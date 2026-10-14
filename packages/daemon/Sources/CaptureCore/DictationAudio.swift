import CoreMedia
import Foundation

/// When dictations happened, so ambient audio doesn't keep them twice (R2b). Each dictation's
/// span, from key-down to key-up with `margin` either side, is kept for `kept`: a few bytes each.
/// The ambient microphone drops any utterance that overlaps one, however late it's delivered, with
/// remembering on or off; and any utterance delivered more than `cutoff` after it ended, which is
/// far inside `kept`, so every utterance is either checked against a span still kept, or dropped.
public final class DictationSpans: @unchecked Sendable {
    public static let margin: TimeInterval = 0.5
    public static let kept: TimeInterval = 24 * 3600
    public static let cutoff: TimeInterval = 600

    public enum Verdict: Equatable, Sendable {
        case keep
        /// Said while dictating: the dictation has it.
        case dictated
        /// Delivered too long after it was said to be checked: dropped, and counted.
        case tooLate
    }

    private let lock = NSLock()
    private var spans: [(from: Date, to: Date)] = []
    /// A dictation under way: its key-down.
    private var open: Date?

    public init() {}

    public func began(at time: Date) {
        lock.withLock { open = time }
    }

    /// The dictation under way ended (typed, or cancelled: said all the same).
    public func ended(at time: Date) {
        lock.withLock {
            guard let from = open else { return }
            open = nil
            spans.append((from.addingTimeInterval(-Self.margin), time.addingTimeInterval(Self.margin)))
            spans.removeAll { $0.to < time.addingTimeInterval(-Self.kept) }
        }
    }

    /// The key-down under way wasn't a dictation (a tap of the key): nothing was said into it.
    public func discard() {
        lock.withLock { open = nil }
    }

    /// What to do with an ambient utterance from the microphone, said at `at` for `seconds`, being
    /// delivered at `now`.
    public func verdict(at: Date, seconds: Double, now: Date) -> Verdict {
        let end = at.addingTimeInterval(max(0, seconds))
        if now.timeIntervalSince(end) > Self.cutoff { return .tooLate }
        return lock.withLock {
            let during = open.map { end >= $0.addingTimeInterval(-Self.margin) } ?? false
            return during || spans.contains { at <= $0.to && end >= $0.from } ? .dictated : .keep
        }
    }
}

/// Audio heard from key-down, held in order until the transcriber is ready, so the first word
/// isn't lost to its start; then given straight through. At most `limit` seconds are held.
public final class DictationFeed<Buffer>: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: TimeInterval
    private var pending: [(buffer: Buffer, time: CMTime, seconds: Double)] = []
    private var held: Double = 0
    private var sink: ((Buffer, CMTime) -> Void)?
    private var closed = false

    public init(limit: TimeInterval = DictationHold.longest) {
        self.limit = limit
    }

    /// Audio that began at `time` and lasts `seconds`.
    public func take(_ buffer: Buffer, at time: CMTime, seconds: Double) {
        lock.lock()
        guard !closed else { return lock.unlock() }
        if let sink {
            lock.unlock()
            sink(buffer, time)
            return
        }
        if held + seconds <= limit {
            pending.append((buffer, time, seconds))
            held += seconds
        }
        lock.unlock()
    }

    /// The transcriber is ready: what was held is given to it, in order, then everything after.
    public func ready(_ sink: @escaping (Buffer, CMTime) -> Void) {
        lock.lock()
        guard !closed else { return lock.unlock() }
        // Given under the lock, so a buffer taken meanwhile waits its turn behind the held ones.
        for item in pending { sink(item.buffer, item.time) }
        pending = []
        self.sink = sink
        lock.unlock()
    }

    /// No more: what's held is let go, and nothing more is taken or given.
    public func close() {
        lock.withLock {
            closed = true
            pending = []
            sink = nil
        }
    }
}

/// One thing made ahead of when it's wanted (dictation's transcriber), so it's ready then. One that
/// couldn't be made isn't kept: the next ask makes another. A download asked for while one made
/// without leave to download is still being made is made next, if that one fails.
public final class MadeAhead<Value: Sendable>: @unchecked Sendable {
    private let make: @Sendable (_ download: Bool) async -> Value?
    private let lock = NSLock()
    private var spare: (id: Int, download: Bool, task: Task<Value?, Never>)?
    private var made = 0
    private var downloadNext = false

    public init(make: @escaping @Sendable (_ download: Bool) async -> Value?) {
        self.make = make
    }

    /// Makes the next, if there isn't one waiting; `download` lets it fetch what it needs.
    public func prepare(download: Bool) {
        lock.withLock { start(download) }
    }

    /// The one made ahead (begun now if there isn't one), taken: the next is made by `prepare`.
    public func take() -> Task<Value?, Never> {
        lock.withLock {
            start(false)
            defer { spare = nil }
            return spare!.task
        }
    }

    /// Whether one is waiting (made, or being made).
    var waiting: Bool { lock.withLock { spare != nil } }

    /// Under the lock.
    private func start(_ download: Bool) {
        if let spare {
            if download && !spare.download { downloadNext = true }
            return
        }
        made += 1
        let (id, make) = (made, self.make)
        downloadNext = false
        spare = (id, download, Task { [weak self] in
            let value = await make(download)
            if value == nil { self?.failed(id) }
            return value
        })
    }

    private func failed(_ id: Int) {
        lock.withLock {
            guard spare?.id == id else { return }
            spare = nil
            if downloadNext { start(true) }
        }
    }
}
