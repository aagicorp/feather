/// Covers Window/HeaderBar.swift: the state the header shows without a window (the lit layout buttons, the
/// terminal icon for its side, Back/Forward enabled or dimmed, the ink for a light or dark tint, the project
/// name in the search box, the inset for the traffic lights).
import XCTest
@testable import Feather

final class HeaderBarTests: XCTestCase {
    private func alpha(_ color: NSColor?) -> CGFloat { color?.usingColorSpace(.sRGB)?.alphaComponent ?? -1 }
    private func red(_ color: NSColor?) -> CGFloat { color?.usingColorSpace(.sRGB)?.redComponent ?? -1 }

    func testLayoutButtonsAreLitWhileTheirPaneShows() {
        let bar = HeaderBar()
        bar.update(sidebarShown: true, terminalShown: false, terminalOnRight: false)
        XCTAssertEqual(bar.sidebarToggle.alphaValue, 1)
        XCTAssertEqual(bar.terminalToggle.alphaValue, 0.4)
        let bottom = bar.terminalToggle.image?.tiffRepresentation
        XCTAssertNotNil(bottom)

        bar.update(sidebarShown: false, terminalShown: true, terminalOnRight: true)
        XCTAssertEqual(bar.sidebarToggle.alphaValue, 0.4)
        XCTAssertEqual(bar.terminalToggle.alphaValue, 1)
        let right = bar.terminalToggle.image?.tiffRepresentation
        XCTAssertNotEqual(right, bottom, "the icon shows which side the terminal is on")
        XCTAssertEqual(bar.terminalToggle.image?.accessibilityDescription, bar.terminalToggle.toolTip)

        bar.update(sidebarShown: false, terminalShown: true, terminalOnRight: false)
        XCTAssertEqual(bar.terminalToggle.image?.tiffRepresentation, bottom)
    }

    func testBackAndForwardFollowTheHistory() {
        let bar = HeaderBar()
        bar.update(folderName: "Project", canGoBack: true, canGoForward: false)
        XCTAssertTrue(bar.back.isEnabled)
        XCTAssertFalse(bar.forward.isEnabled)
        XCTAssertEqual(alpha(bar.back.contentTintColor), 0.85, accuracy: 0.001)
        XCTAssertEqual(alpha(bar.forward.contentTintColor), 0.35, accuracy: 0.001)
        bar.update(folderName: "Project", canGoBack: false, canGoForward: true)
        XCTAssertFalse(bar.back.isEnabled)
        XCTAssertTrue(bar.forward.isEnabled)
    }

    func testInkFollowsTheTint() {
        let bar = HeaderBar()
        bar.tint = NSColor(hex: 0xFFFFE0)                 // a light project colour: dark ink
        bar.update(folderName: "P", canGoBack: true, canGoForward: true)
        XCTAssertEqual(red(bar.back.contentTintColor), 0, accuracy: 0.001)
        XCTAssertEqual(red(bar.sidebarToggle.contentTintColor), 0, accuracy: 0.001)
        bar.tint = NSColor(hex: 0x3B0764)                 // a dark one: white ink
        bar.update(folderName: "P", canGoBack: true, canGoForward: true)
        XCTAssertEqual(red(bar.back.contentTintColor), 1, accuracy: 0.001)
        bar.tint = nil                                    // the theme's chrome decides
        bar.update(folderName: "P", canGoBack: true, canGoForward: true)
        XCTAssertEqual(red(bar.back.contentTintColor), Settings.shared.theme.isDark ? 1 : 0, accuracy: 0.001)
    }

    func testSearchBoxNamesTheProject() {
        let bar = HeaderBar()
        bar.update(folderName: "My Project", canGoBack: false, canGoForward: false)
        XCTAssertTrue(bar.search.attributedTitle.string.hasSuffix("  My Project"))
        bar.update(folderName: "Ünïcode", canGoBack: false, canGoForward: false)
        XCTAssertTrue(bar.search.attributedTitle.string.hasSuffix("  Ünïcode"))
        XCTAssertTrue(bar.search.toolTip?.contains("⌘P") ?? false)
    }

    func testFullScreenDropsTheTrafficLightInset() throws {
        let bar = HeaderBar()
        let leading = try XCTUnwrap(bar.constraints.first { $0.firstAttribute == .leading && $0.secondItem === bar && $0.firstItem is NSStackView })
        XCTAssertEqual(leading.constant, HeaderBar.trafficLightInset)
        bar.isFullScreen = true
        XCTAssertEqual(leading.constant, 12)
        bar.isFullScreen = false
        XCTAssertEqual(leading.constant, HeaderBar.trafficLightInset)
        XCTAssertEqual(HeaderBar.height, 30)
    }

    func testToolTipsNameTheShortcuts() {
        let bar = HeaderBar()
        XCTAssertEqual(bar.sidebarToggle.toolTip, "Show or Hide the Sidebar (⌘B)")
        XCTAssertEqual(bar.terminalToggle.toolTip, "Show or Hide the Terminal (⌘J)")
        XCTAssertEqual(bar.back.toolTip, "Go Back (⌃-)")
        XCTAssertEqual(bar.forward.toolTip, "Go Forward (⌃⇧-)")
    }
}
