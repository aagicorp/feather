import AppKit

/// Saves a window's documents without being asked, when the Auto Save setting says so: a moment after the last
/// edit, or when the focus goes elsewhere (another tab, another window, another app).
///
/// It only ever does what ⌘S would have done without questions. Untitled files (they would need a name),
/// pictures, and files that changed on disk underneath their unsaved edits are left alone; the last of those is
/// a conflict only the user can settle. The save runs the usual tidy but not format on save, which waits for a
/// language server and moves text about: fine for a deliberate ⌘S, not for something that happens by itself.
final class AutoSaveController {
    enum Mode: String, CaseIterable {
        case off, afterDelay, onFocusChange

        var title: String {
            switch self {
            case .off: return "Off"
            case .afterDelay: return "After a Delay"
            case .onFocusChange: return "When Focus Changes"
            }
        }
    }

    static let delay: TimeInterval = 1

    private unowned let store: DocumentStore
    private var timer: Timer?
    /// Documents edited since the timer last fired. Weak: a closed document needs no saving.
    private let pending = NSHashTable<TextDocument>.weakObjects()
    private weak var focused: TextDocument?
    /// How often the timer was pushed back, for the test that shows a keystroke costs exactly that.
    private(set) var reschedules = 0
    private(set) var saves = 0

    init(store: DocumentStore) {
        self.store = store
        NotificationCenter.default.addObserver(self, selector: #selector(focusLeft),
                                               name: NSApplication.didResignActiveNotification, object: nil)
    }

    deinit { timer?.invalidate() }

    /// Called for every edit, so it does the least it can: note the document and push the one timer back.
    func documentEdited(_ document: TextDocument) {
        guard Settings.shared.autoSaveMode == .afterDelay else { return }
        pending.add(document)
        reschedules += 1
        let fireDate = Date(timeIntervalSinceNow: AutoSaveController.delay)
        if let timer, timer.isValid {
            timer.fireDate = fireDate
        } else {
            let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in self?.savePending() }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func savePending() {
        timer = nil
        let documents = pending.allObjects
        pending.removeAllObjects()
        guard Settings.shared.autoSaveMode == .afterDelay else { return }
        documents.forEach(saveIfPossible)
    }

    /// The window tells us which document has the focus; when that changes, the one left behind is saved.
    func focusMoved(to document: TextDocument?) {
        guard document !== focused else { return }
        let previous = focused
        focused = document
        if let previous, Settings.shared.autoSaveMode == .onFocusChange { saveIfPossible(previous) }
    }

    /// The window or the whole app lost the focus.
    @objc func focusLeft() {
        guard Settings.shared.autoSaveMode == .onFocusChange else { return }
        store.dirtyDocuments.forEach(saveIfPossible)
    }

    func canSave(_ document: TextDocument) -> Bool {
        document.isDirty && !document.isMedia && document.url != nil && document.useCount > 0 && !store.isChangedOnDisk(document)
    }

    private func saveIfPossible(_ document: TextDocument) {
        guard canSave(document) else { return }
        if store.saveQuietly(document) { saves += 1 }
    }
}
