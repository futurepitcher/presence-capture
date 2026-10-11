import ApplicationServices
import CoreGraphics
import Foundation

/// Reads an app's focused window from Accessibility into AXText.Node, live. Needs the
/// Accessibility permission; nil without it, when the focused window isn't the one titled
/// `title`, or when the tree can't be read before `deadline`.
public enum AXReader {
    private static let attributes = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXVisibleCharacterRangeAttribute,
    ] as [CFString]

    public static func focusedWindow(pid: pid_t, title: String, deadline: Date) -> (root: AXText.Node, frame: CGRect)? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success, let focused else { return nil }
        let window = focused as! AXUIElement
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
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values) == .success,
              let list = values as? [Any], list.count == attributes.count else { return nil }
        func string(_ i: Int) -> String? { list[i] as? String }
        let role = string(0) ?? ""
        let subrole = string(1)
        // A password field's value is never even fetched into a node.
        let secure = AXText.secure.contains(role) || subrole.map(AXText.secure.contains) == true
        var value = secure ? nil : string(2)
        if let text = value, let range = cfRange(list[7]) {
            // A text view: only what's scrolled into sight.
            let ns = text as NSString
            let start = max(0, min(range.location, ns.length))
            value = ns.substring(with: NSRange(location: start, length: max(0, min(range.length, ns.length - start))))
        }
        var frame: CGRect?
        if let origin = point(list[4]), let size = size(list[5]) { frame = CGRect(origin: origin, size: size) }
        var children: [AXText.Node] = []
        if !secure, let elements = list[6] as? [AXUIElement] {
            for child in elements {
                guard let built = node(child, depth: depth + 1, visited: &visited, deadline: deadline) else { continue }
                children.append(built)
            }
        }
        return AXText.Node(role: role, subrole: subrole, value: value, title: string(3), frame: frame, children: children)
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
