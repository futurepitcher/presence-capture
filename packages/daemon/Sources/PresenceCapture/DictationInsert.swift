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
/// a lock or Pause. A sample is consistent or it's unknown: the front window is read before and after
/// the focused element, the element must be in it, and all of it within `consistentWithin`; anything
/// else is unknown (no element, security unknown, no window title), and unknown is never typed into
/// or kept.
enum Focus {
    static let timeout: Float = 0.25
    static let consistentWithin: TimeInterval = 0.5

    static func sample(_ app: FrontApp?) -> DictationSample {
        let started = Date()
        let unknown = DictationSample(focus: DictationFocus(app: app?.bundle ?? "", element: nil, security: .unknown), app: app, window: nil)
        guard let app else { return unknown }
        let owner = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(owner, timeout)
        let windowBefore = element(owner, kAXFocusedWindowAttribute)
        let focused = element(owner, kAXFocusedUIElementAttribute)
        let windowAfter = element(owner, kAXFocusedWindowAttribute)
        guard let focused, let windowBefore, let windowAfter, CFEqual(windowBefore, windowAfter) else { return unknown }
        if let inside = element(focused, kAXWindowAttribute), !CFEqual(inside, windowAfter) { return unknown }
        let title = string(windowAfter, kAXTitleAttribute)
        let security = IsSecureEventInputEnabled() ? .secure : security(of: focused)
        guard Date().timeIntervalSince(started) <= consistentWithin else { return unknown }
        return DictationSample(focus: DictationFocus(app: app.bundle, element: AXElement(element: focused), security: security), app: app, window: title)
    }

    /// Whether `element` still has the app's focus, read now (off the main thread).
    static func stillFocused(_ element: AXUIElement, in app: FrontApp?) -> Bool {
        guard let app else { return false }
        let owner = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(owner, timeout)
        return self.element(owner, kAXFocusedUIElementAttribute).map { CFEqual($0, element) } ?? false
    }

    static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// Secure by its role, open, or unknown when Accessibility doesn't say.
    static func security(of element: AXUIElement) -> DictationFocus.Security {
        let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
        if role == nil && subrole == nil { return .unknown }
        return subrole == kAXSecureTextFieldSubrole || role == "AXSecureTextField" ? .secure : .open
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
/// (ClipboardPaster). Either way it's checked first (`check`, answered on the main thread), and
/// Accessibility is asked off the main thread, on its own queue, where `proceed` is asked again just
/// before the field is changed.
final class Inserter {
    let paster: ClipboardPaster
    private static let queue = DispatchQueue(label: "presence.capture.dictation.ax")

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

    /// `done` (on the main thread) hears how, or nil when it wasn't typed in: `check` said no, or
    /// `proceed` did just before the field would have been changed.
    func type(_ text: String, into element: AXElement?, check: @escaping (@escaping (Bool) -> Void) -> Void,
              proceed: @escaping () -> Bool, done: @escaping (Way?) -> Void) {
        let pasteIt = { [paster] in paster.paste(text, check: check) { done($0 == nil ? nil : .paste) } }
        guard let element else { return pasteIt() }
        check { allowed in
            guard allowed else { return done(nil) }
            Self.queue.async {
                let result = Self.insert(text, into: AXTextTarget(element: element.element), proceed: proceed)
                DispatchQueue.main.async {
                    switch result {
                    case .inserted: done(.accessibility)
                    case .unchecked: done(.accessibilityUnchecked)
                    case .stopped: done(nil)
                    case .refused: pasteIt()
                    }
                }
            }
        }
    }

    enum AXInsert: Equatable {
        case inserted
        /// Taken, but the field read back other than expected.
        case unchecked
        /// Not taken (or the field can't be checked, so it isn't tried): paste instead.
        case refused
        /// `proceed` said no just before the field would have changed: not typed, and not pasted.
        case stopped
    }

    /// The selection replaced by `text`, checked by reading the value back: it must be exactly the old
    /// value with the selection replaced. A field whose value or selection can't be read isn't tried.
    /// `proceed` is asked after those reads, just before the field is changed. Once the field has
    /// taken the text, it's never pasted again, whatever it reads back.
    static func insert(_ text: String, into target: TextTarget, proceed: () -> Bool = { true }) -> AXInsert {
        guard let before = target.value, let range = target.selection, range.location >= 0, range.length >= 0,
              range.location + range.length <= before.utf16.count else { return .refused }
        guard proceed() else { return .stopped }
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
