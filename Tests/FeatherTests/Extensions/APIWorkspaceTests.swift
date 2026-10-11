import XCTest
@testable import Feather

/// Collections and environments on disk, secrets kept out of the files, history, and captured values.
final class APIWorkspaceTests: XCTestCase {
    private var root: URL!
    private var personal: URL!
    private var secrets: MemorySecretStore!
    private var previousPersonal: URL!
    private var previousSecrets: SecretStore!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-api-project")
        personal = TestSupport.temporaryDirectory("feather-api-personal")
        secrets = MemorySecretStore()
        previousPersonal = APIWorkspace.personalBaseDirectory
        previousSecrets = APIWorkspace.secrets
        APIWorkspace.personalBaseDirectory = personal
        APIWorkspace.secrets = secrets
    }

    override func tearDown() {
        APIWorkspace.personalBaseDirectory = previousPersonal
        APIWorkspace.secrets = previousSecrets
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: personal)
        super.tearDown()
    }

    func testSavesToTheProjectAndReadsBack() throws {
        let workspace = APIWorkspace(projectRoot: root)
        var collection = APICollection(name: "Shop", items: [.request(APIRequest(name: "Ping", url: "http://x"))])
        collection.variables = [APIVariable("key", "hidden", secret: true), APIVariable("host", "h")]
        XCTAssertTrue(workspace.save(collection))
        let file = root.appendingPathComponent(".feather/api/collections/Shop.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("hidden"), "a secret never reaches the file")
        XCTAssertTrue(text.contains("\"host\""))
        XCTAssertEqual(secrets.read(scope: collection.id, name: "key"), "hidden")

        let again = APIWorkspace(projectRoot: root)
        again.load()
        XCTAssertEqual(again.collections.map(\.value.name), ["Shop"])
        XCTAssertEqual(again.collections.first?.location, .project)
        XCTAssertEqual(again.variables(of: again.collections[0].value).map(\.value), ["hidden", "h"])
    }

    func testPersonalLocationAndDelete() throws {
        let workspace = APIWorkspace(projectRoot: root)
        XCTAssertTrue(workspace.save(APIEnvironment(name: "Mine", variables: [APIVariable("a", "1")]), location: .personal))
        XCTAssertTrue(workspace.save(APIEnvironment(name: "Mine", variables: [APIVariable("a", "2")]), location: .personal))     // a second file, not a clash
        let files = try FileManager.default.contentsOfDirectory(atPath: workspace.personalDirectory.appendingPathComponent("environments").path)
        XCTAssertEqual(files.sorted(), ["Mine 2.json", "Mine.json"])
        XCTAssertTrue(workspace.environments.allSatisfy { $0.location == .personal })
        let id = workspace.environments[0].value.id
        workspace.delete(environmentID: id)
        XCTAssertEqual(workspace.environments.count, 1)
        XCTAssertNil(workspace.environment(id: id))
    }

    func testNoFolderMeansPersonalOnly() {
        let workspace = APIWorkspace(projectRoot: nil)
        XCTAssertNil(workspace.projectDirectory)
        XCTAssertTrue(workspace.save(APICollection(name: "Loose")))
        XCTAssertEqual(workspace.collections.first?.location, .personal)
    }

    func testUpdatingKeepsTheFile() throws {
        let workspace = APIWorkspace(projectRoot: root)
        var collection = APICollection(name: "One")
        workspace.save(collection)
        let url = workspace.collections[0].url
        collection.name = "Renamed"
        workspace.save(collection)
        XCTAssertEqual(workspace.collections.count, 1)
        XCTAssertEqual(workspace.collections[0].url, url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Renamed"))
    }

    func testBrokenFilesAreReportedNotFatal() throws {
        let folder = root.appendingPathComponent(".feather/api/collections")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "not json".write(to: folder.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try APIJSON.encoder.encode(APICollection(name: "Good")).write(to: folder.appendingPathComponent("good.json"))
        let workspace = APIWorkspace(projectRoot: root)
        let problems = workspace.load()
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].hasPrefix("bad.json"))
        XCTAssertEqual(workspace.collections.map(\.value.name), ["Good"])
    }

    func testHistoryIsAppendedCappedAndReloaded() {
        let workspace = APIWorkspace(projectRoot: root)
        for index in 0..<(APIWorkspace.historyLimit + 5) {
            workspace.record(APIHistoryEntry(date: Date(), method: .get, url: "http://x/\(index)", status: 200, duration: 0.1, size: 1))
        }
        XCTAssertEqual(workspace.history.count, APIWorkspace.historyLimit)
        XCTAssertEqual(workspace.history.first?.url, "http://x/\(APIWorkspace.historyLimit + 4)")
        let again = APIWorkspace(projectRoot: root)
        again.load()
        XCTAssertEqual(again.history.count, APIWorkspace.historyLimit)
        XCTAssertEqual(again.history.first?.url, workspace.history.first?.url)
        again.clearHistory()
        XCTAssertTrue(again.history.isEmpty)
    }

    func testCapturedValuesLayerOverEnvironmentAndCollection() {
        let workspace = APIWorkspace(projectRoot: root)
        var collection = APICollection(name: "C")
        collection.variables = [APIVariable("who", "collection"), APIVariable("only", "c")]
        let environment = APIEnvironment(name: "E", variables: [APIVariable("who", "environment")])
        workspace.noteCaptured(["token": "t1"], collectionID: nil)
        workspace.noteCaptured(["who": "captured"], collectionID: collection.id)
        let variables = workspace.variables(for: collection, environment: environment)
        XCTAssertEqual(variables.resolve("{{who}} {{only}} {{token}}"), "captured c t1")
        XCTAssertEqual(workspace.variables(for: nil, environment: environment).resolve("{{who}} {{token}}"), "environment t1")
    }
}
