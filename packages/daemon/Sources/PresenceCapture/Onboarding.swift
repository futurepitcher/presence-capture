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
    let connect: (Client) -> Void
    let done: () -> Void

    @State private var allowed = Permissions(screen: false, microphone: false, accessibility: false)
    @State private var heard = false
    @State private var dictating = false
    @State private var key = DictationKey.fn
    @State private var remembering = true
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
            VStack(alignment: .leading, spacing: 8) {
                Text("\(dictation == nil ? 4 : 5). Connect an agent").bold()
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

    private func update() {
        (allowed, heard) = (permissions(), hearing())
        if let dictation { (dictating, key, remembering) = (dictation.on(), dictation.key(), dictation.remember()) }
    }

    /// Hold a key and speak: its own permissions, the key, and whether what's said is remembered
    /// (on by default, shown here with its switch, as the maintainer chose).
    private func dictationStep(_ dictation: DictationControls) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("4. Dictation (optional)").bold()
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
