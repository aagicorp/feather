/// Covers Window/FilterPanel.swift: the scoring used by the Command Palette and Go to Symbol, and the order
/// `matches(for:)` gives rows (the given order for nothing typed, best match first otherwise). The panel is
/// built but never shown.
import XCTest
@testable import Feather

final class FilterPanelTests: XCTestCase {
    private typealias Item = FilterPanelController.Item

    private func score(_ query: String, _ text: String) -> Int? {
        FilterPanelController.score(Array(query.lowercased()), in: Array(text.lowercased()))
    }

    func testOnlySubsequencesMatch() {
        XCTAssertNotNil(score("wll", "Wrap Long Lines"))
        XCTAssertNil(score("wlx", "Wrap Long Lines"))
        XCTAssertNotNil(score("", "anything"))
    }

    func testWordStartsAndConsecutiveRunsScoreHigher() {
        XCTAssertGreaterThan(score("wl", "wrap lines")!, score("wl", "wall")!)
        XCTAssertGreaterThan(score("line", "show line numbers")!, score("line", "outline view")!)
        XCTAssertGreaterThan(score("wrap", "wrap long lines")!, score("wrap", "w r a p")!)
        XCTAssertGreaterThan(score("go", "go to line")!, score("go", "toggle output")!)
    }

    func testMatchesKeepTheGivenOrderForNothingTypedAndRankOtherwise() {
        let panel = FilterPanelController(placeholder: "Type")
        panel.setItems([
            Item(title: "View: Toggle Terminal", detail: "⌘J"),
            Item(title: "Settings: Wrap Long Lines", detail: "Off"),
            Item(title: "File: New File", detail: "⌘N"),
            Item(title: "Wrap Lines", detail: "", indent: 1),
        ])
        XCTAssertEqual(panel.matches(for: ""), [0, 1, 2, 3])
        XCTAssertEqual(panel.matches(for: "   "), [0, 1, 2, 3], "spaces alone are nothing")
        XCTAssertEqual(panel.matches(for: "wrap"), [3, 1], "the shorter title first; the terminal has no w-r-a-p")
        XCTAssertEqual(panel.matches(for: "WRAP LINES"), [3, 1])
        XCTAssertEqual(panel.matches(for: "new file"), [2])
        XCTAssertEqual(panel.matches(for: "zzz"), [])
        XCTAssertFalse(panel.isVisible)
    }

    func testEqualScoresKeepTheGivenOrder() {
        let panel = FilterPanelController(placeholder: "Type")
        panel.setItems([Item(title: "Same Thing", detail: ""), Item(title: "Same Thing", detail: ""), Item(title: "Other", detail: "")])
        XCTAssertEqual(panel.matches(for: "same"), [0, 1])
        panel.setItems([Item(title: "Other", detail: "")])
        XCTAssertEqual(panel.matches(for: "same"), [], "replacing the rows drops the old ones")
    }

    func testIndentIsKeptOnTheItem() {
        XCTAssertEqual(Item(title: "x", detail: "").indent, 0)
        XCTAssertEqual(Item(title: "x", detail: "", indent: 3).indent, 3)
    }
}
