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

/// Where typing would go now (R2b).
enum Focus {
    static func now() -> DictationFocus {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let element = focused()
        let secure = IsSecureEventInputEnabled() || element.map(isSecure) ?? false
        return DictationFocus(app: app, element: element.map(AXElement.init), secure: secure)
    }

    static func focused() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

/// Typing a dictation in: through Accessibility where the focused element takes it, bound to that
/// element with no clipboard involved, and checked by reading its value back; otherwise by pasting,
/// through the one clipboard owner (ClipboardPaster).
final class Inserter {
    private let paster: ClipboardPaster

    init(paster: ClipboardPaster) {
        self.paster = paster
    }

    /// How it went in.
    enum Way: String {
        case accessibility
        case paste
    }

    func type(_ text: String, into element: AXElement?) -> Way {
        if let element, Self.insertByAccessibility(text, into: element.element) { return .accessibility }
        paster.paste(text)
        return .paste
    }

    /// The selection replaced by `text`, if the element says it took: its value, read back, is the
    /// old value with the selection replaced (by length, in UTF-16, as ranges are), and holds the text.
    /// An element whose value or selection can't be read isn't tried: it's pasted into instead.
    static func insertByAccessibility(_ text: String, into element: AXUIElement) -> Bool {
        guard let before = Focus.string(element, kAXValueAttribute), let selected = selectedLength(element) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success,
              let after = Focus.string(element, kAXValueAttribute) else { return false }
        return after.utf16.count == before.utf16.count - selected + text.utf16.count && after.contains(text)
    }

    private static func selectedLength(_ element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.length
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
