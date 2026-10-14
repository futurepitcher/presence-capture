import AppKit
import ApplicationServices
import AVFoundation
import CaptureConnect
import CaptureStore

/// Presence Capture: a menu-bar app that reads the screen, hears this Mac and notes what's in front,
/// into a store whose content is sealed and whose revocation erases (packages/daemon/CONTRACT.md).
/// It writes and never serves: an agent reads the store through pcap-mcp, a separate process.
///
/// The store lives in ~/Library/Application Support/Presence Capture (PRESENCE_CAPTURE_HOME to move
/// it); its master key in the Keychain. Settings are the app's defaults: `interval` (seconds),
/// `retentionDays`, `paused`, `hearMicrophone` (off until the person turns it on: whether a room is
/// heard is theirs to choose), `hearSystemAudio`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let home = CaptureStore.home
    private let defaults = UserDefaults.standard
    private var statusItem: NSStatusItem!
    private var stateItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var accessibilityItem: NSMenuItem!
    private var audioItem: NSMenuItem!
    private var microphoneItem: NSMenuItem!
    private var hearMicrophoneItem: NSMenuItem!
    private var hearSystemAudioItem: NSMenuItem!
    private var approveSensorsItem: NSMenuItem!
    private var retentionMenu: NSMenu!
    private let windows = Windows()
    private var audio: Listener?
    private var store: CaptureStore?
    private var capturer: ScreenCapturer?
    private var activity: ActivityCapturer?
    private var log: Logger!
    private var sensors: SensorPlugins?
    /// Whether capture is held, for sensor plugins, whose output arrives off the main thread.
    private let heldNow = Flag()
    private var timers: [Timer] = []
    private var problem: String?

    private var exclusionPath: String { home + "/excluded-windows.txt" }
    private var sensorsPath: String { home + "/sensors.json" }
    private var interval: TimeInterval { TimeInterval(defaults.integer(forKey: "interval").nonZero ?? 5) }
    private var retentionDays: Int { defaults.integer(forKey: "retentionDays").nonZero ?? 14 }
    private var hearMicrophone: Bool { defaults.object(forKey: "hearMicrophone") as? Bool ?? false }
    private var hearSystemAudio: Bool { defaults.object(forKey: "hearSystemAudio") as? Bool ?? true }

    /// Starts as saved (or as `-paused` says at launch), then is the menu's: the launch argument's
    /// domain can't be written, so reading the default back would undo Pause or Resume.
    private lazy var paused: Bool = defaults.bool(forKey: "paused") {
        didSet {
            defaults.set(paused, forKey: "paused")
            holdCapture()
        }
    }

    /// Why capture is held now, if it is, read afresh each time: paused, the screens asleep,
    /// another user's session in front, or locked.
    private var heldFor: String? {
        if paused { return "Paused" }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return "Waiting (screens asleep)" }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        if (session?[kCGSessionOnConsoleKey as String] as? Bool) == false { return "Waiting (another user)" }
        if screenLocked() { return "Waiting (locked)" }
        return nil
    }

    /// Tells a capture under way to stop at its next window, and the listener whether it may listen,
    /// as soon as either changes. `going`: the system just said the screens are sleeping, another
    /// user is taking the Mac or it's locking, which may not read so yet.
    private func holdCapture(going: Bool = false) {
        let held = going || heldFor != nil
        heldNow.value = held
        audio?.tick(listening: !held && CGPreflightScreenCaptureAccess())
        if held { activity?.reset() }
        guard let capturer else { return }
        Task { await capturer.hold(held) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier, NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        buildMenu()
        log = Logger(path: home + "/logs/capture.log")
        let log = self.log!
        do {
            let store = try CaptureStore(path: home + "/store.sqlite", masterKey: try Keychain.masterKey(log: log.write))
            let capturer = ScreenCapturer(store: store, log: log.write)
            (self.store, self.capturer) = (store, capturer)
            activity = ActivityCapturer(store: store, log: log.write)
            if #available(macOS 26, *) {
                let defaults = self.defaults
                audio = AudioCapturer(store: store, devices: {
                    (defaults.object(forKey: "hearMicrophone") as? Bool ?? false, defaults.object(forKey: "hearSystemAudio") as? Bool ?? true)
                }, log: log.write)
            }
            let exclusionPath = self.exclusionPath
            let heldNow = self.heldNow
            sensors = SensorPlugins(configPath: sensorsPath, store: store, fragments: { Exclusion.load(exclusionPath) },
                                    held: { heldNow.value }, log: log.write)
            holdCapture()
            sensors?.start()
            schedule(capturer: capturer, store: store)
            retain(store)
            log.write("start.ready")
        } catch {
            log.write("start.failed \(String(describing: type(of: error)))")
            problem = error is MasterKeyError ? "The store's key couldn't be read from or kept in the Keychain" : "The capture store couldn't be opened"
        }
        watchSleep()
        // Permissions are asked for when the person chooses to, from the menu or the first-run
        // window's buttons: never at launch.
        refresh()
        if !defaults.bool(forKey: "onboarded") { showOnboarding() }
    }

    private func schedule(capturer: ScreenCapturer, store: CaptureStore) {
        timers.append(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let held = self.heldFor != nil
            self.heldNow.value = held
            let seesScreen = CGPreflightScreenCaptureAccess()
            self.audio?.tick(listening: !held && seesScreen)
            // An erasure a reader held up is finished as soon as the reader lets go (ADR 0002).
            if store.isErasurePending { _ = try? store.finishErasure() }
            // A list that exists but can't be read: nothing is captured until it can be (R8).
            let fragments = Exclusion.load(self.exclusionPath)
            // Activity is noted while capturing, and the lock itself is noted while locked (it
            // carries no app or window). Paused, asleep or another user's: nothing at all.
            if let fragments, !held || (screenLocked() && !self.paused) {
                self.activity?.tick(fragments: fragments, seesScreen: seesScreen)
            }
            Task {
                await capturer.hold(held)
                if !held { await capturer.tick(fragments: fragments) }
            }
            self.refresh()
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.retain(store)
            let log = self.log!
            let heard = self.audio?.takeCounts() ?? (input: 0, output: 0)
            for sensor in self.sensors?.takeCounts() ?? [] {
                log.write("sensors.hour name=\(sensor.name) appended=\(sensor.stats.appended) excluded=\(sensor.stats.excluded) redacted=\(sensor.stats.redacted) invalid=\(sensor.stats.invalid) refused=\(sensor.stats.refused) dropped=\(sensor.dropped)")
            }
            Task {
                let counts = await capturer.takeCounts()
                let average = counts.reads == 0 ? 0 : Int(counts.readMs / Double(counts.reads))
                log.write("capture.hour frames=\(counts.frames) ax_reads=\(counts.axReads) ocr_reads=\(counts.reads) ocr_ms_avg=\(average) audio_in=\(heard.input) audio_out=\(heard.output)")
            }
        })
    }

    /// Retention is a revocation (ADR 0003): what's older than the period is erased, with receipts.
    private func retain(_ store: CaptureStore) {
        do {
            let result = try store.retain(days: Double(retentionDays))
            log.write("retention.done revoked=\(result?.revokedCaptureIds.count ?? 0)")
        } catch {
            log.write("retention.failed")
        }
    }

    /// Asked again at once when the screens sleep or wake, another user takes the Mac or gives it
    /// back, or it locks or unlocks.
    private func watchSleep() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, going) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
                              (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.holdCapture(going: going) }
        }
        let system = DistributedNotificationCenter.default()
        for (name, going) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            system.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in self?.holdCapture(going: going) }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        audioItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        audioItem.isEnabled = false
        pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
        let forgetQuarter = NSMenuItem(title: "Forget the Last 15 Minutes…", action: #selector(forgetQuarterHour), keyEquivalent: "")
        let forgetHour = NSMenuItem(title: "Forget the Last Hour…", action: #selector(forgetHour), keyEquivalent: "")
        hearMicrophoneItem = NSMenuItem(title: "Hear the Microphone", action: #selector(toggleMicrophone), keyEquivalent: "")
        hearSystemAudioItem = NSMenuItem(title: "Hear System Audio", action: #selector(toggleSystemAudio), keyEquivalent: "")
        let exclusions = NSMenuItem(title: "Edit Excluded Apps and Windows…", action: #selector(editExclusions), keyEquivalent: "")
        approveSensorsItem = NSMenuItem(title: "Approve Sensors…", action: #selector(approveSensors), keyEquivalent: "")
        let screenItem = NSMenuItem(title: "Allow Screen Recording…", action: #selector(allowScreen), keyEquivalent: "")
        microphoneItem = NSMenuItem(title: "Allow Microphone…", action: #selector(allowMicrophone), keyEquivalent: "")
        accessibilityItem = NSMenuItem(title: "Allow Accessibility (page addresses)…", action: #selector(allowAccessibility), keyEquivalent: "")
        let connect = NSMenuItem(title: "Connect an Agent", action: nil, keyEquivalent: "")
        connect.submenu = NSMenu()
        for client in Client.allCases {
            let item = NSMenuItem(title: "\(client.name)…", action: #selector(connectAgent(_:)), keyEquivalent: "")
            item.representedObject = client.rawValue
            item.target = self
            connect.submenu?.addItem(item)
        }
        let agents = NSMenuItem(title: "Agents Read…", action: #selector(showAgentsRead), keyEquivalent: "")
        let retention = NSMenuItem(title: "Keep Captures For", action: nil, keyEquivalent: "")
        retentionMenu = NSMenu()
        for days in Self.retentionChoices {
            let item = NSMenuItem(title: Self.span(days).capitalized, action: #selector(setRetention(_:)), keyEquivalent: "")
            item.tag = days
            item.target = self
            retentionMenu.addItem(item)
        }
        retention.submenu = retentionMenu
        let setUp = NSMenuItem(title: "Set Up Presence Capture…", action: #selector(showOnboarding), keyEquivalent: "")
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        for item in [stateItem!, audioItem!, .separator(), pauseItem!, forgetQuarter, forgetHour, .separator(), connect, agents, .separator(),
                     hearMicrophoneItem!, hearSystemAudioItem!, retention, exclusions, approveSensorsItem!, .separator(),
                     screenItem, microphoneItem!, accessibilityItem!, setUp, updates, .separator()] {
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "Quit Presence Capture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    /// The periods the menu offers for Keep Captures For, in days.
    static let retentionChoices = [1, 7, 14, 30, 90, 365]

    static func span(_ days: Int) -> String {
        days == 365 ? "1 year" : days == 1 ? "1 day" : "\(days) days"
    }

    private func refresh() {
        let seesScreen = CGPreflightScreenCaptureAccess()
        let state = problem ?? (!seesScreen ? "Needs Screen Recording" : heldFor ?? "Capturing")
        stateItem.title = state
        pauseItem.title = paused ? "Resume" : "Pause"
        accessibilityItem.isHidden = AXIsProcessTrusted()
        audioItem.title = audio?.state ?? "Not listening (needs macOS 26)"
        microphoneItem.isHidden = audio == nil || AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hearMicrophoneItem.state = hearMicrophone ? .on : .off
        for item in retentionMenu.items { item.state = item.tag == retentionDays ? .on : .off }
        hearSystemAudioItem.state = hearSystemAudio ? .on : .off
        let waiting = sensors?.unapproved.count ?? 0
        approveSensorsItem.isHidden = waiting == 0
        approveSensorsItem.title = waiting == 1 ? "Approve 1 Sensor…" : "Approve \(waiting) Sensors…"
        let symbol = problem != nil || !seesScreen ? "exclamationmark.circle" : paused ? "pause.circle" : "record.circle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Presence Capture: \(state)")
    }

    @objc private func togglePause() {
        paused.toggle()
        refresh()
    }

    @objc private func forgetQuarterHour() { forget(minutes: 15, label: "the last 15 minutes") }
    @objc private func forgetHour() { forget(minutes: 60, label: "the last hour") }

    /// A revocation of the stretch just past (ADR 0002): everything captured in it, and everything
    /// derived from it, erased from disk, with a receipt. It can't be undone, so it's asked first.
    private func forget(minutes: Double, label: String) {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Forget \(label)?"
        alert.informativeText = "Everything captured in \(label), and everything derived from it, is erased from this Mac. This can't be undone."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let now = Date()
        do {
            let result = try store.revoke(scopeKind: "time_range",
                                          scopeValue: "\(CaptureStore.iso(now.addingTimeInterval(-minutes * 60)))/\(CaptureStore.iso(now))",
                                          reason: "forget \(Int(minutes))m")
            activity?.reset()
            log.write("forget.done minutes=\(Int(minutes)) revoked=\(result.revokedCaptureIds.count) on_disk=\(result.erasedOnDisk)" + (result.erasureError == nil ? "" : " erasure_failed"))
            let done = NSAlert()
            done.messageText = "Forgotten"
            done.informativeText = result.erasedOnDisk
                ? "\(result.revokedCaptureIds.count) captures from \(label) were erased."
                : "\(result.revokedCaptureIds.count) captures from \(label) were revoked and can't be read. Their last traces will be erased from disk as soon as the store can finish: an agent may be reading it."
            done.runModal()
        } catch {
            log.write("forget.failed")
            let failed = NSAlert()
            failed.messageText = "Nothing was forgotten"
            failed.informativeText = "The store couldn't revoke \(label). Nothing was changed."
            failed.runModal()
        }
    }

    @objc private func toggleMicrophone() {
        defaults.set(!hearMicrophone, forKey: "hearMicrophone")
        holdCapture()
        refresh()
    }

    @objc private func toggleSystemAudio() {
        defaults.set(!hearSystemAudio, forKey: "hearSystemAudio")
        holdCapture()
        refresh()
    }

    /// Each sensor waiting for approval, shown as exactly what will run, approved one at a time.
    /// Approving pins it as it is on disk now; a later change waits for approval again.
    @objc private func approveSensors() {
        guard let sensors else { return }
        NSApp.activate(ignoringOtherApps: true)
        for sensor in sensors.unapproved {
            let alert = NSAlert()
            alert.messageText = "Run the sensor “\(sensor.name)”?"
            alert.informativeText = [
                sensor.command.joined(separator: " "),
                "Why it's waiting: \(sensor.reason).",
                "It runs with your permissions. What it sends is excluded, redacted and sealed like any capture, "
                    + "but a program you run can do anything you can. Approve it only if you trust it.",
            ].joined(separator: "\n\n")
            alert.addButton(withTitle: "Approve")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { continue }
            do {
                try sensors.approve(sensor.name)
            } catch {
                log.write("sensors.approve_failed name=\(sensor.name)")
            }
        }
        refresh()
    }

    /// The person's own list, opened in their text editor; made with a note on first use.
    @objc private func editExclusions() {
        if !FileManager.default.fileExists(atPath: exclusionPath) {
            try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            let note = """
                # Apps and windows Presence Capture never captures, one a line.
                # A line matches when it appears in an app's name or a window's title, in any case.
                # Saved changes apply within a few seconds. Lines starting with # are notes.
                #
                # 1Password
                # Bank

                """
            FileManager.default.createFile(atPath: exclusionPath, contents: Data(note.utf8))
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: exclusionPath))
    }

    /// Asks once; after that, System Settings is where it's granted (by the person, never by this app).
    @objc private func allowScreen() {
        if !CGRequestScreenCaptureAccess(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refresh()
    }

    @objc private func allowMicrophone() { askForMicrophone(thenHear: false) }

    /// Asks once; after that, System Settings is where it's allowed. From the first-run window,
    /// allowing it is also choosing to be heard, so Hear the Microphone is turned on with it.
    private func askForMicrophone(thenHear: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted && thenHear { self?.defaults.set(true, forKey: "hearMicrophone") }
                    if granted { self?.holdCapture() }
                    self?.refresh()
                }
            }
        case .authorized:
            if thenHear { defaults.set(true, forKey: "hearMicrophone") }
            holdCapture()
            refresh()
        default:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
        }
    }

    // MARK: Agents, retention, set-up and updates (R2)

    /// The first-run window: each permission explained, and connecting an agent. Shown at the
    /// first launch, and from the menu. Closing it, by Done or otherwise, means it isn't shown again.
    @objc private func showOnboarding() {
        windows.show("onboarding", title: "Welcome to Presence Capture", closed: { [weak self] in self?.defaults.set(true, forKey: "onboarded") }) {
            OnboardingView(permissions: { Permissions.now }, canHear: audio != nil,
                           allowScreen: { [weak self] in self?.allowScreen() },
                           allowMicrophone: { [weak self] in self?.askForMicrophone(thenHear: true) },
                           allowAccessibility: { [weak self] in self?.allowAccessibility() },
                           connect: { [weak self] client in self?.connect(client) },
                           done: { [weak self] in self?.windows.close("onboarding") })
        }
    }

    @objc private func connectAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let client = Client(rawValue: raw) else { return }
        connect(client)
    }

    private func connect(_ client: Client) {
        guard let store else { return storeIsClosed() }
        ConnectAgent.run(client, store: store, storePath: home + "/store.sqlite", log: log.write)
    }

    /// Every grant, and what each agent was given: counts from the egress log, never content.
    @objc private func showAgentsRead() {
        guard let store else { return storeIsClosed() }
        let log = self.log!
        windows.show("agents", title: "Agents Read") {
            AgentsReadView(load: { AgentsReadView.Snapshot(grants: try store.grants(), egress: try store.egress(since: Date().addingTimeInterval(-7 * 86_400))) },
                           revoke: { grantId in if try store.revokeGrant(grantId) { log.write("grant.revoked") } })
        }
    }

    /// A shorter period erases what's older now, so it's asked first; a longer one erases nothing yet.
    @objc private func setRetention(_ sender: NSMenuItem) {
        let days = sender.tag
        guard days != retentionDays else { return }
        if days < retentionDays {
            let alert = NSAlert()
            alert.messageText = "Keep captures for \(Self.span(days))?"
            alert.informativeText = "Everything captured more than \(Self.span(days)) ago is erased from this Mac now, and from then on as it ages. This can't be undone."
            alert.addButton(withTitle: "Erase Older Captures")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        defaults.set(days, forKey: "retentionDays")
        log.write("retention.set days=\(days)")
        if let store { retain(store) }
        refresh()
    }

    @objc private func checkForUpdates() { Updates.check() }

    private func storeIsClosed() {
        let alert = NSAlert()
        alert.messageText = "The store isn't open"
        alert.informativeText = problem ?? "Presence Capture couldn't open its store."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func allowAccessibility() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        refresh()
    }

    /// What was heard up to now is kept before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sensors?.stop()
        guard let audio else { return .terminateNow }
        timers.forEach { $0.invalidate() }
        timers = []
        Task { @MainActor in
            await audio.finish()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// A Bool read and written from any thread.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Counts and states only, one line each, timestamped: never what was captured.
final class Logger: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()

    init(path: String) {
        self.path = path
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    }

    @Sendable func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(CaptureStore.iso(Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
