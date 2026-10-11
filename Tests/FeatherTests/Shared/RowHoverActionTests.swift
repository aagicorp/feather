/// Covers Shared/RowHoverAction.swift: the one action offered on a list's rows — which rows it applies to, that
/// it does nothing while switched off, and the context menu it installs on the table.
import XCTest
@testable import Feather

final class RowHoverActionTests: XCTestCase {
    private func makeTable() -> NSTableView {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        return table
    }

    func testTriggerRunsOnlyOnEligibleRows() {
        let table = makeTable()
        var performed: [Int] = []
        let action = RowHoverAction(table: table, title: "Replace", toolTip: "tip", isEligible: { $0 % 2 == 0 }, perform: { performed.append($0) })
        action.trigger(row: 0)
        action.trigger(row: 1)
        action.trigger(row: 4)
        XCTAssertEqual(performed, [0, 4])
    }

    func testSwitchedOffItDoesNothing() {
        let table = makeTable()
        var performed: [Int] = []
        let action = RowHoverAction(table: table, title: "Replace", toolTip: "tip", isEligible: { _ in true }, perform: { performed.append($0) })
        action.isEnabled = false
        action.trigger(row: 3)
        XCTAssertEqual(performed, [])
        action.isEnabled = true
        action.trigger(row: 3)
        XCTAssertEqual(performed, [3])
    }

    func testTitleAndEligibilityClosuresSeeTheRow() {
        let table = makeTable()
        var asked: [Int] = []
        var titled: [Int] = []
        let action = RowHoverAction(table: table, toolTip: "tip",
                                    title: { titled.append($0); return $0 == 0 ? "Replace All in File" : "Replace" },
                                    isEligible: { asked.append($0); return $0 != 1 }, perform: { _ in })
        XCTAssertEqual(titled, [0], "the button starts with the title for the first row")
        action.trigger(row: 1)
        action.trigger(row: 2)
        XCTAssertEqual(asked, [1, 2])
    }

    func testItOwnsTheTablesContextMenu() {
        let table = makeTable()
        let action = RowHoverAction(table: table, title: "Open", toolTip: "tip", isEligible: { _ in true }, perform: { _ in })
        XCTAssertTrue(table.menu?.delegate === action)
        // Without a clicked row (no click happened) the menu offers nothing.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "stale", action: nil, keyEquivalent: ""))
        action.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.count, 0)
        XCTAssertEqual(table.subviews.filter { $0 is NSButton }.count, 1, "one button, moved from row to row")
        XCTAssertEqual((table.subviews.first { $0 is NSButton } as? NSButton)?.isHidden, true)
    }

    func testTheSingleTitleConvenienceUsesThatTitleForEveryRow() {
        let table = makeTable()
        _ = RowHoverAction(table: table, title: "Revert", toolTip: "tip", isEligible: { _ in true }, perform: { _ in })
        XCTAssertEqual((table.subviews.first { $0 is NSButton } as? NSButton)?.title, "Revert")
        XCTAssertEqual((table.subviews.first { $0 is NSButton } as? NSButton)?.toolTip, "tip")
    }
}
