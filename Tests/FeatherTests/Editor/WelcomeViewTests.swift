/// Editor/EditorArea.swift, WelcomeView: the welcome page keeps its content in the middle while there is room and
/// scrolls from the top when the editor is shorter than the content, as when the terminal is dragged tall.
import XCTest
@testable import Feather

final class WelcomeViewTests: XCTestCase {
    private func welcome(height: CGFloat) -> WelcomeView {
        let view = WelcomeView()
        view.frame = NSRect(x: 0, y: 0, width: 800, height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testTallEditorCentresTheContent() {
        let view = welcome(height: 900)
        let page = view.scrollViewForTests.documentView!
        XCTAssertEqual(page.frame.height, 900, accuracy: 1, "the page fills the editor")
        let stack = view.stackForTests.frame
        XCTAssertEqual(stack.midY, 450, accuracy: 2, "content in the middle")
        XCTAssertGreaterThan(stack.minY, 28)
    }

    func testShortEditorScrollsFromTheTop() {
        let view = welcome(height: 260)
        let scroll = view.scrollViewForTests
        let page = scroll.documentView!
        let stack = view.stackForTests.frame
        XCTAssertGreaterThan(stack.height, 260, "the content is taller than the editor here")
        XCTAssertEqual(stack.minY, 28, accuracy: 1, "the title starts at the top margin, not above it")
        XCTAssertEqual(page.frame.height, stack.maxY + 28, accuracy: 1, "the page is as tall as the content plus margins")
        XCTAssertGreaterThan(page.frame.height, scroll.contentView.bounds.height, "so it scrolls")
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5, "and starts at the top")
    }
}
