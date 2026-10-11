/// Editor/TabBarView.swift: the bar keeps its tab views across reloads, updating them in place, adding and
/// dropping only at the end, and a reload that changes nothing touches nothing.
import XCTest
@testable import Feather

final class TabBarViewTests: XCTestCase {
    private func info(_ title: String, dirty: Bool = false) -> TabInfo { TabInfo(title: title, icon: nil, toolTip: "/\(title)", isDirty: dirty) }

    func testViewsAreReusedAcrossReloads() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        bar.reload(tabs: [info("a.swift"), info("b.swift"), info("c.swift")], selected: 0)
        let first = bar.itemViewsForTests
        XCTAssertEqual(first.count, 3)
        bar.reload(tabs: [info("a.swift"), info("b.swift"), info("c.swift"), info("d.swift")], selected: 3)
        let more = bar.itemViewsForTests
        XCTAssertEqual(more.count, 4)
        XCTAssertTrue(zip(first, more).allSatisfy { $0 === $1 }, "the three views that were there are the same objects")
        bar.reload(tabs: [info("a.swift"), info("b.swift", dirty: true)], selected: 1)
        let fewer = bar.itemViewsForTests
        XCTAssertEqual(fewer.count, 2)
        XCTAssertTrue(fewer[0] === first[0] && fewer[1] === first[1])
        XCTAssertNil(more[2].superview, "a dropped view leaves the bar")
        bar.reload(tabs: [info("a.swift"), info("b.swift", dirty: true)], selected: 1)
        XCTAssertTrue(bar.itemViewsForTests[0] === fewer[0], "an unchanged reload keeps everything")
    }

    func testClosingAndSelectingReachTheRightIndexAfterAReload() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 600, height: TabBarView.height))
        var selected: [Int] = [], closed: [Int] = []
        bar.onSelect = { selected.append($0) }
        bar.onClose = { closed.append($0) }
        bar.reload(tabs: [info("a"), info("b"), info("c")], selected: 0)
        bar.reload(tabs: [info("b"), info("c")], selected: 0)       // "a" closed: the views shift down one index
        bar.itemViewsForTests[1].onSelect?()
        bar.itemViewsForTests[0].onClose?()
        XCTAssertEqual(selected, [1])
        XCTAssertEqual(closed, [0])
    }
}
