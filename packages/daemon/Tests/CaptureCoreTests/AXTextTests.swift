import CoreGraphics
import XCTest

@testable import CaptureCore

final class AXTextTests: XCTestCase {
    private let window = CGRect(x: 100, y: 100, width: 800, height: 600)
    private typealias Node = AXText.Node

    private func text(_ value: String, at y: CGFloat = 200) -> Node {
        Node(role: "AXStaticText", value: value, frame: CGRect(x: 120, y: y, width: 400, height: 20))
    }

    private let paragraph = "The quarterly plan ships the erasure work by Friday, then the native daemon."

    func testReadsTheVisibleTextInTheTreesOrder() {
        let root = Node(role: "AXWindow", frame: window, children: [
            Node(role: "AXWebArea", frame: window, children: [
                Node(role: "AXHeading", title: "Q4 plan", frame: CGRect(x: 120, y: 150, width: 300, height: 30)),
                text(paragraph),
            ]),
        ])
        XCTAssertEqual(AXText.visibleText(root, window: window), "Q4 plan\n\(paragraph)")
    }

    func testNeverReadsAPasswordField() {
        let root = Node(role: "AXWindow", frame: window, children: [
            text(paragraph),
            Node(role: "AXSecureTextField", value: "hunter2hunter2", frame: CGRect(x: 120, y: 300, width: 200, height: 20)),
            Node(role: "AXTextField", subrole: "AXSecureTextField", value: "correct horse battery", frame: CGRect(x: 120, y: 340, width: 200, height: 20)),
            // A container marked secure: nothing under it either.
            Node(role: "AXGroup", subrole: "AXSecureTextField", children: [text("inside a secure group")]),
        ])
        let out = AXText.visibleText(root, window: window) ?? ""
        XCTAssertFalse(out.contains("hunter2"))
        XCTAssertFalse(out.contains("correct horse"))
        XCTAssertFalse(out.contains("inside a secure group"))
    }

    func testLeavesWhatsScrolledOutOfTheWindow() {
        let root = Node(role: "AXWindow", frame: window, children: [
            text(paragraph),
            text("Far below, never on screen: the bank PIN is 4417.", at: 5000),
        ])
        let out = AXText.visibleText(root, window: window) ?? ""
        XCTAssertTrue(out.contains("quarterly plan"))
        XCTAssertFalse(out.contains("4417"), "text outside the window's frame was kept")
    }

    func testReadsNoTextWithoutEvidenceItsVisible() {
        let root = Node(role: "AXWindow", frame: window, children: [
            text(paragraph),
            Node(role: "AXStaticText", value: "No frame at all: the hidden PIN is 4417."),
            Node(role: "AXStaticText", value: "Collapsed to nothing: the hidden PIN is 4417.", frame: CGRect(x: 120, y: 300, width: 0, height: 20)),
            Node(role: "AXStaticText", value: "No height: the hidden PIN is 4417.", frame: CGRect(x: 120, y: 340, width: 300, height: 0)),
            // A container with no frame of its own is still walked; its visible child is read.
            Node(role: "AXGroup", children: [text("Inside a frameless group, and on screen.", at: 400)]),
        ])
        let out = AXText.visibleText(root, window: window) ?? ""
        XCTAssertFalse(out.contains("4417"), "text with no evidence it was visible was kept")
        XCTAssertTrue(out.contains("Inside a frameless group"))
    }

    func testGivesWayToOCRWhenThereIsTooLittle() {
        // A canvas app, say: a window whose tree has a title and little else.
        let root = Node(role: "AXWindow", frame: window, children: [text("Untitled")])
        XCTAssertNil(AXText.visibleText(root, window: window))
    }

    func testStopsAtItsLimits() {
        let wide = Node(role: "AXWindow", frame: window, children: (0..<(AXText.maxNodes * 2)).map { text("line \($0) of a very long list of things", at: 200) })
        let lines = AXText.visibleText(wide, window: window)?.split(separator: "\n") ?? []
        XCTAssertLessThan(lines.count, AXText.maxNodes, "read past the node limit")

        var deep = text(paragraph)
        for _ in 0..<(AXText.maxDepth * 2) { deep = Node(role: "AXGroup", children: [deep]) }
        XCTAssertNil(AXText.visibleText(Node(role: "AXWindow", frame: window, children: [deep]), window: window), "read past the depth limit")
    }

    func testAnElementWhoseRoleOrSubroleWasntReadIsUnknownNotOpen() {
        let field = AXText.Answer.text("AXTextField")
        XCTAssertEqual(AXText.identity(role: field, subrole: .absent)?.subrole, nil)
        XCTAssertEqual(AXText.identity(role: field, subrole: .absent)?.role, "AXTextField")
        XCTAssertEqual(AXText.identity(role: field, subrole: .text("AXSecureTextField"))?.subrole, "AXSecureTextField")
        XCTAssertNil(AXText.identity(role: field, subrole: .failed), "a subrole that failed was taken as absent")
        XCTAssertNil(AXText.identity(role: .failed, subrole: .absent))
        XCTAssertNil(AXText.identity(role: .absent, subrole: .absent), "an element with no role")
        XCTAssertNil(AXText.identity(role: .other, subrole: .absent))
        // What's read in its place stands for nothing: no text of it, or under it.
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tree = AXText.Node(role: "AXWindow", frame: window, children: [
            AXText.Node(role: AXText.unreadable, frame: CGRect(x: 10, y: 10, width: 200, height: 20)),
            AXText.Node(role: "AXStaticText", value: String(repeating: "visible words ", count: 5), frame: CGRect(x: 10, y: 40, width: 400, height: 20)),
        ])
        XCTAssertEqual(AXText.visibleText(tree, window: window), String(repeating: "visible words ", count: 5).trimmingCharacters(in: .whitespaces))
    }

    func testATextAreaWhoseVisibleRangeCantBeReadKeepsNothing() {
        let text = "shown part, and much more scrolled out of sight"
        XCTAssertEqual(AXText.visibleValue(text, role: "AXTextArea", visibleRange: CFRange(location: 0, length: 10)), "shown part")
        XCTAssertNil(AXText.visibleValue(text, role: "AXTextArea", visibleRange: nil), "a text area's whole value was kept")
        XCTAssertNil(AXText.visibleValue(text, role: "AXTextArea", visibleRange: CFRange(location: -1, length: 4)))
        XCTAssertEqual(AXText.visibleValue("a label", role: "AXStaticText", visibleRange: nil), "a label")
        XCTAssertEqual(AXText.visibleValue(text, role: "AXTextArea", visibleRange: CFRange(location: (text as NSString).length - 8, length: 100)), "of sight", "a range running past the end")
    }
}
