import Foundation
@testable import CaptureCore
import XCTest

/// A plugin's output, split into lines, with a limit on one line.
final class LineBufferTests: XCTestCase {
    func testSplitsLinesAcrossChunks() throws {
        var buffer = LineBuffer()
        XCTAssertEqual(try XCTUnwrap(buffer.add(Data("{\"a\":1}\n{\"b\"".utf8))), [Data("{\"a\":1}".utf8)])
        XCTAssertEqual(try XCTUnwrap(buffer.add(Data(":2}\n\n".utf8))), [Data("{\"b\":2}".utf8), Data()])
    }

    func testALineThatNeverEndsIsCutOffNotHeld() throws {
        var buffer = LineBuffer()
        let chunk = Data(repeating: UInt8(ascii: "a"), count: 64 * 1024)
        var fed = 0
        while fed <= LineBuffer.maxLine {
            guard buffer.add(chunk) != nil else { break }
            fed += chunk.count
        }
        XCTAssertLessThanOrEqual(fed, LineBuffer.maxLine, "a line past the limit was still held")
        // Past the limit and ended in the same chunk: still refused.
        var ended = LineBuffer()
        XCTAssertNil(ended.add(Data(repeating: UInt8(ascii: "a"), count: LineBuffer.maxLine + 10) + Data("\n".utf8)))
        // A long line that does end, under the limit, is still read.
        var other = LineBuffer()
        XCTAssertEqual(try XCTUnwrap(other.add(Data(repeating: UInt8(ascii: "b"), count: 1000) + Data("\n".utf8))).count, 1)
    }
}
