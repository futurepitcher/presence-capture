import AVFoundation
import CaptureCore
import CoreMedia

/// The microphone for dictation (R2b), on from key-down to release, and the transcriber it feeds.
/// A transcriber is made before it's needed (at launch, when dictation is turned on, and after each
/// use), so it's normally ready at key-down; audio heard before it is, is held and given first, so
/// the opening word isn't lost.
@available(macOS 26, *)
final class DictationListener: DictationListening, @unchecked Sendable {
    /// A transcriber, made ahead, and what it hears.
    final class Ready: @unchecked Sendable {
        let transcriber: Transcriber
        let words: Words

        init(transcriber: Transcriber, words: Words) {
            (self.transcriber, self.words) = (transcriber, words)
        }
    }

    /// What a transcriber heard, in order.
    final class Words: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ text: String) { lock.withLock { said.append(text) } }
        var text: String { lock.withLock { said.joined(separator: " ") } }
    }

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let ahead: MadeAhead<Ready>
    private var tapped = false

    init(log: @escaping @Sendable (String) -> Void) {
        ahead = MadeAhead { download in
            do {
                guard let locale = try await Transcriber.prepare(locale: Locale.current, download: download) else {
                    log("dictation.no_model")
                    return nil
                }
                let words = Words()
                return Ready(transcriber: try await Transcriber(locale: locale) { text, _, _ in words.add(text) }, words: words)
            } catch {
                log("dictation.transcriber_failed")
                return nil
            }
        }
    }

    /// Makes the next transcriber, if there isn't one waiting (one that failed isn't kept). The model
    /// is used if it's on this Mac; it's fetched (from Apple) only while dictation is on (`download`).
    func prepare(download: Bool = false) {
        ahead.prepare(download: download)
    }

    /// Key-down: the microphone on, its audio given to the waiting transcriber (held until it's
    /// ready). `level` hears how loud, 0–1, for the panel's meter.
    func begin(level: @escaping @Sendable (Float) -> Void) throws -> DictationHearing {
        let session = DictationSession(ready: ahead.take())
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            guard let copy = Self.copy(buffer) else { return }
            let time = when.isHostTimeValid ? CMClockMakeHostTimeFromSystemUnits(when.hostTime) : CMClockGetTime(CMClockGetHostTimeClock())
            session.feed.take(copy, at: time, seconds: Double(copy.frameLength) / format.sampleRate)
            level(Self.level(copy))
        }
        lock.withLock { tapped = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stop()
            session.cancel()
            throw error
        }
        return session
    }

    /// The microphone off, at once.
    func stop() {
        let wasTapped = lock.withLock { () -> Bool in
            defer { tapped = false }
            return tapped
        }
        guard wasTapped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// A buffer of its own: the engine may reuse the one it hands the tap.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (source, target) in zip(from, to) {
            guard let data = source.mData, let into = target.mData else { return nil }
            memcpy(into, data, Int(min(source.mDataByteSize, target.mDataByteSize)))
        }
        return out
    }

    /// The loudest sample, 0–1 (float audio; others read as 0).
    static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[i])) }
        return min(1, peak)
    }
}

/// One dictation's audio and words. Cancelled, it gives nothing, and its transcriber is let go.
@available(macOS 26, *)
final class DictationSession: DictationHearing, @unchecked Sendable {
    let feed = DictationFeed<AVAudioPCMBuffer>()
    private let ready: Task<DictationListener.Ready?, Never>
    private let started: Task<DictationListener.Ready?, Never>

    init(ready: Task<DictationListener.Ready?, Never>) {
        self.ready = ready
        let feed = self.feed
        started = Task {
            guard let made = await ready.value else { return nil }
            feed.ready { buffer, time in made.transcriber.feed(buffer, at: time) }
            return made
        }
    }

    /// Released: what was said, once the transcriber has finished with all of it; nil if there was
    /// no transcriber to hear it.
    func finish() async -> String? {
        guard let made = await started.value else { return nil }
        feed.close()
        await made.transcriber.finish()
        return made.words.text
    }

    /// Cancelled: nothing more is taken, and what was heard is let go unread.
    func cancel() {
        feed.close()
        let started = self.started
        Task { await started.value?.transcriber.finish() }
    }
}
