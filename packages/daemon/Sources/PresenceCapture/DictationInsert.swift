import AppKit
import ApplicationServices
import CaptureCore
import Carbon.HIToolbox

/// An accessibility element, compared as macOS compares them (CFEqual), so the focus at key-down
/// and at release can be told apart.
struct AXElement: Hashable {
    let element: AXUIElement

    static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.element, b.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// The app in front, read on the main thread (it's cheap and doesn't wait on the app).
struct FrontApp: Equatable, Sendable {
    let name: String
    let bundle: String
    let pid: pid_t

    static func now() -> FrontApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return FrontApp(name: app.localizedName ?? "", bundle: app.bundleIdentifier ?? "", pid: app.processIdentifier)
    }
}

/// What dictation sees of where typing goes, at one moment (key-down, release, or just before
/// typing): the focused element, whether it's secure, and the front window's title for the
/// exclusion list (nil when it can't be read).
struct DictationSample: Equatable, @unchecked Sendable {
    var focus: DictationFocus
    var app: FrontApp?
    var window: String?
}

/// Where typing would go (R2b), through Accessibility. Each question to an app waits at most
/// `timeout`, and it's asked off the main thread: an app that doesn't answer never holds up the key,
/// a lock or Pause.
enum Focus {
    static let timeout: Float = 0.25

    static func sample(_ app: FrontApp?) -> DictationSample {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        let element = element(system, kAXFocusedUIElementAttribute)
        let secure = IsSecureEventInputEnabled() || element.map(isSecure) ?? false
        var window: String?
        if let app {
            let owner = AXUIElementCreateApplication(app.pid)
            AXUIElementSetMessagingTimeout(owner, timeout)
            window = self.element(owner, kAXFocusedWindowAttribute).flatMap { string($0, kAXTitleAttribute) }
        }
        return DictationSample(focus: DictationFocus(app: app?.bundle ?? "", element: element.map(AXElement.init), secure: secure),
                               app: app, window: window)
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func isSecure(_ element: AXUIElement) -> Bool {
        string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole || string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}

/// A text field as insertion needs it: the real one through Accessibility, a fake in tests.
protocol TextTarget {
    var value: String? { get }
    /// The selection, in UTF-16 units, as Accessibility gives ranges.
    var selection: CFRange? { get }
    /// Replaces the selection; false when the field refuses (nothing changed).
    func setSelectedText(_ text: String) -> Bool
}

struct AXTextTarget: TextTarget {
    let element: AXUIElement

    var value: String? { Focus.string(element, kAXValueAttribute) }

    var selection: CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }

    func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }
}

/// Typing a dictation in: through Accessibility where the focused element takes it, bound to that
/// element with no clipboard involved; otherwise by pasting, through the one clipboard owner
/// (ClipboardPaster), checked again when the paste's turn comes.
final class Inserter {
    let paster: ClipboardPaster

    init(paster: ClipboardPaster) {
        self.paster = paster
    }

    /// How it went in.
    enum Way: String {
        case accessibility
        /// Accessibility took the text but read back other than expected (a field that reformats
        /// it): it went in, and isn't pasted again.
        case accessibilityUnchecked = "accessibility_unchecked"
        case paste
    }

    /// `done` hears how, or nil when the paste wasn't made (`check` said no when its turn came).
    func type(_ text: String, into element: AXElement?, check: @escaping () -> Bool, done: @escaping (Way?) -> Void) {
        if let element {
            switch Self.insert(text, into: AXTextTarget(element: element.element)) {
            case .inserted: return done(.accessibility)
            case .unchecked: return done(.accessibilityUnchecked)
            case .refused: break
            }
        }
        paster.paste(text, check: check) { restored in done(restored == nil ? nil : .paste) }
    }

    enum AXInsert: Equatable {
        case inserted
        /// Taken, but the field read back other than expected.
        case unchecked
        /// Not taken (or the field can't be checked, so it isn't tried): paste instead.
        case refused
    }

    /// The selection replaced by `text`, checked by reading the value back: it must be exactly the old
    /// value with the selection replaced. A field whose value or selection can't be read isn't tried.
    /// Once the field has taken the text, it's never pasted again, whatever it reads back.
    static func insert(_ text: String, into target: TextTarget) -> AXInsert {
        guard let before = target.value, let range = target.selection, range.location >= 0, range.length >= 0,
              range.location + range.length <= before.utf16.count else { return .refused }
        guard target.setSelectedText(text) else { return .refused }
        let expected = (before as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
        return target.value == expected ? .inserted : .unchecked
    }

    /// ⌘V, posted as the keyboard would (needs Accessibility).
    static func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// The system clipboard, as ClipboardPaster sees it. What a dictation writes is marked transient,
/// so clipboard managers that honour the mark don't keep it.
final class SystemClipboard: Clipboard {
    private let board = NSPasteboard.general
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var changeCount: Int { board.changeCount }

    func snapshot() -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            Dictionary(item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } }) { first, _ in first }
        }
    }

    func restore(_ items: [[String: Data]]) {
        board.clearContents()
        board.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        })
    }

    func write(_ text: String) {
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transient)
        board.writeObjects([item])
    }
}
