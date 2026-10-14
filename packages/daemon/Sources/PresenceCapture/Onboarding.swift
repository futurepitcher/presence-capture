import AppKit
import ApplicationServices
import AVFoundation
import CaptureConnect
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

/// The first-run window (R2): each permission, what it's for, and a button that asks for it. Nothing
/// is asked until its button is pressed. Then connecting an agent, the five-minute path's last step.
struct OnboardingView: View {
    let permissions: () -> Permissions
    /// Hearing needs macOS 26 (SpeechAnalyzer).
    let canHear: Bool
    /// Whether Hear the Microphone is on: allowed and not heard is a step not yet done.
    let hearing: () -> Bool
    let allowScreen: () -> Void
    let allowMicrophone: () -> Void
    let allowAccessibility: () -> Void
    let connect: (Client) -> Void
    let done: () -> Void

    @State private var allowed = Permissions(screen: false, microphone: false, accessibility: false)
    @State private var heard = false
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
                     "Hears the room, as words, on this Mac. No audio is kept. Off until you allow it here; turn it off any time with Hear the Microphone.",
                     button: allowed.microphone ? "Hear the Microphone" : "Allow and Hear the Microphone…", action: allowMicrophone)
            } else {
                step(2, "Microphone", required: false, done: false, "Hearing needs macOS 26.", button: nil, action: {})
            }
            step(3, "Accessibility", required: false, done: allowed.accessibility,
                 "Reads the address of the page in front and the text of the window in front, more exactly than from pixels.",
                 button: "Allow Accessibility…", action: allowAccessibility)
            VStack(alignment: .leading, spacing: 8) {
                Text("4. Connect an agent").bold()
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
        .onAppear { (allowed, heard) = (permissions(), hearing()) }
        .onReceive(tick) { _ in (allowed, heard) = (permissions(), hearing()) }
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
