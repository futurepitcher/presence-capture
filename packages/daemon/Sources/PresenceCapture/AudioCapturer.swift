import AVFoundation
import CaptureCore
import CaptureStore
import CoreMedia
import ScreenCaptureKit

/// What the app listens with: told at once, whenever it changes, whether it may listen now.
protocol Listener: AnyObject {
    func tick(listening: Bool)
    /// Stop, keeping what was heard, once whatever is under way is done (the app is quitting).
    func finish() async
    /// What it's listening to, for the menu.
    var state: String { get }
    func takeCounts() -> (input: Int, output: Int)
}

/// What this Mac hears: the microphone (you, "input") and the sound it plays (the others on a
/// call, "output"), from one ScreenCaptureKit stream, each one the person may turn off (R8, per
/// input device). Each is transcribed on this Mac (SpeechAnalyzer, ADR 0004) and kept an utterance
/// at a time, stamped when it was said: an `audio_segment` with no audio in it (ADR 0005) and the
/// `audio_transcript` derived from it (R10), so revoking the one takes the other. Redacted first.
/// No audio is ever written.
///
/// One wanted state, set at once whenever it changes. Starting and stopping run one at a time, each
/// settling on what's wanted when it ends, and audio that comes in while it isn't wanted is dropped
/// as it comes, so a pause or a lock takes effect at once, whatever is under way.
@available(macOS 26, *)
final class AudioCapturer: NSObject, Listener, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let store: CaptureStore
    /// Which devices the person allows to be heard, read when listening starts.
    private let devices: @Sendable () -> (microphone: Bool, systemAudio: Bool)
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "presence.capture.audio")
    private let lock = NSLock()
    // All below, under the lock.
    private var wanted = false
    private var stream: SCStream?
    private var channels: [SCStreamOutputType: Channel] = [:]
    /// Whether the running stream hears the microphone: when that and the permission differ (allowed
    /// in System Settings, or taken back), it starts again.
    private var hasMic = false
    /// A start or stop queued or under way.
    private var busy = false
    private var lifecycle: Task<Void, Never>?
    /// Settles what each channel heard every Utterance.settleEvery while the stream runs, on its own
    /// clock: the app's tick can be set longer, and a row must never wait past Utterance.maxDelay.
    private var settler: Task<Void, Never>?
    /// The clock the stream's buffers are timed by (SCStream.synchronizationClock; the host clock
    /// until a stream says otherwise): what's heard is aged and dated by it, never another.
    private var clock: CMClock = CMClockGetHostTimeClock()
    /// What came in from each source since the last flow line, and whose format was logged.
    private var inputs: [SCStreamOutputType: InputFlow] = [:]
    private var kept: [SCStreamOutputType: Int] = [:]
    private var formatLogged: Set<SCStreamOutputType> = []
    private var retryAfter = Date.distantPast
    private var counts = (input: 0, output: 0)
    /// Dictations (R2b): ambient audio doesn't keep what was dictated, nor what arrives too late to
    /// be checked against them.
    private let spans: DictationSpans
    private var dropped = (dictated: 0, tooLate: 0, unexcludable: 0)
    /// Whether what's heard may be kept now: not while the exclusion list can't be read (R8).
    private let mayKeep: @Sendable () -> Bool
    /// Quitting: from then nothing makes it listen again, whatever a tick says.
    private var ending = false

    init(store: CaptureStore, devices: @escaping @Sendable () -> (microphone: Bool, systemAudio: Bool), spans: DictationSpans = DictationSpans(),
         mayKeep: @escaping @Sendable () -> Bool = { true }, log: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.spans = spans
        self.mayKeep = mayKeep
        self.devices = devices
        self.log = log
    }

    func tick(listening: Bool) {
        let allowed = devices()
        let micAllowed = allowed.microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let (settle, restart) = lock.withLock { () -> (Bool, Bool) in
            wanted = listening && !ending
            let running = stream != nil
            if busy { return (false, false) }
            // A device turned on or off (or the microphone allowed or taken back): heard afresh.
            let restart = wanted && running && (micAllowed != hasMic || allowed.systemAudio != (channels[.audio] != nil))
            let settle = wanted != running && (running || Date() >= retryAfter)
            if restart || settle { busy = true }
            return (settle, restart)
        }
        if restart { enqueue { await self.stop(); await self.settle() } }
        else if settle { enqueue { await self.settle() } }
    }

    func finish() async {
        lock.withLock {
            ending = true
            wanted = false
            busy = true
        }
        enqueue { await self.settle() }
        await lock.withLock { lifecycle }?.value
    }

    var state: String {
        lock.withLock {
            guard stream != nil, wanted else { return "Not listening" }
            switch (hasMic, channels[.audio] != nil) {
            case (true, true): return "Listening: microphone and system audio"
            case (true, false): return "Listening: microphone only"
            default: return "Listening: system audio only"
            }
        }
    }

    func takeCounts() -> (input: Int, output: Int) {
        let (kept, drops) = lock.withLock { () -> ((input: Int, output: Int), (dictated: Int, tooLate: Int, unexcludable: Int)) in
            defer { (counts, dropped) = ((0, 0), (0, 0, 0)) }
            return (counts, dropped)
        }
        if drops.dictated + drops.tooLate + drops.unexcludable > 0 {
            log("audio.dropped dictated=\(drops.dictated) too_late=\(drops.tooLate) exclusions_unreadable=\(drops.unexcludable)")
        }
        return kept
    }

    /// An utterance's wall-clock times, or nil when it ended `DictationSpans.cutoff` or more ago on its
    /// stream's clock (the bound Utterance.wallTimes keeps times within), or its time can't be told:
    /// dropped then, never taken for just said (which would slip it past the dictations kept, and past
    /// a Forget of when it was really said).
    static func times(_ range: CMTimeRange, clockNow: CMTime, now: Date) -> (start: Date, end: Date)? {
        guard let age = Utterance.age(range, clockNow: clockNow), age < DictationSpans.cutoff else { return nil }
        return Utterance.wallTimes(range, clockNow: clockNow, now: now)
    }

    fileprivate func tooLate() {
        lock.withLock { dropped.tooLate += 1 }
    }

    /// Whether an utterance is kept: not if it was said while dictating (from the microphone: the
    /// dictation has it), and not if it arrives more than `DictationSpans.cutoff` after it ended
    /// (from either device), which is too late to be checked against the dictations kept.
    static func admits(_ spoken: Spoken, spans: DictationSpans, now: Date) -> DictationSpans.Verdict {
        let verdict = spans.verdict(at: spoken.at, seconds: spoken.seconds, now: now)
        return verdict == .dictated && spoken.deviceType != "input" ? .keep : verdict
    }

    /// After whatever is queued.
    private func enqueue(_ step: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let before = lifecycle
            lifecycle = Task {
                await before?.value
                await step()
            }
        }
    }

    /// Start or stop until running is what's wanted (or a start must wait to try again).
    private func settle() async {
        while true {
            let (want, running, mayStart) = lock.withLock { (wanted, stream != nil, Date() >= retryAfter) }
            if want && !running && mayStart {
                await start()
            } else if !want && running {
                await stop()
            } else {
                break
            }
        }
        lock.withLock { busy = false }
    }

    private func start() async {
        var made: [SCStreamOutputType: Channel] = [:]
        do {
            guard let locale = try await Transcriber.prepare(locale: Locale.current, download: true) else {
                log("audio.no_model")
                retry(in: 3600)
                return
            }
            let allowed = devices()
            let micAllowed = allowed.microphone && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            guard allowed.systemAudio || micAllowed else {
                log("audio.all_devices_off")
                retry(in: 60)
                return
            }
            if allowed.systemAudio {
                made[.audio] = try await Channel(device: "System Audio (output)", deviceType: "output", locale: locale, owner: self)
            }
            if micAllowed {
                let name = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Microphone"
                made[.microphone] = try await Channel(device: "\(name) (input)", deviceType: "input", locale: locale, owner: self)
            }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw AudioError.noDisplay }
            let config = SCStreamConfiguration()
            config.capturesAudio = allowed.systemAudio
            config.captureMicrophone = micAllowed
            config.excludesCurrentProcessAudio = true
            config.channelCount = 1
            // The stream carries the screen too: as little of it as it allows, never read.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if allowed.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
            if micAllowed { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue) }
            // No longer wanted while the model and transcribers were readied (paused, locked): not started.
            guard lock.withLock({ wanted }) else {
                for channel in made.values { await channel.finish() }
                return
            }
            lock.withLock {
                channels = made
                hasMic = micAllowed
                inputs = [:]
                kept = [:]
                formatLogged = []
            }
            lock.withLock { clock = stream.synchronizationClock ?? CMClockGetHostTimeClock() }
            try await stream.startCapture()
            // Asked again once started, in case it says only then.
            lock.withLock { clock = stream.synchronizationClock ?? clock }
            let settler = Task { [weak self] in
                let began = Date()
                var flowLogged = Date.distantPast
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(Utterance.settleEvery * 1_000_000_000))
                    guard let self else { return }
                    let now = self.streamNow()
                    for channel in self.lock.withLock({ Array(self.channels.values) }) { channel.settle(now: now) }
                    // A minute after it starts, then every ten.
                    let due = flowLogged == .distantPast ? Date().timeIntervalSince(began) >= 60 : Date().timeIntervalSince(flowLogged) >= 600
                    if due {
                        self.logFlow()
                        flowLogged = Date()
                    }
                }
            }
            lock.withLock {
                self.stream = stream
                self.settler = settler
            }
            log("audio.started mic=\(micAllowed)")
        } catch {
            log("audio.start_failed \(String(describing: type(of: error)))")
            lock.withLock { channels = [:] }
            retry(in: 60)
            for channel in made.values { await channel.finish() }
        }
    }

    /// The stream stopped (if it hasn't already), and everything heard up to now kept.
    private func stop() async {
        let (stream, made) = lock.withLock { () -> (SCStream?, [Channel]) in
            settler?.cancel()
            settler = nil
            return (self.stream, Array(channels.values))
        }
        try? await stream?.stopCapture()
        for channel in made { await channel.finish() }
        lock.withLock {
            self.stream = nil
            channels = [:]
        }
        log("audio.stopped")
    }

    /// Now, on the clock the stream's buffers are timed by.
    fileprivate func streamNow() -> CMTime {
        CMClockGetTime(lock.withLock { clock })
    }

    /// Counts and levels only, a line per source: what came in, what the transcriber was fed, how
    /// its settles went, what it heard and what was kept. Never a word.
    private func logFlow() {
        let (flows, keptRows, made) = lock.withLock { () -> ([SCStreamOutputType: InputFlow], [SCStreamOutputType: Int], [SCStreamOutputType: Channel]) in
            defer {
                inputs = [:]
                kept = [:]
            }
            return (inputs, kept, channels)
        }
        for (type, name) in [(SCStreamOutputType.audio, "output"), (.microphone, "input")] {
            guard let channel = made[type] else { continue }
            let input = flows[type] ?? InputFlow()
            let through = channel.takeFlow()
            log("audio.flow kind=\(name) buffers=\(input.buffers) frames=\(input.frames) unreadable=\(input.unreadable) untimed=\(input.untimed) peak=\(String(format: "%.3f", input.peak)) fed=\(through.fed) unconverted=\(through.unconverted) settled=\(through.settled) refused=\(through.settleRefused) gaps=\(through.gaps) behind=\(through.behind) heard=\(through.heard) kept=\(keptRows[type] ?? 0)")
        }
    }

    /// A segment and its transcript, written together or not at all, stamped when the words were
    /// said: speech from a range forgotten while it was being transcribed is refused, and none is
    /// kept while the exclusion list can't be read, however late it arrives.
    func keep(_ spoken: Spoken, from type: SCStreamOutputType) {
        guard mayKeep() else { return lock.withLock { dropped.unexcludable += 1 } }
        switch Self.admits(spoken, spans: spans, now: Date()) {
        case .keep: break
        case .dictated: return lock.withLock { dropped.dictated += 1 }
        case .tooLate: return lock.withLock { dropped.tooLate += 1 }
        }
        do {
            let segment = CaptureStore.newCaptureId()
            try store.appendAll([
                NewCapture(captureId: segment, capturedAt: spoken.at, captureType: "audio_segment", source: "ambient_audio",
                           sourceApp: spoken.deviceType),
                NewCapture(capturedAt: spoken.at, captureType: "audio_transcript", source: "ambient_audio", sourceApp: spoken.deviceType,
                           contentText: Redact.redact(spoken.text), extraction: "asr", derivedFrom: segment),
            ])
            lock.withLock {
                kept[type, default: 0] += 1
                if spoken.deviceType == "input" { counts.input += 1 } else { counts.output += 1 }
            }
        } catch StoreError.revoked {
            log("append.refused_revoked kind=audio")
        } catch {
            log("audio.store_failed")
        }
    }

    /// Audio, given to its channel only while listening is wanted.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type != .screen, sampleBuffer.isValid, let channel = lock.withLock({ wanted ? channels[type] : nil }) else { return }
        let buffer = Self.pcm(sampleBuffer)
        let first = lock.withLock { () -> Bool in
            var flow = inputs[type] ?? InputFlow()
            flow.buffers += 1
            flow.frames += sampleBuffer.numSamples
            if let buffer { flow.peak = max(flow.peak, Self.peak(buffer)) } else { flow.unreadable += 1 }
            if !sampleBuffer.presentationTimeStamp.isValid { flow.untimed += 1 }
            inputs[type] = flow
            return formatLogged.insert(type).inserted
        }
        if first, let description = sampleBuffer.formatDescription, let basic = description.audioStreamBasicDescription {
            let float = basic.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let interleaved = basic.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            log("audio.format kind=\(type == .audio ? "output" : "input") rate=\(Int(basic.mSampleRate)) channels=\(basic.mChannelsPerFrame) float=\(float) interleaved=\(interleaved) bits=\(basic.mBitsPerChannel)")
        }
        guard let buffer else { return }
        channel.feed(buffer, at: sampleBuffer.presentationTimeStamp)
    }

    /// The loudest sample in a buffer's first channel, 0–1: a level, not what was said.
    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        if let samples = buffer.floatChannelData?[0] {
            return (0..<frames).reduce(Float(0)) { max($0, abs(samples[$1])) }
        }
        if let samples = buffer.int16ChannelData?[0] {
            return (0..<frames).reduce(Float(0)) { max($0, abs(Float(samples[$1]) / 32_768)) }
        }
        return 0
    }

    /// Stopped by the system (a display gone, permission taken back): what was heard is kept, and a
    /// tick starts it again after a wait.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        startAgain(after: "audio.stream_stopped")
    }

    /// A channel's transcriber ended with an error: it would hear nothing more, so all of it stops
    /// and starts again after a wait, as when the stream stops.
    fileprivate func channelFailed() {
        startAgain(after: "audio.transcriber_failed")
    }

    private func startAgain(after event: String) {
        log(event)
        lock.withLock { busy = true }
        retry(in: 30)
        enqueue {
            await self.stop()
            await self.settle()
        }
    }

    /// Not started again for `seconds`, then at once if listening is still wanted: on its own clock,
    /// not waiting for the app's tick, which can be set much longer.
    private func retry(in seconds: TimeInterval) {
        lock.withLock { retryAfter = Date().addingTimeInterval(seconds) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            let go = self.lock.withLock { () -> Bool in
                guard self.wanted, self.stream == nil, !self.busy, Date() >= self.retryAfter else { return false }
                self.busy = true
                return true
            }
            if go { self.enqueue { await self.settle() } }
        }
    }

    /// A sample buffer's audio as a PCM buffer, in its own format.
    private static func pcm(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

@available(macOS 26, *)
private enum AudioError: Error {
    case noDisplay
}

/// One device: its transcriber, each utterance it finishes kept at once.
@available(macOS 26, *)
private final class Channel: @unchecked Sendable {
    private var transcriber: Transcriber?

    init(device: String, deviceType: String, locale: Locale, owner: AudioCapturer) async throws {
        transcriber = try await Transcriber(
            locale: locale,
            heard: { [weak owner] text, range, confidence in
                guard let owner else { return }
                guard let (start, end) = AudioCapturer.times(range, clockNow: owner.streamNow(), now: Date()) else { return owner.tooLate() }
                if let spoken = Utterance.row(text, start: start, end: end, device: device, deviceType: deviceType, conf: confidence) {
                    owner.keep(spoken, from: deviceType == "input" ? .microphone : .audio)
                }
            },
            failed: { [weak owner] in owner?.channelFailed() }
        )
    }

    func feed(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        transcriber?.feed(buffer, at: time)
    }

    /// What's older than Utterance.settleAfter at `now` (the stream's clock), finished and kept now.
    func settle(now: CMTime) {
        transcriber?.settle(olderThan: Utterance.settleAfter, now: now)
    }

    func finish() async {
        await transcriber?.finish()
    }

    func takeFlow() -> TranscriberFlow {
        transcriber?.takeFlow() ?? TranscriberFlow()
    }
}

/// What came in from one source: counts and its loudest level.
private struct InputFlow {
    var buffers = 0
    var frames = 0
    var unreadable = 0
    var untimed = 0
    var peak: Float = 0
}
