import XCTest
@testable import Feather

/// Covers Editor/AutoSave.swift: the modes, what may be saved without asking, the one timer that every edit
/// pushes back, and saving when the focus moves. The delay itself is the thing under test here, so these wait.
final class AutoSaveTests: XCTestCase {
    private var root: URL!
    private var store: DocumentStore!
    private var previousMode: AutoSaveController.Mode!

    override func setUp() {
        super.setUp()
        previousMode = Settings.shared.autoSaveMode
        root = TestSupport.temporaryDirectory("feather-autosave")
        let lsp = LSPManager()
        lsp.isAllowed = false
        store = DocumentStore(lsp: lsp)
    }

    override func tearDown() {
        Settings.shared.autoSaveMode = previousMode
        store = nil
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func open(_ name: String, _ text: String = "start") throws -> TextDocument {
        try TestSupport.write([name: text], under: root)
        return try store.open(root.appendingPathComponent(name))
    }

    private func edit(_ document: TextDocument, _ text: String = "+") {
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    }

    private func disk(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }

    func testModes() {
        XCTAssertEqual(AutoSaveController.Mode.allCases.map(\.rawValue), ["off", "afterDelay", "onFocusChange"])
        XCTAssertEqual(AutoSaveController.Mode.allCases.map(\.title), ["Off", "After a Delay", "When Focus Changes"])
        XCTAssertEqual(AutoSaveController.delay, 1)
    }

    func testWhatMayBeSavedWithoutAsking() throws {
        let autoSave = store.autoSave
        let clean = try open("clean.txt")
        XCTAssertFalse(autoSave.canSave(clean))
        edit(clean)
        XCTAssertTrue(autoSave.canSave(clean))
        let untitled = store.newUntitled()
        edit(untitled)
        XCTAssertFalse(autoSave.canSave(untitled))                            // it would need a name
        XCTAssertFalse(autoSave.canSave(store.openMedia(root.appendingPathComponent("p.png"))))
        let changed = try open("changed.txt")
        edit(changed)
        try "someone else".write(to: root.appendingPathComponent("changed.txt"), atomically: true, encoding: .utf8)
        XCTAssertFalse(autoSave.canSave(changed))                             // a conflict is the user's to settle
        let closed = try open("closed.txt")
        edit(closed)
        store.release(closed)
        XCTAssertFalse(autoSave.canSave(closed))
    }

    func testOffDoesNothing() throws {
        Settings.shared.autoSaveMode = .off
        let document = try open("a.txt")
        edit(document)
        XCTAssertEqual(store.autoSave.reschedules, 0)
        store.autoSave.focusMoved(to: document)
        store.autoSave.focusMoved(to: nil)
        store.autoSave.focusLeft()
        XCTAssertEqual(store.autoSave.saves, 0)
        XCTAssertTrue(document.isDirty)
    }

    func testAfterADelayEveryEditPushesTheOneTimerBackAndThenItSaves() throws {
        Settings.shared.autoSaveMode = .afterDelay
        let a = try open("a.txt")
        let b = try open("b.txt")
        edit(a, "1")
        edit(a, "2")
        edit(b, "3")
        XCTAssertEqual(store.autoSave.reschedules, 3)
        XCTAssertEqual(store.autoSave.saves, 0)
        XCTAssertTrue(a.isDirty)
        XCTAssertTrue(TestSupport.wait(upTo: 4) { store.autoSave.saves == 2 })
        XCTAssertFalse(a.isDirty)
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(try disk("a.txt"), "21start")
        XCTAssertEqual(try disk("b.txt"), "3start")
        XCTAssertFalse(store.isAutoSaving)
    }

    func testTheSaveRunsTheTidyAsAnAutoSave() throws {
        Settings.shared.autoSaveMode = .afterDelay
        let document = try open("a.txt")
        var sawAutoSaving: Bool?
        store.willSave = { [weak store] _ in sawAutoSaving = store?.isAutoSaving }
        edit(document)
        XCTAssertTrue(TestSupport.wait(upTo: 4) { store.autoSave.saves == 1 })
        XCTAssertEqual(sawAutoSaving, true)
    }

    func testSwitchingOffBeforeTheTimerFiresCancelsTheSave() throws {
        Settings.shared.autoSaveMode = .afterDelay
        let document = try open("a.txt")
        edit(document)
        Settings.shared.autoSaveMode = .off
        XCTAssertFalse(TestSupport.wait(upTo: 1.6) { store.autoSave.saves > 0 })
        XCTAssertTrue(document.isDirty)
        XCTAssertEqual(try disk("a.txt"), "start")
    }

    func testFocusChangeSavesTheDocumentLeftBehind() throws {
        Settings.shared.autoSaveMode = .onFocusChange
        let a = try open("a.txt")
        let b = try open("b.txt")
        store.autoSave.focusMoved(to: a)
        edit(a)
        edit(b)
        store.autoSave.focusMoved(to: a)                    // no change of focus
        XCTAssertEqual(store.autoSave.saves, 0)
        store.autoSave.focusMoved(to: b)
        XCTAssertEqual(store.autoSave.saves, 1)
        XCTAssertFalse(a.isDirty)
        XCTAssertTrue(b.isDirty)
        XCTAssertEqual(try disk("a.txt"), "+start")
        store.autoSave.focusLeft()                          // the window lost the focus: everything dirty goes
        XCTAssertEqual(store.autoSave.saves, 2)
        XCTAssertFalse(b.isDirty)
        XCTAssertEqual(store.autoSave.reschedules, 0)      // the timer belongs to the other mode
    }

    func testFocusChangeLeavesAConflictAlone() throws {
        Settings.shared.autoSaveMode = .onFocusChange
        let a = try open("a.txt")
        store.autoSave.focusMoved(to: a)
        edit(a)
        try "outside".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        store.autoSave.focusMoved(to: nil)
        XCTAssertEqual(store.autoSave.saves, 0)
        XCTAssertTrue(a.isDirty)
        XCTAssertEqual(try disk("a.txt"), "outside")
    }
}
