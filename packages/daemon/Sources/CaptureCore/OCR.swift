import CoreGraphics
import CryptoKit
import Foundation
import Vision

/// Reading a window's image: its text line by line (Vision, on this Mac), and a hash that tells an
/// unchanged window from a changed one, pixel for pixel, so only an unchanged one isn't read again.
public enum OCR {
    /// The text, top to bottom and left to right within a line, each with how sure Vision was and
    /// its box (0–1, origin bottom left, as Vision gives it).
    public static func read(_ image: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Line(text: best.string, conf: rounded(Double(best.confidence), 2), x: rounded(box.minX, 4), y: rounded(box.minY, 4),
                        w: rounded(box.width, 4), h: rounded(box.height, 4))
        }
        return ordered(lines)
    }

    /// How far below a row's top line another can sit and still be on its row (a window's
    /// thousandths: a slanted or uneven baseline).
    static let rowSlack = 0.005

    /// Lines as they read: rows from the top, each left to right. Rows are formed first, from the
    /// top down, each beginning at its highest line, so the order is the same however the lines came.
    static func ordered(_ lines: [Line]) -> [Line] {
        var rows: [[Line]] = []
        for line in lines.sorted(by: { ($0.y, -$0.x) > ($1.y, -$1.x) }) {
            if let top = rows.last?.first, top.y - line.y <= rowSlack {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { ($0.x, $0.y) < ($1.x, $1.y) } }
    }

    /// Vision's numbers come from floats, so stored whole they carry a dozen digits of noise
    /// (0.30000001192092896): to a ten-thousandth of a window is finer than a pixel.
    static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    /// Every pixel of the image, exactly, with its size: a change of a few pixels (a new chat
    /// line, one digit) is a change, so a window's text is never kept past what it shows.
    public static func hash(_ image: CGImage) -> String {
        // No pixels to read: a hash nothing matches, so the window is read.
        guard let pixels = image.dataProvider?.data else { return UUID().uuidString }
        var hasher = SHA256()
        hasher.update(data: Data("\(image.width)x\(image.height)x\(image.bytesPerRow)x\(image.bitsPerPixel)".utf8))
        hasher.update(data: pixels as Data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
