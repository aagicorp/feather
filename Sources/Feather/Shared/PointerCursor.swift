import AppKit
import SwiftTerm

/// Shows the pointing-hand cursor over anything that does something when clicked: buttons, tabs, breadcrumbs
/// and the rows of the app's lists. It is one app-wide rule rather than per-view code, so new controls get it
/// for free. Text areas are never touched; they manage their own I-beam (and the ⌘-hover link hand).
final class PointerCursorMonitor {
    static let shared = PointerCursorMonitor()
    private var monitor: Any?
    private var isShowingHand = false

    func start() {
        guard monitor == nil else { return }
        // Mouse-moved events are only delivered to windows that ask for them.
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
        NSApp.windows.forEach { $0.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.update(for: event)
            return event
        }
    }

    private weak var lastHit: NSView?
    private var lastHitIsClickable = false

    private func update(for event: NSEvent) {
        guard let window = event.window, let frameView = window.contentView?.superview,
              let hit = frameView.hitTest(event.locationInWindow) else { lastHit = nil; return reset() }
        // Most moves stay over the same view: no walk up the hierarchy, and no cursor call unless it is needed.
        if hit !== lastHit {
            lastHit = hit
            lastHitIsClickable = isClickable(hit)
        }
        if lastHitIsClickable {
            if NSCursor.current !== NSCursor.pointingHand { NSCursor.pointingHand.set() }
            isShowingHand = true
        } else {
            reset()
        }
    }

    /// Only undo a hand that this monitor set, so a text view's own cursor is left alone.
    private func reset() {
        guard isShowingHand else { return }
        isShowingHand = false
        NSCursor.arrow.set()
    }

    private func isClickable(_ view: NSView) -> Bool {
        var current: NSView? = view
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            switch candidate {
            case is NSTextView, is TerminalView: return false                 // text: not ours to decide
            case let control as NSControl where control is NSButton || control is NSSegmentedControl || control is NSPopUpButton:
                return control.isEnabled
            case is TabItemView, is NSTableRowView: return true
            case let field as NSTextField where field.isEditable: return false     // a text box wants the I-beam
            default: current = candidate.superview
            }
        }
        return false
    }
}
