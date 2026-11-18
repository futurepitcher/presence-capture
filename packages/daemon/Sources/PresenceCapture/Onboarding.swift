import AppKit
import ApplicationServices
import AVFoundation
import CaptureConnect
import CaptureCore
import Combine
import SwiftUI

/// What macOS has allowed the app, read afresh each time.
struct Permissions: Equatable {
    var screen: Bool
    var microphone: Bool
    var accessibility: Bool

    static var now: Permissions {
        Permissions(screen: CGPreflightScreenCaptureAccess(), microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                    accessibility: AXIsProcessTrusted())
    }
}

/// Dictation's step in the first-run window (R2b), as the app gives it.
struct DictationControls {
    let on: () -> Bool
    let turnOn: () -> Void
    let key: () -> DictationKey
    let setKey: (DictationKey) -> Void
    let remember: () -> Bool
    let setRemember: (Bool) -> Void
    /// What macOS does with the Globe key itself, if anything.
    let globeClash: () -> String?
}

/// Keep Captures For, as the first-run window offers it: chosen here, explicitly, with a year unless
/// the person picks another period, Indefinitely among them.
struct RetentionControls {
    let days: () -> Int
    /// A shorter period asks first, as it does from the menu, since it erases what's older.
    let choose: (Int) -> Void
}

/// WhatsApp's step in the first-run window (docs/sources/whatsapp.md): off until turned on here,
/// with its consent, and with past messages only if chosen.
struct WhatsAppControls {
    let status: () -> WhatsAppCapturer.Status
    /// The most days of history that can be brought in, as captures are kept now.
    let maxHistoryDays: () -> Int
    /// Shows the consent; turns it on, bringing in this many days of past messages, only if agreed.
    let turnOn: (Int) -> Void
    /// Where macOS lets the app read WhatsApp's files, when it hasn't yet.
    let openAccess: () -> Void
}

/// The first-run window (R2): each permission, what it's for, and a button that asks for it. Nothing
/// is asked until its button is pressed. Then connecting an agent, the five-minute path's last step.
struct OnboardingView: View {
    let permissions: () -> Permissions
    /// Hearing needs macOS 26 (SpeechAnalyzer).
    let canHear: Bool
    /// Whether Hear the Microphone is on: allowed and not heard is a step not yet done.
    let hearing: () -> Bool
    /// Dictation, on macOS 26; nil before.
    var dictation: DictationControls? = nil
    let allowScreen: () -> Void
    let allowMicrophone: () -> Void
    let allowAccessibility: () -> Void
    /// WhatsApp, built in; nil leaves the step out.
    var whatsApp: WhatsAppControls? = nil
    /// How long captures are kept; nil leaves the step out.
    var retention: RetentionControls? = nil
    let connect: (Client) -> Void
    let done: () -> Void

    @State private var allowed = Permissions(screen: false, microphone: false, accessibility: false)
    @State private var heard = false
    @State private var dictating = false
    @State private var key = DictationKey.fn
    @State private var remembering = true
    @State private var keepDays = AppDelegate.defaultRetentionDays
    @State private var whatsAppStatus = WhatsAppCapturer.Status.off
    /// Past messages to bring in when WhatsApp is turned on here: none unless chosen.
    @State private var historyDays = 0
    @State private var maxHistory = WhatsAppDatabase.historyMaxDays
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Presence Capture remembers what you see, hear and do on this Mac, so an agent you choose can use it.")
                    .font(.title3)
                Text("Everything stays on this Mac, sealed. Nothing is asked for until you press its button.")
                    .foregroundStyle(.secondary)
            }
            step(1, "Screen Recording", required: true, done: allowed.screen,
                 "Reads the text on your screen, on this Mac with Apple's Vision, and hears what this Mac plays. No images are kept.",
                 button: "Allow Screen Recording…", action: allowScreen)
            if canHear {
                step(2, "Microphone", required: false, done: allowed.microphone && heard,
                     "Hears the room, as words, on this Mac. No audio is kept. Off until you allow it here; turn it off any time with Hear the Microphone. "
                        + "It hears everyone near you, not only you: they haven't agreed to this by your installing it, and recording "
                        + "others is governed by law where you are. Telling them, and having their consent, is yours to do.",
                     button: allowed.microphone ? "Hear the Microphone" : "Allow and Hear the Microphone…", action: allowMicrophone)
            } else {
                step(2, "Microphone", required: false, done: false, "Hearing needs macOS 26.", button: nil, action: {})
            }
            step(3, "Accessibility", required: false, done: allowed.accessibility,
                 "Reads the address of the page in front and the text of the window in front, more exactly than from pixels.",
                 button: "Allow Accessibility…", action: allowAccessibility)
            if let dictation { dictationStep(dictation) }
            if let whatsApp { whatsAppStep(whatsApp, number: numbered) }
            if let retention { retentionStep(retention, number: numbered + (whatsApp == nil ? 0 : 1)) }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(numbered + (whatsApp == nil ? 0 : 1) + (retention == nil ? 0 : 1)). Connect an agent").bold()
                Text("It gets a grant of its own, for 30 days. You see the change to its settings before it's made.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    ForEach(Client.allCases, id: \.self) { client in
                        Button(client.name) { connect(client) }
                    }
                }
            }
            HStack {
                Text("Forget the last 15 minutes or hour from the menu at any time.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear(perform: update)
        .onReceive(tick) { _ in update() }
    }

    /// The number of the first step after Dictation's.
    private var numbered: Int { dictation == nil ? 4 : 5 }

    private func update() {
        (allowed, heard) = (permissions(), hearing())
        if let dictation { (dictating, key, remembering) = (dictation.on(), dictation.key(), dictation.remember()) }
        if let whatsApp { (whatsAppStatus, maxHistory) = (whatsApp.status(), whatsApp.maxHistoryDays()) }
        if let retention { keepDays = retention.days() }
    }

    /// Every WhatsApp chat on this Mac, both sides, from WhatsApp Desktop's own files, read-only: off
    /// until turned on here, past messages only if chosen (none by default).
    private func whatsAppStep(_ whatsApp: WhatsAppControls, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(number). WhatsApp (optional, experimental)").bold()
                    Text("Keeps the text of every WhatsApp chat on this Mac, both sides and groups, read from WhatsApp's own files here. "
                         + "Nothing is sent and WhatsApp is never contacted. Skip a chat any time with Exclude WhatsApp Chats… in the menu. "
                         + "The people you talk to haven't agreed to this by your installing it.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                switch whatsAppStatus {
                case .on:
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .off:
                    Button("Capture WhatsApp…") { whatsApp.turnOn(min(historyDays, maxHistory)); update() }
                case .needsAccess:
                    Button("Allow in Privacy Settings…") { whatsApp.openAccess() }
                case .notInstalled, .unknownSchema:
                    EmptyView()
                }
            }
            switch whatsAppStatus {
            case .off:
                Picker("Also bring in past messages", selection: $historyDays) {
                    ForEach(WhatsAppCapturer.historyChoices.filter { $0 <= maxHistory }, id: \.self) { days in
                        Text(days == 0 ? "None (default)" : AppDelegate.span(days)).tag(days)
                    }
                }
                .frame(maxWidth: 360)
                Text("Past messages come from every chat but the ones you exclude, and are kept like anything else captured.")
                    .font(.caption).foregroundStyle(.secondary)
            case .needsAccess:
                Text("macOS hasn't let Presence Capture read WhatsApp's files yet. Turn on Presence Capture under Full Disk Access, then come back.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .notInstalled:
                Text("WhatsApp Desktop isn't on this Mac.").font(.callout).foregroundStyle(.secondary)
            case .unknownSchema:
                Text("This version of WhatsApp Desktop isn't one Presence Capture can read yet, so nothing is read. An update will say when it can.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            case .on:
                EmptyView()
            }
        }
    }

    /// How long what's captured is kept: a year unless chosen here or under Keep Captures For.
    private func retentionStep(_ retention: RetentionControls, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(number). Keep captures for").bold()
            Text("What's older than this is erased from this Mac as it ages, for good. Indefinitely keeps everything "
                 + "until you forget it. Forget, Pause and revoking an agent work the same either way. Change it any time under Keep Captures For.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Keep captures for", selection: Binding(get: { keepDays }, set: { retention.choose($0); update() })) {
                ForEach(AppDelegate.retentionChoices, id: \.self) { days in
                    Text(AppDelegate.span(days).capitalized + (days == AppDelegate.defaultRetentionDays ? " (default)" : "")).tag(days)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
    }

    /// Hold a key and speak: its own permissions, the key, and whether what's said is remembered
    /// (on by default, shown here with its switch, as the maintainer chose).
    private func dictationStep(_ dictation: DictationControls) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("4. Dictation (optional, experimental)").bold()
                    Text("Hold a key and speak, in any app: what you say is typed where the cursor is, heard on this Mac. "
                         + "It asks for the microphone, Input Monitoring (for the key alone: no other key is ever seen) and Accessibility (to type).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if dictating {
                    Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Turn On Dictation…") { dictation.turnOn(); update() }
                }
            }
            if dictating {
                Picker("Hold", selection: Binding(get: { key }, set: { dictation.setKey($0); update() })) {
                    ForEach(DictationKey.allCases, id: \.self) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                if key == .fn, let clash = dictation.globeClash() {
                    Text("When you press Fn (Globe), macOS also \(clash). Hold Right Option or Right Command instead, or set "
                         + "“Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard.")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("Open Keyboard Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
                Toggle("Remember what I dictate", isOn: Binding(get: { remembering }, set: { dictation.setRemember($0); update() }))
                Text("Kept like anything else captured, and forgotten the same way. Never from excluded apps or password fields.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: String, required: Bool, done: Bool, _ why: String, button: String?,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(number). \(title)\(required ? "" : " (optional)")").bold()
                Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if done {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if let button {
                Button(button, action: action)
            }
        }
    }
}

/// One window of each kind, kept while it's open, brought forward when it's asked for again. Used
/// from the main thread, as the rest of the app's AppKit is.
final class Windows {
    private var open: [String: NSWindow] = [:]

    func show<Content: View>(_ name: String, title: String, closed: @escaping () -> Void = {}, _ content: () -> Content) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = open[name] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.center()
        open[name] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            self?.open[name] = nil
            closed()
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ name: String) {
        open[name]?.close()
    }
}
