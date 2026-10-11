/// Covers Window/ActivityBar.swift: the count on an icon (the changed files on Source Control), kept when the
/// icons are replaced, "99+" past two digits, and the tooltip that says it.
import XCTest
@testable import Feather

final class ActivityBarTests: XCTestCase {
    private func buttons(_ bar: ActivityBar) -> [ActivityButton] {
        bar.subviews.compactMap { $0 as? NSStackView }.first?.arrangedSubviews.compactMap { $0 as? ActivityButton } ?? []
    }

    func testTheCountSitsOnTheIconAndSurvivesNewItems() {
        let bar = ActivityBar()
        bar.setItems(SidebarContainerViewController.builtInItems)
        let index = SidebarContainerViewController.sourceControlPane
        XCTAssertEqual(bar.badge(at: index), 0)
        bar.setBadge(3, at: index)
        XCTAssertEqual(bar.badge(at: index), 3)
        let button = buttons(bar)[index]
        XCTAssertEqual(button.badge, 3)
        XCTAssertEqual(button.toolTip, "Source Control (⌃⇧G) — 3 changes")
        bar.setBadge(1, at: index)
        XCTAssertEqual(button.toolTip, "Source Control (⌃⇧G) — 1 change")

        // An extension pane arriving replaces the icons; the count stays.
        bar.setItems(SidebarContainerViewController.builtInItems + [.init(symbol: "network", tooltip: "API")])
        XCTAssertEqual(buttons(bar)[index].badge, 1)
        XCTAssertEqual(buttons(bar).count, SidebarContainerViewController.builtInItems.count + 1)

        bar.setBadge(0, at: index)
        XCTAssertEqual(buttons(bar)[index].badge, 0)
        XCTAssertEqual(buttons(bar)[index].toolTip, "Source Control (⌃⇧G)")
    }

    func testACountPastTwoDigitsIsCapped() {
        XCTAssertEqual(ActivityButton.badgeText(7), "7")
        XCTAssertEqual(ActivityButton.badgeText(99), "99")
        XCTAssertEqual(ActivityButton.badgeText(100), "99+")
    }

    func testTheBadgeDrawsWithoutAWindow() {
        let bar = ActivityBar()
        bar.setItems(SidebarContainerViewController.builtInItems)
        bar.setBadge(12, at: SidebarContainerViewController.sourceControlPane)
        let button = buttons(bar)[SidebarContainerViewController.sourceControlPane]
        let image = NSImage(size: button.bounds.size)
        image.lockFocus()
        button.draw(button.bounds)
        image.unlockFocus()
        XCTAssertNotNil(image.tiffRepresentation)
    }
}
