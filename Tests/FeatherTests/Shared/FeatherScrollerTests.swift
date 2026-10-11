/// Shared/FeatherScroller.swift: the app's scroll bars.
import XCTest
@testable import Feather

final class FeatherScrollerTests: XCTestCase {
    /// Where both bars show, the corner between them paints nothing: AppKit's own corner view (a grey wash,
    /// a lighter little box at the bottom right of the sidebar) is hidden.
    func testTheCornerBetweenTheBarsPaintsNothing() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.useFeatherScrollers()
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        scroll.documentView = document
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(scroll)
        scroll.tile()
        scroll.layoutSubtreeIfNeeded()
        let corner = scroll.subviews.filter { !($0 is NSClipView) && !($0 is NSScroller) }
        XCTAssertEqual(corner.count, 1, "AppKit's corner view is there")
        XCTAssertEqual(corner.first?.alphaValue, 1, "and paints until the bars are about to draw")
        scroll.verticalScroller?.viewWillDraw()
        XCTAssertEqual(corner.first?.alphaValue, 0, "transparent from then on")
        scroll.tile()                                                     // tiling again does not bring it back
        scroll.verticalScroller?.viewWillDraw()
        XCTAssertEqual(corner.first?.alphaValue, 0)
        _ = window
    }
}
