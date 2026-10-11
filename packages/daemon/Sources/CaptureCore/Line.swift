/// One line of a window's text as Vision read it: its words, how sure it was, and its box in the
/// window (normalized, origin at the bottom left, as Vision gives it).
public struct Line: Codable, Equatable, Sendable {
    public var text: String
    public var conf: Double
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(text: String, conf: Double, x: Double, y: Double, w: Double, h: Double) {
        (self.text, self.conf, self.x, self.y, self.w, self.h) = (text, conf, x, y, w, h)
    }
}
