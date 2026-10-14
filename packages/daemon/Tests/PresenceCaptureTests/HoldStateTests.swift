import Foundation
@testable import PresenceCapture
import XCTest

/// A Pause is seen by a screen capture under way at once, and what it read across one isn't kept.
final class HoldStateTests: XCTestCase {
    func testAHoldIsCountedSoWorkBegunBeforeItIsntKeptAfterIt() {
        let holding = HoldState()
        let began = holding.now.holds
        XCTAssertFalse(holding.now.held)
        holding.set(true)
        XCTAssertTrue(holding.now.held, "a Pause wasn't seen at once")
        holding.set(true)
        holding.set(false)
        // Let go again before the capture under way finished: it still began before the hold.
        XCTAssertFalse(holding.now.held)
        XCTAssertEqual(holding.now.holds, began + 1, "a capture begun before a Pause would be kept after it")
        holding.set(false)
        XCTAssertEqual(holding.now.holds, began + 1, "letting go counted as a hold")
    }

    func testItsReadFromAnyThread() {
        let holding = HoldState()
        DispatchQueue.concurrentPerform(iterations: 1000) { i in holding.set(i % 2 == 0) }
        holding.set(false)
        XCTAssertFalse(holding.now.held)
        XCTAssertGreaterThan(holding.now.holds, 0)
    }
}
