import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Speech to text on this Mac, with Apple's SpeechTranscriber: one stream of audio in, each
/// finished utterance out with when it began and ended on the stream's own clock (the times its
/// buffers were given with). Nothing leaves the Mac.
@available(macOS 26, *)
public final class Transcriber: @unchecked Sendable {
    /// A finished utterance: its words, its span on the stream's clock, and how sure the
    /// transcriber was of them (0–1, by characters; nil when it didn't say).
    public typealias Heard = @Sendable (_ text: String, _ range: CMTimeRange, _ confidence: Double?) -> Void

    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let results: Task<Void, Never>
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private let finishing: Finishing
    private let counts = Counts()
    /// Where the next audio fed begins on the stream's clock: what was fed is one unbroken run from
    /// its first buffer's time, since converted buffers aren't the length their times would say
    /// (and audio given twice over a span is dropped by the analyzer).
    private var next: CMTime?
    /// A buffer this much later than the run's end begins a new run there: audio was missed.
    private static let gap = CMTime(value: 1, timescale: 2)

    /// The model for speech like `locale`'s, kept for this app (Apple's own, shared by the apps
    /// that use it): its locale once it's on this Mac, else nil. With `download`, a model not yet on
    /// it is fetched from Apple first; without, nothing is fetched.
    public static func prepare(locale: Locale, download: Bool) async throws -> Locale? {
        guard SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let module = module(supported)
        try await AssetInventory.reserve(locale: supported)
        if await AssetInventory.status(forModules: [module]) == .installed { return supported }
        guard download, let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return nil }
        try await request.downloadAndInstall()
        return await AssetInventory.status(forModules: [module]) == .installed ? supported : nil
    }

    /// Final results only, each with its span.
    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// How sure the transcriber was of a result's words, weighted by their length.
    static func confidence(_ text: AttributedString) -> Double? {
        var weighted = 0.0
        var length = 0
        for (value, range) in text.runs[\.transcriptionConfidence] {
            guard let value else { continue }
            let count = text.characters[range].count
            weighted += value * Double(count)
            length += count
        }
        return length == 0 ? nil : weighted / Double(length)
    }

    /// What went through since asked last.
    public func takeFlow() -> TranscriberFlow {
        counts.take()
    }

    /// Listening for speech in a locale `prepare` gave; `heard` hears each utterance as it ends, and
    /// `failed` hears if the analysis ends with an error before `finish` (nothing more will be heard).
    public init(locale: Locale, heard: @escaping Heard, failed: @escaping @Sendable () -> Void = {}) async throws {
        let module = Self.module(locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { throw TranscriberError.noFormat }
        let (inputs, input) = AsyncStream<AnalyzerInput>.makeStream()
        analyzer = SpeechAnalyzer(modules: [module])
        self.format = format
        self.input = input
        let finishing = Finishing()
        self.finishing = finishing
        let counts = self.counts
        results = Task {
            do {
                for try await result in module.results where result.isFinal {
                    counts.add { $0.heard += 1 }
                    heard(String(result.text.characters), result.range, Transcriber.confidence(result.text))
                }
            } catch {
                // What was heard before was given. Ended by an error while listening: said, so the
                // listener can start again; ended as it was finishing: nothing to say.
                if !finishing.value { failed() }
            }
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: inputs)
    }

    /// Audio that began at `time` on the stream's clock, in any PCM format.
    public func feed(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let converted = convert(buffer) else {
            counts.add { $0.unconverted += 1 }
            return
        }
        counts.add { $0.fed += 1 }
        let start = next.map { CMTimeCompare(time, CMTimeAdd($0, Self.gap)) >= 0 ? time : $0 } ?? time
        if let next, CMTimeCompare(start, next) != 0 { counts.add { $0.gaps += 1 } }
        if let next, CMTimeCompare(time, next) < 0 { counts.add { $0.behind += 1 } }
        next = CMTimeAdd(start, CMTime(value: CMTimeValue(converted.frameLength), timescale: CMTimeScale(format.sampleRate)))
        input.yield(AnalyzerInput(buffer: converted, bufferStartTime: start))
    }

    /// Everything said more than `seconds` before `now` (on the stream's clock: the host's, for a
    /// ScreenCaptureKit stream) is finished and given now, even mid-utterance, so no words wait long
    /// to be written (see Utterance.maxDelay). Listening goes on. Aged by the clock, not by the audio
    /// fed: a source that went quiet sends no buffers, and what it heard last is finished all the
    /// same, once all of it is older than that (through the end of what was fed). Otherwise not
    /// through the very end of what was fed, which the analyzer refuses; one refused is asked again.
    public func settle(olderThan seconds: TimeInterval, now: CMTime) {
        let cutoff = CMTimeSubtract(now, CMTime(seconds: seconds, preferredTimescale: 600))
        guard let fed = lock.withLock({ next }) else { return }
        let quiet = CMTimeCompare(cutoff, fed) >= 0
        let counts = self.counts
        Task {
            do {
                try await analyzer.finalize(through: quiet ? nil : cutoff)
                counts.add { $0.settled += 1 }
            } catch {
                counts.add { $0.settleRefused += 1 }
            }
        }
    }

    /// No more audio: what was said up to its end is given, then this returns.
    public func finish() async {
        finishing.value = true
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await results.value
    }

    /// In the analyzer's format (called holding the lock).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate).rounded(.up)) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var failure: NSError?
        converter.convert(to: out, error: &failure) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return failure == nil && out.frameLength > 0 ? out : nil
    }
}

public enum TranscriberError: Error {
    case noFormat
}

/// Whether `finish` has begun, as the results task sees it.
private final class Finishing: @unchecked Sendable {
    private let lock = NSLock()
    private var begun = false
    var value: Bool {
        get { lock.withLock { begun } }
        set { lock.withLock { begun = newValue } }
    }
}

/// How much went through a transcriber, for the log: counts only, never what was heard.
public struct TranscriberFlow: Sendable, Equatable {
    public var fed = 0
    public var unconverted = 0
    public var settled = 0
    public var settleRefused = 0
    public var heard = 0
    /// Buffers that began a new run (a gap of half a second or more after the last), and buffers
    /// whose time was behind the run's end (fed as if continuous).
    public var gaps = 0
    public var behind = 0

    public init() {}
}

/// The flow counts, shared with the results task and settles.
private final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var flow = TranscriberFlow()
    func add(_ change: (inout TranscriberFlow) -> Void) { lock.withLock { change(&flow) } }
    func take() -> TranscriberFlow {
        lock.withLock {
            defer { flow = TranscriberFlow() }
            return flow
        }
    }
}
