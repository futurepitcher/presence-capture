import CoreMedia
import Foundation

/// A finished utterance as it's kept: when it began, how long it lasted, from which device (the
/// microphone is "input", the sound this Mac plays is "output"), the words, and how sure the
/// transcriber was of them (0–1; nil when it didn't say).
public struct Spoken: Equatable, Sendable {
    public var at: Date
    public var seconds: Double
    public var device: String
    public var deviceType: String
    public var text: String
    public var conf: Double?

    public init(at: Date, seconds: Double, device: String, deviceType: String, text: String, conf: Double? = nil) {
        (self.at, self.seconds, self.device, self.deviceType, self.text, self.conf) = (at, seconds, device, deviceType, text, conf)
    }
}

/// What one device heard, kept an utterance a capture, stamped when it was said, so a consumer can
/// tell an assistant's own voice from the person's by when the words were spoken. A capture is
/// written once its utterance is finished, a little after it was said, and never more than
/// `maxDelay` after (the transcriber is made to finish what's older). Silence keeps nothing.
public enum Utterance {
    /// How long after its words began a capture can be written: every `settleEvery` while listening (its
    /// own clock, never the app's adjustable tick), the transcriber finishes everything older than
    /// `settleAfter`, and takes a moment to: 20 + 5 + time to finish, within 45.
    public static let settleAfter: TimeInterval = 20
    public static let settleEvery: TimeInterval = 5
    public static let maxDelay: TimeInterval = 45

    /// Below these, what the transcriber gave is taken for noise, not speech: a single word below
    /// 0.6, more words below 0.3. Set on an hour of this Mac's speech, where one-word rows below 0.6
    /// were mostly noise and longer ones well above.
    public static let minOneWordConf = 0.6
    public static let minConf = 0.3

    /// A finished utterance, from when it began to when it ended; nil for no words, or words the
    /// transcriber was too unsure of (kept when it didn't say how sure it was).
    public static func row(_ text: String, start: Date, end: Date, device: String, deviceType: String, conf: Double? = nil) -> Spoken? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        if let conf, conf < (severalWords(words) ? minConf : minOneWordConf) { return nil }
        let length = (max(0, end.timeIntervalSince(start)) * 10).rounded() / 10
        return Spoken(at: start, seconds: length, device: device, deviceType: deviceType, text: words, conf: conf)
    }

    /// Whether the words are more than one, by the language's own word breaks (Chinese, Japanese and
    /// Thai put no spaces between words).
    static func severalWords(_ text: String) -> Bool {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, stop in
            count += 1
            stop = count > 1
        }
        return count > 1
    }

    /// How long ago, in seconds, an utterance ended, on its stream's clock; nil when that can't be told
    /// (a time that isn't one, or in the future). Asked before its times are made wall-clock times,
    /// which take an unknowable one for just now.
    public static func age(_ range: CMTimeRange, clockNow: CMTime) -> Double? {
        let ago = CMTimeGetSeconds(CMTimeSubtract(clockNow, range.end))
        return ago.isFinite && ago >= -1 ? max(0, ago) : nil
    }

    /// An utterance's span on the clock its stream's buffers are timed by, as wall-clock times, by
    /// how long before `clockNow` (that clock's reading at `now`) it ended. One that can't be (in the
    /// future, or more than ten minutes back) is taken as just ended.
    public static func wallTimes(_ range: CMTimeRange, clockNow: CMTime, now: Date) -> (start: Date, end: Date) {
        let ago = CMTimeGetSeconds(CMTimeSubtract(clockNow, range.end))
        let length = CMTimeGetSeconds(range.duration)
        let end = ago.isFinite && ago >= 0 && ago < DictationSpans.cutoff ? now.addingTimeInterval(-ago) : now
        return (end.addingTimeInterval(-(length.isFinite ? max(0, length) : 0)), end)
    }
}
