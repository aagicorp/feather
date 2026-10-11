import AppKit

/// The app's scroll bar: a plain rounded knob whose thickness the user chooses in Settings.
/// AppKit asks the *class* how wide a scroller is, which is why the width lives in a static setting.
final class FeatherScroller: NSScroller {
    private var isHovering = false
    private var hoverArea: NSTrackingArea?

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        CGFloat(Settings.shared.scrollBarSize)
    }

    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; needsDisplay = true }

    override func mouseExited(with event: NSEvent) { isHovering = false; needsDisplay = true }

    /// Where a vertical and a horizontal bar meet, AppKit puts a small view of its own that paints a grey wash:
    /// a little lighter box in the corner of the sidebar or the editor. The bars draw no track, so the corner
    /// draws nothing either: it is made fully transparent before the bars draw. (Hiding it would make the
    /// scroll view tile again, and tile again, without end; its alpha the scroll view leaves alone.)
    override func viewWillDraw() {
        super.viewWillDraw()
        guard let scrollView = superview as? NSScrollView else { return }
        let width = FeatherScroller.scrollerWidth(for: controlSize, scrollerStyle: scrollerStyle)
        for view in scrollView.subviews where !(view is NSClipView) && !(view is NSScroller) && view.alphaValue != 0
            && view.frame.width <= width + 1 && view.frame.height <= width + 1 {
            view.alphaValue = 0
        }
    }

    // No track: the bar sits on whatever is behind it, like the rest of the interface.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func draw(_ dirtyRect: NSRect) { drawKnob() }

    override func drawKnob() {
        var knob = rect(for: .knob)
        guard knob.width > 0, knob.height > 0 else { return }
        let inset = max(1.5, min(knob.width, knob.height) * 0.2)
        knob = knob.insetBy(dx: inset, dy: inset)
        let radius = min(knob.width, knob.height) / 2
        let ink = Settings.shared.theme.isDark ? NSColor.white : NSColor.black
        ink.withAlphaComponent(isHovering ? 0.46 : 0.26).setFill()
        NSBezierPath(roundedRect: knob, xRadius: radius, yRadius: radius).fill()
    }
}

extension NSScrollView {
    /// Swaps in the app's scroll bars. Call after `hasVerticalScroller` / `hasHorizontalScroller` are set.
    func useFeatherScrollers() {
        scrollerStyle = .legacy                      // always the same kind of bar, mouse or trackpad
        if hasVerticalScroller, !(verticalScroller is FeatherScroller) { verticalScroller = FeatherScroller() }
        if hasHorizontalScroller, !(horizontalScroller is FeatherScroller) { horizontalScroller = FeatherScroller() }
    }
}

extension NSView {
    /// Gives every scroll view under this view the app's scroll bars, and re-lays them out at the current size.
    /// The terminal keeps its own scroller, which SwiftTerm manages.
    func applyFeatherScrollers() {
        if let scrollView = self as? NSScrollView {
            scrollView.useFeatherScrollers()
            scrollView.tile()
            scrollView.verticalScroller?.needsDisplay = true
            scrollView.horizontalScroller?.needsDisplay = true
        }
        subviews.forEach { $0.applyFeatherScrollers() }
    }
}
