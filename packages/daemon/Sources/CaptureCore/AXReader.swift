import ApplicationServices
import CoreGraphics
import Foundation

/// Reads an app's focused window from Accessibility into AXText.Node, live. Needs the
/// Accessibility permission; nil without it, when the focused window isn't the one titled
/// `title`, or when the tree can't be read before `deadline`.
public enum AXReader {
    /// Asked first, on its own: whether an element is a password field is known before anything
    /// else of it is asked for.
    private static let identity = [kAXRoleAttribute, kAXSubroleAttribute] as [CFString]
    /// Asked only of an element that isn't one.
    private static let content = [
        kAXValueAttribute, kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
        kAXChildrenAttribute, kAXVisibleCharacterRangeAttribute,
    ] as [CFString]
    /// How long one element may take to answer, set on every element asked (a timeout is an
    /// element's own), so a hung window or control can't hold capture past its deadline.
    private static let perElement: Float = 0.25

    public static func focusedWindow(pid: pid_t, title: String, deadline: Date) -> (root: AXText.Node, frame: CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, perElement)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused else { return nil }
        let window = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(window, perElement)
        // Bound to the window that was read: another window in front now gives nothing.
        var windowTitle: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &windowTitle) == .success,
              windowTitle as? String == title else { return nil }
        var visited = 0
        guard let root = node(window, depth: 0, visited: &visited, deadline: deadline), let frame = root.frame else { return nil }
        return (root, frame)
    }

    private static func node(_ element: AXUIElement, depth: Int, visited: inout Int, deadline: Date) -> AXText.Node? {
        guard depth <= AXText.maxDepth, visited < AXText.maxNodes, Date() < deadline else { return nil }
        visited += 1
        AXUIElementSetMessagingTimeout(element, perElement)
        var identityValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, identity as CFArray, [], &identityValues) == .success,
              let ids = identityValues as? [Any], ids.count == identity.count else { return nil }
        // Each attribute of a batch can fail on its own, even when the batch succeeds: a role or
        // subrole that wasn't read leaves whether it's a password field unknown, so nothing of it,
        // or under it, is asked for.
        guard let (role, subrole) = AXText.identity(role: answer(ids[0]), subrole: answer(ids[1])) else {
            return AXText.Node(role: AXText.unreadable)
        }
        // A password field: nothing more of it, or under it, is asked for. Its value is never
        // fetched, not even to be thrown away.
        if AXText.secure.contains(role) || subrole.map(AXText.secure.contains) == true {
            return AXText.Node(role: role, subrole: subrole)
        }
        guard Date() < deadline else { return nil }
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, content as CFArray, [], &values) == .success,
              let list = values as? [Any], list.count == content.count else { return nil }
        func string(_ i: Int) -> String? { list[i] as? String }
        // A text view: only what's scrolled into sight, and nothing of a text area whose sight can't
        // be read.
        let value = AXText.visibleValue(string(0), role: role, visibleRange: cfRange(list[5]))
        var frame: CGRect?
        if let origin = point(list[2]), let size = size(list[3]) { frame = CGRect(origin: origin, size: size) }
        var children: [AXText.Node] = []
        if let elements = list[4] as? [AXUIElement] {
            for child in elements {
                guard let built = node(child, depth: depth + 1, visited: &visited, deadline: deadline) else { continue }
                children.append(built)
            }
        }
        return AXText.Node(role: role, subrole: subrole, value: value, title: string(1), frame: frame, children: children)
    }

    /// One attribute of a batch, as it answered: an error value is absent (no value, unsupported)
    /// or failed (anything else, a timeout included).
    private static func answer(_ item: Any) -> AXText.Answer {
        let ref = item as CFTypeRef
        if CFGetTypeID(ref) == AXValueGetTypeID() {
            let value = item as! AXValue
            guard AXValueGetType(value) == .axError else { return .other }
            var error = AXError.success
            _ = AXValueGetValue(value, .axError, &error)
            return error == .noValue || error == .attributeUnsupported ? .absent : .failed
        }
        return (item as? String).map(AXText.Answer.text) ?? .other
    }

    private static func point(_ value: Any) -> CGPoint? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func size(_ value: Any) -> CGSize? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    private static func cfRange(_ value: Any) -> CFRange? {
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
}
