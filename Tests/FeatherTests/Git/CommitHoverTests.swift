import XCTest
@testable import Feather

/// Git/CommitHover.swift: what the hover card is told about a commit, read from throwaway repositories: author
/// and date, co-authors pulled out of the message, the changed/inserted/deleted counts, and the web address of
/// the commit worked out from the "origin" remote for GitHub, GitLab and Bitbucket. The card view itself is UI.
final class CommitHoverTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = try TestSupport.makeRepository(["a.txt": "one\ntwo\n", "b.txt": "b\n"])
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func head() -> String { TestSupport.git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines) }

    private func details(of hash: String) -> GitCommitDetails? {
        var result: GitCommitDetails?
        var done = false
        GitCommitDetails.load(hash, in: root) { result = $0; done = true }
        XCTAssertTrue(TestSupport.wait(upTo: 15) { done }, "details did not load")
        return result
    }

    func testAuthorDateMessageAndCounts() throws {
        try "one\nTWO\nthree\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        TestSupport.git(["add", "-A"], in: root)
        TestSupport.git(["commit", "-qm", "Change a, drop b\n\nA longer explanation.\n"], in: root)
        guard let details = details(of: head()) else { return XCTFail("no details") }
        XCTAssertEqual(details.author, "Feather Tests")
        XCTAssertLessThan(abs(details.date.timeIntervalSinceNow), 300)
        XCTAssertEqual(details.message, "Change a, drop b\n\nA longer explanation.")
        XCTAssertEqual(details.filesChanged, 2)
        XCTAssertEqual(details.insertions, 2)
        XCTAssertEqual(details.deletions, 2)
        XCTAssertNil(details.webURL, "no remote, no link")
        XCTAssertNil(details.hostName)
        XCTAssertTrue(details.coAuthors.isEmpty)
    }

    func testCoAuthorsComeOutOfTheMessage() throws {
        try "x\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        TestSupport.git(["commit", "-qam", "Pair work\n\nCo-authored-by: Grace Hopper <grace@example.com>\nco-authored-by:   Alan Turing <alan@example.com>\n"], in: root)
        guard let details = details(of: head()) else { return XCTFail("no details") }
        XCTAssertEqual(details.coAuthors, ["Grace Hopper", "Alan Turing"])
        XCTAssertEqual(details.message, "Pair work", "the trailers are not part of the message shown")
        XCTAssertEqual(details.filesChanged, 1)
        XCTAssertEqual(details.insertions, 1)
        XCTAssertEqual(details.deletions, 2)
    }

    func testAnUnknownCommitGivesNothing() {
        XCTAssertNil(details(of: "0123456789abcdef0123456789abcdef01234567"))
    }

    func testGitHubRemoteInSSHForm() {
        TestSupport.git(["remote", "add", "origin", "git@github.com:acme/widgets.git"], in: root)
        let details = details(of: head())
        XCTAssertEqual(details?.hostName, "GitHub")
        XCTAssertEqual(details?.webURL?.absoluteString, "https://github.com/acme/widgets/commit/" + head())
    }

    func testGitLabRemoteInHTTPSFormWithAUser() {
        TestSupport.git(["remote", "add", "origin", "https://oauth2@gitlab.example.com/group/sub/project.git"], in: root)
        let details = details(of: head())
        XCTAssertEqual(details?.hostName, "GitLab")
        XCTAssertEqual(details?.webURL?.absoluteString, "https://gitlab.example.com/group/sub/project/-/commit/" + head())
    }

    func testBitbucketRemoteInSSHURLForm() {
        TestSupport.git(["remote", "add", "origin", "ssh://git@bitbucket.org/team/repo"], in: root)
        let details = details(of: head())
        XCTAssertEqual(details?.hostName, "Bitbucket")
        XCTAssertEqual(details?.webURL?.absoluteString, "https://bitbucket.org/team/repo/commits/" + head())
    }

    func testAnUnknownHostHasNoLink() {
        TestSupport.git(["remote", "add", "origin", "git@code.internal:team/repo.git"], in: root)
        let details = details(of: head())
        XCTAssertNotNil(details)
        XCTAssertNil(details?.webURL)
        XCTAssertNil(details?.hostName)
    }
}
