import CoreGraphics

/// Which captured window is the focused one: the app's front-most window that's a window at all
/// (shown, and as big as one captured), and only if it was captured. An app can keep something in
/// front that isn't one (Claude's invisible 1512x32 strip over its real window), which is passed
/// over; but a real window in front that wasn't captured (opened since the windows were listed)
/// means none captured is focused, never one behind it.
public enum FrontWindow {
    /// The smallest window captured, in points.
    public static let minWidth = 100.0
    public static let minHeight = 60.0

    /// A window as the window list gives it.
    public struct Listed: Equatable, Sendable {
        public let id: CGWindowID
        public let pid: pid_t
        public let layer: Int
        public let width: Double
        public let height: Double
        public let alpha: Double

        public init(id: CGWindowID, pid: pid_t, layer: Int, width: Double, height: Double, alpha: Double) {
            (self.id, self.pid, self.layer, self.width, self.height, self.alpha) = (id, pid, layer, width, height, alpha)
        }
    }

    public static func of(_ captured: Set<CGWindowID>, pid: pid_t, frontToBack list: [Listed]) -> CGWindowID? {
        let front = list.first { $0.pid == pid && $0.layer == 0 && $0.alpha > 0 && $0.width >= minWidth && $0.height >= minHeight }
        return front.flatMap { captured.contains($0.id) ? $0.id : nil }
    }
}
