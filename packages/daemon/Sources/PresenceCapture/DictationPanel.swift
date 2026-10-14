import AppKit
import FoundationModels
import SwiftUI

/// The small panel at the bottom of the screen while dictating (R2b). It never takes focus, so
/// typing goes where it was going.
final class DictationPanel: DictationShowing {
    final class Model: ObservableObject {
        enum State: Equatable {
            case listening(Float)
            case working
            /// Not typed (the focus moved): the words, to copy if the person chooses.
            case held(String)
            /// Something to say, with nothing held.
            case said(String)
        }
        @Published var state = State.working
    }

    private let model = Model()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 64), styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationPanelView(model: model, close: { [weak self] in self?.hide() }))
        return panel
    }()
    private var hideLater: DispatchWorkItem?

    func listening(_ level: Float) { show(.listening(level)) }
    func working() { show(.working) }
    func hold(_ text: String) { show(.held(text)) }

    /// Said, then gone after a few seconds.
    func say(_ message: String) {
        show(.said(message))
        let later = DispatchWorkItem { [weak self] in self?.hide() }
        hideLater = later
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: later)
    }

    func hide() {
        hideLater?.cancel()
        panel.orderOut(nil)
    }

    private func show(_ state: Model.State) {
        hideLater?.cancel()
        model.state = state
        let size = panel.contentView?.fittingSize ?? NSSize(width: 360, height: 64)
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.minY + 80, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
    }
}

struct DictationPanelView: View {
    @ObservedObject var model: DictationPanel.Model
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .listening(let level):
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Capsule().fill(.secondary.opacity(0.25)).frame(width: 160, height: 6)
                    .overlay(alignment: .leading) { Capsule().fill(.primary).frame(width: 160 * CGFloat(max(0.03, level)), height: 6) }
                Text("Release to type").font(.callout).foregroundStyle(.secondary)
            case .working:
                ProgressView().controlSize(.small)
                Text("Typing…").font(.callout)
            case .held(let text):
                VStack(alignment: .leading, spacing: 6) {
                    Text("The window changed, so this wasn't typed:").font(.caption).foregroundStyle(.secondary)
                    Text(text).lineLimit(4).textSelection(.enabled)
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            close()
                        }
                        Button("Close", action: close)
                    }
                }
            case .said(let message):
                Text(message).font(.callout)
                Button("Close", action: close)
            }
        }
        .padding(14)
        .frame(minWidth: 320, maxWidth: 480, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Tidy what I say" (R2b): the on-device model proposes a tidier text, briefly; the proposal is
/// taken only if DictationText.tidyKeepsMeaning says it changes nothing but by deletion. Unavailable
/// (no Apple Intelligence), or too slow, it's skipped.
@available(macOS 26, *)
enum Tidier {
    /// How long typing waits for a proposal (release-to-text has a 1 s budget in all).
    static let budget: TimeInterval = 0.6

    static let instructions = """
        You tidy dictated text. Remove filler words (um, uh, er, erm, ah) and false starts (a word or phrase said twice in a row), \
        and fix punctuation and capital letters. Change nothing else: never add, remove, replace or reorder any other word. \
        Reply with the tidied text only.
        """

    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func propose(_ text: String) async -> String? {
        guard available else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await LanguageModelSession(instructions: instructions).respond(to: text).content }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
