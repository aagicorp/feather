/// Covers App/WorkspaceTrust.swift: which folders count as trusted (a trusted parent covers its children), the
/// one-spelling-per-folder rule for /private/tmp and paths that do not exist, the open-folder bookkeeping that
/// lets git refuse to run in a restricted project, and the switch that turns the whole feature off.
import XCTest
@testable import Feather

final class WorkspaceTrustTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var trust: WorkspaceTrust!

    override func setUp() {
        super.setUp()
        suiteName = "feather-tests-trust-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        trust = WorkspaceTrust(defaults: defaults, recentFolders: [])
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testNothingIsTrustedUntilSaidSo() {
        XCTAssertTrue(trust.isEnabled)
        XCTAssertFalse(trust.isTrusted(url("/tmp/feather-trust-project")))
        XCTAssertTrue(trust.isTrusted(nil), "a window without a folder has nothing to run")
        XCTAssertEqual(trust.trustedFolders, [])
    }

    func testATrustedParentCoversItsChildrenButNotItsNeighbours() {
        trust.trust(url("/tmp/feather-trust/project"))
        XCTAssertTrue(trust.isTrusted(url("/tmp/feather-trust/project")))
        XCTAssertTrue(trust.isTrusted(url("/tmp/feather-trust/project/src/deep")))
        XCTAssertFalse(trust.isTrusted(url("/tmp/feather-trust/project-two")), "a name that merely starts the same way")
        XCTAssertFalse(trust.isTrusted(url("/tmp/feather-trust")))
    }

    func testKeysFoldPrivateSpellingsEvenForFoldersThatDoNotExist() {
        let name = "feather-trust-missing-\(UUID().uuidString)"
        XCTAssertEqual(WorkspaceTrust.key("/private/tmp/\(name)/"), "/tmp/\(name)")
        XCTAssertEqual(WorkspaceTrust.key("/tmp/\(name)/sub/../other"), "/tmp/\(name)/other")
        XCTAssertEqual(WorkspaceTrust.key("/private/var/folders/x"), "/var/folders/x")
        XCTAssertEqual(WorkspaceTrust.key("/private/etc"), "/etc")
        XCTAssertEqual(WorkspaceTrust.key("/privateer/x"), "/privateer/x", "only the real /private prefixes are folded")
        XCTAssertEqual(WorkspaceTrust.key("/private"), "/private")

        trust.trust(url("/private/tmp/\(name)"))
        XCTAssertTrue(trust.isTrusted(url("/tmp/\(name)/src")))
        XCTAssertTrue(trust.isTrusted(url("/private/tmp/\(name)")))
        XCTAssertEqual(trust.trustedFolders, ["/tmp/\(name)"])
    }

    func testAnExistingFolderIsFoundUnderEitherSpelling() {
        let folder = url("/tmp/feather-trust-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        trust.trust(url("/private" + folder.path))
        XCTAssertTrue(trust.isTrusted(folder))
        XCTAssertTrue(trust.isTrusted(folder.appendingPathComponent("child")))
    }

    func testTrustingTheRootCoversEverything() {
        trust.trust(url("/"))
        XCTAssertTrue(trust.isTrusted(url("/Users/somebody/code")))
        XCTAssertTrue(trust.isTrusted(url("/")))
    }

    func testRevokeAndPersistence() {
        trust.trust(url("/tmp/feather-trust/b"))
        trust.trust(url("/tmp/feather-trust/a"))
        XCTAssertEqual(trust.trustedFolders, ["/tmp/feather-trust/a", "/tmp/feather-trust/b"])
        XCTAssertEqual(defaults.stringArray(forKey: "trustedFolders"), ["/tmp/feather-trust/a", "/tmp/feather-trust/b"])

        trust.revoke(url("/private/tmp/feather-trust/a"))
        XCTAssertFalse(trust.isTrusted(url("/tmp/feather-trust/a")))
        XCTAssertTrue(trust.isTrusted(url("/tmp/feather-trust/b")))
        XCTAssertEqual(WorkspaceTrust(defaults: defaults, recentFolders: []).trustedFolders, ["/tmp/feather-trust/b"])
    }

    func testChangesArePosted() {
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: WorkspaceTrust.didChange, object: nil, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        trust.trust(url("/tmp/feather-trust/x"))
        trust.revoke(url("/tmp/feather-trust/x"))
        trust.isEnabled = false
        XCTAssertEqual(posts, 3)
    }

    func testFoldersWorkedInBeforeTheFeatureExistedAreTrustedOnce() {
        let fresh = "feather-tests-trust-seed-\(UUID().uuidString)"
        let seeded = UserDefaults(suiteName: fresh)!
        defer { seeded.removePersistentDomain(forName: fresh) }
        let first = WorkspaceTrust(defaults: seeded, recentFolders: [url("/private/tmp/feather-trust/old")])
        XCTAssertTrue(first.isTrusted(url("/tmp/feather-trust/old/src")))
        XCTAssertEqual(first.trustedFolders, ["/tmp/feather-trust/old"])
        // The next launch does not add whatever is recent by then.
        let second = WorkspaceTrust(defaults: seeded, recentFolders: [url("/tmp/feather-trust/newer")])
        XCTAssertFalse(second.isTrusted(url("/tmp/feather-trust/newer")))
        XCTAssertEqual(second.trustedFolders, ["/tmp/feather-trust/old"])
    }

    func testTurningTheFeatureOffTrustsEverything() {
        trust.noteOpen(url("/tmp/feather-trust/p"), restricted: true)
        trust.isEnabled = false
        XCTAssertTrue(trust.isTrusted(url("/tmp/feather-trust/anything")))
        XCTAssertFalse(trust.blocksExecution(in: url("/tmp/feather-trust/p/src")))
        XCTAssertFalse(defaults.bool(forKey: "workspaceTrustEnabled"))
        XCTAssertFalse(WorkspaceTrust(defaults: defaults, recentFolders: []).isEnabled)

        trust.isEnabled = true
        XCTAssertFalse(trust.isTrusted(url("/tmp/feather-trust/anything")))
        XCTAssertTrue(trust.blocksExecution(in: url("/tmp/feather-trust/p/src")), "the open folder was remembered while off")
    }

    func testExecutionIsBlockedBelowAFolderOpenInRestrictedMode() {
        let project = url("/tmp/feather-trust/restricted")
        XCTAssertFalse(trust.blocksExecution(in: project), "not open anywhere")
        trust.noteOpen(project, restricted: true)
        XCTAssertTrue(trust.blocksExecution(in: project))
        XCTAssertTrue(trust.blocksExecution(in: url("/private/tmp/feather-trust/restricted/packages/app")))
        XCTAssertFalse(trust.blocksExecution(in: url("/tmp/feather-trust/restricted-2")))
        XCTAssertFalse(trust.blocksExecution(in: url("/tmp/feather-trust")))

        // Trusting it (from the status bar) lifts the block without the window having to say so.
        trust.trust(project)
        XCTAssertFalse(trust.blocksExecution(in: project.appendingPathComponent("src")))
        trust.revoke(project)
        XCTAssertTrue(trust.blocksExecution(in: project))

        trust.noteOpen(project, restricted: false)
        XCTAssertFalse(trust.blocksExecution(in: project))
        trust.noteOpen(project, restricted: true)
        trust.noteClosed(project)
        XCTAssertFalse(trust.blocksExecution(in: project))
    }

    func testTwoWindowsCanHaveDifferentRestrictions() {
        trust.noteOpen(url("/tmp/feather-trust/one"), restricted: true)
        trust.noteOpen(url("/tmp/feather-trust/two"), restricted: false)
        XCTAssertTrue(trust.blocksExecution(in: url("/tmp/feather-trust/one/x")))
        XCTAssertFalse(trust.blocksExecution(in: url("/tmp/feather-trust/two/x")))
        trust.noteClosed(url("/tmp/feather-trust/one"))
        XCTAssertFalse(trust.blocksExecution(in: url("/tmp/feather-trust/one/x")))
    }

    func testAnswersFromBackgroundThreadsAreConsistent() {
        trust.trust(url("/tmp/feather-trust/shared"))
        trust.noteOpen(url("/tmp/feather-trust/locked"), restricted: true)
        let group = DispatchGroup()
        var wrong = 0
        let lock = NSLock()
        for _ in 0..<32 {
            group.enter()
            DispatchQueue.global().async {
                let ok = self.trust.isTrusted(self.url("/tmp/feather-trust/shared/a")) && self.trust.blocksExecution(in: self.url("/tmp/feather-trust/locked/b"))
                if !ok { lock.lock(); wrong += 1; lock.unlock() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(wrong, 0)
    }
}
