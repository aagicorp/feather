/// Shared/Glass.swift: the floating surfaces are glass on macOS 26 and flat panels before it or with Reduce
/// Transparency on; the content fills the surface either way; retinting changes the surface, not the content.
import XCTest
@testable import Feather

final class GlassTests: XCTestCase {
    func testTheSurfaceMatchesTheSystem() {
        let content = NSView()
        let surface = Glass.panel(around: content, cornerRadius: 10, tint: .red)
        var checkedGlass = false
        #if compiler(>=6.2) && !FEATHER_NO_GLASS
        if #available(macOS 26, *), Glass.isActive {
            checkedGlass = true
            let glass = try? XCTUnwrap(surface as? NSGlassEffectView)
            XCTAssertNotNil(glass, "macOS 26 without Reduce Transparency: glass")
            XCTAssertTrue(glass?.contentView === content)
            XCTAssertEqual(glass?.cornerRadius, 10)
            XCTAssertEqual(glass?.tintColor?.alphaComponent ?? 0, Glass.tintAlpha, accuracy: 0.01)
            Glass.retint(surface, .blue)
            XCTAssertEqual(glass?.tintColor?.usingColorSpace(.sRGB)?.blueComponent, 1)
        }
        #else
        XCTAssertFalse(Glass.isBuiltWithGlass, "an older SDK, or -DFEATHER_NO_GLASS: no glass is ever drawn")
        XCTAssertFalse(Glass.isActive)
        #endif
        if !checkedGlass {
            XCTAssertTrue(surface is Glass.FlatPanel)
            XCTAssertTrue(content.superview === surface)
            XCTAssertEqual(surface.layer?.cornerRadius, 10)
            Glass.retint(surface, .blue)
            XCTAssertEqual(surface.layer?.backgroundColor.map { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.blueComponent }, 1)
        }
        surface.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        surface.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.frame.size, surface.bounds.size, "the content fills the surface")
    }

    func testTheWindowChromeSitsOnABackdrop() {
        let before = Settings.shared.glassChrome
        defer { Settings.shared.glassChrome = before }
        Settings.shared.glassChrome = true
        let bar = ActivityBar()
        XCTAssertTrue(bar.subviews.first === bar.backdropForTests, "the backdrop is at the back")
        bar.frame = NSRect(x: 0, y: 0, width: 46, height: 300)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.backdropForTests.frame, bar.bounds)
        let expectGlass = Glass.isActive
        XCTAssertEqual(bar.backdropForTests.isGlassForTests, expectGlass)
        XCTAssertEqual(bar.backdropForTests.tintColorForTests?.alphaComponent ?? -1, expectGlass ? Glass.chromeAlpha : 1, accuracy: 0.01)
        let header = HeaderBar()
        XCTAssertTrue(header.subviews.first === header.backdropForTests)
        // The switch turns it off at once, everywhere.
        Settings.shared.glassChrome = false
        bar.backdropForTests.tint(.red)
        XCTAssertFalse(bar.backdropForTests.isGlassForTests)
        XCTAssertEqual(bar.backdropForTests.tintColorForTests?.alphaComponent, 1)
        XCTAssertEqual(Glass.paneBackground(.red).alpha, 1)
        Settings.shared.glassChrome = true
        if #available(macOS 26, *), Glass.isBuiltWithGlass, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            XCTAssertEqual(Glass.paneBackground(.red).alpha, 0, "panes let the sidebar's glass through")
        } else {
            XCTAssertEqual(Glass.paneBackground(.red).alpha, 1, "no glass: the pane paints its colour")
        }
    }

    func testANoticeCardSitsOnASurface() {
        let card = NoticeCard(kind: "test", symbol: "info.circle", text: "Hello", actions: [], dismissTitle: "OK")
        XCTAssertTrue(card.subviews.first === card.surfaceForTests, "the surface is under everything else")
        XCTAssertEqual(card.layer?.backgroundColor.map { NSColor(cgColor: $0)?.alphaComponent }, 0, "the card itself is clear; the surface is the ground")
    }

    // MARK: - Floating panels (Window/FloatingPanel.swift)

    func testAFloatingPanelStandsOffItsEdgesAndItsContentFillsIt() {
        let content = NSViewController()
        content.view = NSView()
        let panel = FloatingPanelController(content: content)
        panel.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        panel.setInsets(top: 6, leading: 0, bottom: 0, trailing: 6)
        panel.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.panel.frame, NSRect(x: 0, y: 0, width: 394, height: 294))
        XCTAssertEqual(content.view.frame.size, panel.panel.bounds.size, "the content fills the panel")
        XCTAssertTrue(content.parent === panel)
        XCTAssertEqual(panel.panel.layer?.cornerRadius, FloatingPanelController.cornerRadius)
        XCTAssertEqual(panel.panel.layer?.masksToBounds, true)
        panel.setInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        panel.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.panel.frame, NSRect(x: 6, y: 6, width: 388, height: 288))
        XCTAssertEqual(panel.insetsForTests.left, 6)
    }

    func testAPanelIsTranslucentOnlyOverGlass() {
        let content = NSViewController()
        content.view = NSView()
        let panel = FloatingPanelController(content: content)
        _ = panel.view
        let theme = Settings.shared.theme
        let alpha = panel.panel.layer?.backgroundColor?.alpha ?? -1
        XCTAssertEqual(alpha, Glass.isActive ? Glass.surfaceAlpha : 1, accuracy: 0.01)
        XCTAssertEqual(Glass.surface(theme.background).alphaComponent, Glass.isActive ? Glass.surfaceAlpha : 1, accuracy: 0.01)
        XCTAssertGreaterThan(Glass.surfaceAlpha, Glass.chromeAlpha, "text is read against the panels, so they are less see-through than the chrome")
    }

    func testTheGapBetweenPanelsIsTheDivider() {
        let split = GapSplitView()
        XCTAssertEqual(split.dividerThickness, GapSplitView.gap)
        XCTAssertEqual(GapSplitView.gap, 6)
        split.frame = NSRect(x: 0, y: 0, width: 100, height: 10)
        let image = NSImage(size: split.frame.size, flipped: false) { _ in
            split.drawDivider(in: NSRect(x: 0, y: 0, width: 100, height: 6))
            return true
        }
        XCTAssertNotNil(image, "drawing the divider draws nothing and does not fail")
    }

    func testTheWindowLaysItsPanelsOutWithGaps() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 1000, height: 700), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(controller.editorItem.viewController === controller.editorPanel)
        XCTAssertTrue(controller.terminalItem.viewController === controller.terminalPanel)
        XCTAssertTrue(controller.innerSplit.splitView is GapSplitView)
        XCTAssertNotNil(controller.rootBackdrop, "the glass behind everything, seen in the gaps")
        // Terminal hidden: the editor stands off the bottom edge; shown below the editor: the divider is the gap.
        XCTAssertTrue(controller.terminalItem.isCollapsed)
        XCTAssertEqual(controller.editorPanel.insetsForTests.bottom, GapSplitView.gap)
        XCTAssertEqual(controller.editorPanel.insetsForTests.left, 0, "the divider to the sidebar is the gap")
        controller.terminalItem.isCollapsed = false
        XCTAssertEqual(controller.editorPanel.insetsForTests.bottom, 0)
        XCTAssertEqual(controller.terminalPanel.insetsForTests.top, 0)
        XCTAssertEqual(controller.terminalPanel.insetsForTests.bottom, GapSplitView.gap)
        XCTAssertEqual(controller.terminalPanel.insetsForTests.left, controller.editorPanel.insetsForTests.left, "the terminal's left edge is the editor's")
        XCTAssertEqual(controller.terminalPanel.insetsForTests.right, controller.editorPanel.insetsForTests.right)
        controller.sidebarItem.isCollapsed = true
        XCTAssertEqual(controller.editorPanel.insetsForTests.left, GapSplitView.gap, "no sidebar: the editor stands off the activity bar")
        XCTAssertEqual(controller.terminalPanel.insetsForTests.left, GapSplitView.gap)
        XCTAssertNil(controller.sidebarContainer.view.subviews.first { $0 is Glass.Backdrop }, "the sidebar has no glass of its own: it is a card on the window's")
        XCTAssertTrue(controller.sidebarItem.viewController === controller.sidebarPanel)
        XCTAssertEqual(controller.sidebarPanel.surface, \.chrome, "the sidebar card is the chrome colour, the editor's the background")
        XCTAssertEqual(controller.sidebarPanel.insetsForTests.left, GapSplitView.gap, "off the activity bar")
        XCTAssertEqual(controller.sidebarPanel.insetsForTests.right, 0, "the divider to the editor is the gap")
        window.close()
    }
}
