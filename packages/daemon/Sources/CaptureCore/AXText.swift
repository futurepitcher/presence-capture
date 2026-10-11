import CoreGraphics

/// A window's text as its app exposes it to Accessibility: exact where OCR guesses, and cheaper.
/// What's read is only what's visible in the window (a text view's visible range, an element
/// inside the window's frame), never the rest of a document scrolled out of sight, and never a
/// password field. The tree is read live by AXReader; deciding what of it to keep is here, so
/// it can be tested without the Accessibility permission.
public enum AXText {
    /// One element of an app's Accessibility tree, as far as reading it needs.
    public struct Node: Equatable, Sendable {
        public var role: String
        public var subrole: String?
        /// Its text: for a text view, only its visible part (AXReader cuts it to AXVisibleCharacterRange).
        public var value: String?
        public var title: String?
        /// Its frame on screen, when it says.
        public var frame: CGRect?
        public var children: [Node]

        public init(role: String, subrole: String? = nil, value: String? = nil, title: String? = nil, frame: CGRect? = nil, children: [Node] = []) {
            (self.role, self.subrole, self.value, self.title, self.frame, self.children) = (role, subrole, value, title, frame, children)
        }
    }

    /// Roles whose value is text someone reads.
    static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell"]
    /// Never read, whatever else is.
    static let secure: Set<String> = ["AXSecureTextField"]

    /// Below this, Accessibility gave too little to stand for the window, and OCR reads it instead.
    public static let enough = 40

    /// Limits on one window, so a huge tree can't stall capture.
    public static let maxNodes = 4000
    public static let maxDepth = 64
    public static let maxCharacters = 100_000

    /// The text visible in `window`, in the tree's order, one element a line; nil when it's too
    /// little to stand for the window (OCR reads it then).
    public static func visibleText(_ root: Node, window: CGRect) -> String? {
        var lines: [String] = []
        var visited = 0
        var characters = 0

        func walk(_ node: Node, depth: Int) {
            guard visited < maxNodes, depth <= maxDepth, characters < maxCharacters else { return }
            visited += 1
            if secure.contains(node.role) || node.subrole.map(secure.contains) == true { return }
            // Out of the window entirely: scrolled away, or another part of the screen.
            if let frame = node.frame, frame.width > 0, frame.height > 0, !frame.intersects(window) { return }
            // Text counts only with a frame on screen inside the window: one with none, or with no
            // size, gives no evidence it's visible (hidden, collapsed, off-screen). A container
            // without one is still walked: its children answer for themselves.
            let shown = node.frame.map { $0.width > 0 && $0.height > 0 && $0.intersects(window) } ?? false
            if shown, textRoles.contains(node.role), let text = (node.value ?? node.title)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                let kept = String(text.prefix(maxCharacters - characters))
                lines.append(kept)
                characters += kept.count
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }

        walk(root, depth: 0)
        let text = lines.joined(separator: "\n")
        return text.filter { !$0.isWhitespace }.count >= enough ? text : nil
    }
}
