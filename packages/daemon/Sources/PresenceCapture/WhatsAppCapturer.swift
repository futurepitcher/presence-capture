import CaptureCore
import CaptureStore
import Foundation

/// WhatsApp, built into the app (docs/sources/whatsapp.md): the text of every chat on this Mac, both
/// sides, read read-only from WhatsApp Desktop's own database every 30 seconds and put through the
/// same gate as any sensor. Off until the person turns it on, which is the consent; from then on it
/// runs by itself. Chats on the WhatsApp exclude list are never kept, and while capture is held
/// (Pause, locked, asleep) nothing is kept: what was written meanwhile is passed over, not queued.
///
/// Settings, in the app's defaults: `whatsApp` (on or off), `whatsAppSince` (nothing sent before this
/// is read: when it was turned on, or as far back as a history import asked) and `whatsAppAfter` (the
/// last row read, so a restart reads on from there).
final class WhatsAppCapturer: @unchecked Sendable {
    enum Status: Equatable {
        /// WhatsApp Desktop's database isn't on this Mac (or this app can't see it).
        case notInstalled
        case off
        /// There, but macOS hasn't allowed this app to read it.
        case needsAccess
        case on
        /// Not a database this reader knows: nothing is read until the app is updated.
        case unknownSchema
    }

    static let enabledKey = "whatsApp"
    static let sinceKey = "whatsAppSince"
    static let afterKey = "whatsAppAfter"
    static let interval: TimeInterval = 30
    /// What setup offers to bring in from before it was turned on. None is the default.
    static let historyChoices = [0, 30, 90, WhatsAppDatabase.historyMaxDays]

    private let path: String
    private let gate: Gate
    private let defaults: UserDefaults
    private let held: @Sendable () -> Bool
    private let fragments: @Sendable () -> [String]?
    private let chats: @Sendable () -> [String]?
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "presence.capture.whatsapp")
    private let lock = NSLock()
    private var current = Status.off
    private var timer: DispatchSourceTimer?

    /// `fragments` is the app's exclusion list and `chats` the WhatsApp exclude list: nil when one
    /// exists but can't be read, and then nothing is read until it can be.
    init(path: String = WhatsAppDatabase.defaultPath, store: CaptureStore, defaults: UserDefaults, held: @escaping @Sendable () -> Bool,
         fragments: @escaping @Sendable () -> [String]?, chats: @escaping @Sendable () -> [String]?, log: @escaping @Sendable (String) -> Void) {
        (self.path, self.defaults, self.held, self.fragments, self.chats, self.log) = (path, defaults, held, fragments, chats, log)
        gate = Gate(store: store, source: "whatsapp")
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var installed: Bool { FileManager.default.fileExists(atPath: path) }
    var status: Status { lock.withLock { current } }
    /// The days of history that can be brought in when captures are kept for `retentionDays`: never
    /// more than a year, and never more than would be erased again at once.
    static func historyDays(_ asked: Int, retentionDays: Int) -> Int { max(0, min(asked, WhatsAppDatabase.historyMaxDays, retentionDays)) }

    /// Turned on, with the consent given: reads from now, or from `historyDays` back.
    func turnOn(historyDays: Int = 0, now: Date = Date()) {
        queue.sync {
            defaults.set(now.timeIntervalSince1970 - Double(max(0, historyDays)) * 86_400, forKey: Self.sinceKey)
            defaults.set(0, forKey: Self.afterKey)
            defaults.set(true, forKey: Self.enabledKey)
            lock.withLock { current = .on }
        }
        log("whatsapp.on history_days=\(historyDays)")
        pollSoon()
    }

    /// Off, at once: nothing more is read, a read under way included. What was kept stays until it's
    /// forgotten or ages out.
    func turnOff() {
        defaults.set(false, forKey: Self.enabledKey)
        queue.async { [self] in
            defaults.removeObject(forKey: Self.sinceKey)
            defaults.removeObject(forKey: Self.afterKey)
            lock.withLock { current = installed ? .off : .notInstalled }
        }
        log("whatsapp.off")
    }

    /// Brings in what was sent up to `days` before now, every chat but the excluded. A message already
    /// kept, or kept and forgotten, isn't kept again.
    func importHistory(days: Int, now: Date = Date()) {
        guard enabled, days > 0 else { return }
        queue.sync {
            let since = now.timeIntervalSince1970 - Double(days) * 86_400
            defaults.set(min(since, defaults.object(forKey: Self.sinceKey) as? Double ?? since), forKey: Self.sinceKey)
            defaults.set(0, forKey: Self.afterKey)
        }
        log("whatsapp.history days=\(days)")
        pollSoon()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.read() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func pollSoon() { queue.async { self.read() } }

    /// `done`, on the main thread, with the status once what's queued (a first read) is done.
    func afterRead(_ done: @escaping @MainActor (Status) -> Void) {
        queue.async { [self] in
            let status = self.status
            Task { @MainActor in done(status) }
        }
    }

    /// Returns once what's queued is done (tests; quitting).
    func flush() { queue.sync {} }

    func takeStats() -> Gate.Stats { gate.takeStats() }

    /// One read, on the queue. Exposed for tests.
    func pollNow() -> Status { queue.sync { read() } }

    /// Every chat, for choosing one to forget; nil when it can't be read.
    func chatList() -> [WhatsAppDatabase.Chat]? { queue.sync { try? WhatsAppDatabase(path: path).chats() } }

    @discardableResult
    private func read() -> Status {
        let status = readOnce()
        let changed = lock.withLock { () -> Bool in
            defer { current = status }
            return current != status
        }
        if changed { log("whatsapp.status \(status)") }
        return status
    }

    private func readOnce() -> Status {
        guard enabled else { return installed ? .off : .notInstalled }
        let db: WhatsAppDatabase
        do {
            db = try WhatsAppDatabase(path: path)
        } catch WhatsAppDatabase.ReadError.missing {
            return .notInstalled
        } catch WhatsAppDatabase.ReadError.unknownSchema {
            return .unknownSchema
        } catch {
            return .needsAccess
        }
        do {
            let last = try db.lastRow()
            // A database made again (WhatsApp reinstalled) starts its rows over: so does the read. (So
            // does one whose newest rows were deleted; dedupe keeps that re-read from adding anything.)
            let saved = defaults.integer(forKey: Self.afterKey)
            let after = saved > last ? 0 : saved
            // Held: what was written meanwhile is passed over, never kept later.
            if held() {
                defaults.set(last, forKey: Self.afterKey)
                return .on
            }
            // A list that can't be read: nothing is read, and the read waits for it.
            guard let fragments = fragments(), let chats = chats() else { return .on }
            let since = Date(timeIntervalSince1970: defaults.object(forKey: Self.sinceKey) as? Double ?? Date().timeIntervalSince1970)
            var reached = after
            for message in try db.messages(since: since, after: after) {
                // Turned off meanwhile: nothing more, and the next turn-on starts afresh.
                guard enabled else { return .off }
                if !WhatsAppDatabase.isExcluded(message, by: chats) {
                    do {
                        try gate.ingest(WhatsAppDatabase.observation(message), fragments: fragments)
                    } catch {
                        // Read again next time, from this message on.
                        log("whatsapp.store_failed")
                        defaults.set(reached, forKey: Self.afterKey)
                        return .on
                    }
                }
                reached = message.pk
            }
            defaults.set(max(reached, last), forKey: Self.afterKey)
            return .on
        } catch {
            return .needsAccess
        }
    }
}
