import Foundation

/// A plugin's output, split into lines as it arrives, with a limit on how long one line may grow:
/// a program that never sends a newline can't make the app hold more and more of it.
public struct LineBuffer {
    public static let maxLine = 1 << 20

    private var pending = Data()

    public init() {}

    /// The whole lines in what's arrived, in order; nil when a line has run past `maxLine` with no
    /// end (then nothing more of this output should be read).
    public mutating func add(_ chunk: Data) -> [Data]? {
        pending.append(chunk)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            // A line past the limit is refused even when its end came in the same chunk.
            guard pending.distance(from: pending.startIndex, to: end) <= Self.maxLine else {
                pending = Data()
                return nil
            }
            lines.append(Data(pending[pending.startIndex..<end]))
            pending.removeSubrange(pending.startIndex...end)
        }
        guard pending.count <= Self.maxLine else {
            pending = Data()
            return nil
        }
        return lines
    }
}
