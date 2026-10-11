import XCTest
@testable import Feather

/// The pure parts behind the API client's views: the URL ↔ Params split, colours, pretty-printing, the path
/// under the caret, moving items in a collection, and the runner against the mock server.
final class APIUITests: XCTestCase {
    func testSplitAndJoinQuery() {
        let (base, query) = APIFormat.splitQuery("{{baseUrl}}/users?page=2&sort&q={{term}}")
        XCTAssertEqual(base, "{{baseUrl}}/users")
        XCTAssertEqual(query.map { "\($0.name)=\($0.value)" }, ["page=2", "sort=", "q={{term}}"])
        XCTAssertEqual(APIFormat.joinQuery(base: "http://h/x", params: [APIKeyValue("a", "1"), APIKeyValue("off", "2", enabled: false), APIKeyValue("flag", "")]),
                       "http://h/x?a=1&flag")
        XCTAssertEqual(APIFormat.joinQuery(base: "http://h/x", params: []), "http://h/x")
    }

    func testParamsAfterEditingURLKeepDisabledRowsAndIDs() {
        let page = APIKeyValue("page", "1")
        let off = APIKeyValue("debug", "true", enabled: false)
        let (base, params) = APIFormat.params(afterEditingURL: "http://h/list?page=3&limit=10", previous: [page, off])
        XCTAssertEqual(base, "http://h/list")
        XCTAssertEqual(params.map(\.name), ["page", "limit", "debug"])
        XCTAssertEqual(params[0].id, page.id, "an existing row keeps its identity")
        XCTAssertEqual(params[0].value, "3")
        XCTAssertFalse(params[2].enabled)
        // Round trip: the field shows the same thing again.
        XCTAssertEqual(APIFormat.joinQuery(base: base, params: params), "http://h/list?page=3&limit=10")
    }

    func testMethodAndStatusColours() {
        let theme = Theme.builtIns[0]
        XCTAssertEqual(APIFormat.methodColor(.put, theme: theme), APIFormat.methodColor(.patch, theme: theme))
        let distinct = [APIMethod.get, .post, .put, .delete].map { APIFormat.methodColor($0, theme: theme) }
        XCTAssertEqual(Set(distinct.map { $0.description }).count, 4)
        XCTAssertEqual(APIFormat.statusColor(204, theme: theme), APIFormat.methodColor(.get, theme: theme))
        XCTAssertEqual(APIFormat.statusColor(404, theme: theme), APIFormat.methodColor(.post, theme: theme))
        XCTAssertEqual(APIFormat.statusColor(500, theme: theme), APIFormat.methodColor(.delete, theme: theme))
        XCTAssertEqual(APIFormat.statusColor(nil, theme: theme), APIFormat.methodColor(.delete, theme: theme))
        XCTAssertEqual(APIFormat.methodLabel(.delete), "DEL")
        XCTAssertEqual(APIFormat.size(1536), "1.5 KB")
        XCTAssertEqual(APIFormat.size(12), "12 B")
        XCTAssertEqual(APIFormat.duration(0.184), "184 ms")
        XCTAssertEqual(APIFormat.duration(1.5), "1.50 s")
    }

    func testPrettyJSONKeepsKeyOrderAndLeavesOtherTextAlone() {
        let pretty = APIFormat.prettyJSON(#"{"z":1,"a":{"list":[1,2,{"k":"v"}],"empty":{},"none":[]},"s":"a, b: {c}"}"#)
        XCTAssertEqual(pretty, """
        {
          "z": 1,
          "a": {
            "list": [
              1,
              2,
              {
                "k": "v"
              }
            ],
            "empty": {},
            "none": []
          },
          "s": "a, b: {c}"
        }
        """)
        XCTAssertEqual(APIFormat.prettyJSON("<html>"), "<html>")
        XCTAssertEqual(APIFormat.prettyJSON("[]"), "[]")
    }

    func testJSONPathUnderTheCaret() {
        let text = APIFormat.prettyJSON(#"{"user":{"id":42,"tags":["a","b"]},"ok":true}"#)
        func offset(of needle: String) -> Int { (text as NSString).range(of: needle).location + 1 }
        XCTAssertEqual(APIFormat.jsonPath(at: offset(of: "42"), in: text), "$.user.id")
        XCTAssertEqual(APIFormat.jsonPath(at: offset(of: "\"b\"") + 1, in: text), "$.user.tags[1]")
        XCTAssertEqual(APIFormat.jsonPath(at: offset(of: "true"), in: text), "$.ok")
        XCTAssertNil(APIFormat.jsonPath(at: 3, in: "plain text"))
    }

    func testVariableRanges() {
        XCTAssertEqual(APIFormat.variableRanges(in: "{{a}}/x/{{ b }}").map(\.location), [0, 8])
    }

    func testInsertingAndMovingItemsInACollection() {
        let a = APIRequest(name: "a"), b = APIRequest(name: "b"), c = APIRequest(name: "c")
        var collection = APICollection(name: "C", items: [.request(a), .folder(APIFolder(name: "F", items: [.request(b)])), .request(c)])
        let folderID = collection.items[1].id
        XCTAssertEqual(collection.parentFolderID(of: b.id), .some(folderID))
        XCTAssertEqual(collection.parentFolderID(of: c.id), .some(nil))
        XCTAssertNil(collection.parentFolderID(of: "missing"))
        XCTAssertEqual(collection.index(of: c.id, in: nil), 2)
        // Move c into the folder before b.
        XCTAssertTrue(collection.remove(id: c.id))
        XCTAssertTrue(collection.insert(.request(c), into: folderID, at: 0))
        XCTAssertEqual(collection.folder(id: folderID)?.items.map(\.name), ["c", "b"])
        XCTAssertTrue(collection.insert(.request(APIRequest(name: "z")), into: nil, at: 99))
        XCTAssertEqual(collection.items.map(\.name), ["a", "F", "z"])
        var folder = collection.folder(id: folderID)!
        folder.name = "Renamed"
        XCTAssertTrue(collection.replace(folder))
        XCTAssertEqual(collection.items[1].name, "Renamed")
    }

    // MARK: Runner

    private var server: MockHTTPServer!
    private var personal: URL!
    private var previousPersonal: URL!
    private var previousSecrets: SecretStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try MockHTTPServer()
        personal = TestSupport.temporaryDirectory("feather-api-ui-personal")
        previousPersonal = APIWorkspace.personalBaseDirectory
        previousSecrets = APIWorkspace.secrets
        APIWorkspace.personalBaseDirectory = personal
        APIWorkspace.secrets = MemorySecretStore()
    }

    override func tearDown() {
        server.stop()
        APIWorkspace.personalBaseDirectory = previousPersonal
        APIWorkspace.secrets = previousSecrets
        try? FileManager.default.removeItem(at: personal)
        super.tearDown()
    }

    func testRunnerSendsInOrderAndCapturesFlowToTheNextRequest() {
        server.routes["/login"] = MockHTTPServer.Route(body: Data(#"{"token":"abc123"}"#.utf8))
        server.routes["/fail"] = MockHTTPServer.Route(status: 500, body: Data("{}".utf8))
        var login = APIRequest(name: "Login", method: .post, url: "{{base}}/login")
        login.checks = [.status(200), APICheck(kind: .jsonPath, target: "$.token", op: .exists)]
        login.captures = [APICapture(variable: "token", path: "$.token")]
        var me = APIRequest(name: "Me", url: "{{base}}/me")
        me.auth = APIAuth(kind: .bearer, token: "{{token}}")
        me.checks = [APICheck(kind: .jsonPath, target: "$.headers.authorization", op: .equals, expected: "Bearer abc123")]
        var failing = APIRequest(name: "Broken", url: "{{base}}/fail")
        failing.checks = [.status(200)]
        let collection = APICollection(name: "Flow", items: [.request(login), .folder(APIFolder(name: "After", items: [.request(me)])), .request(failing)])
        let workspace = APIWorkspace(projectRoot: nil)
        let environment = APIEnvironment(name: "Local", variables: [APIVariable("base", server.baseURL)])

        let runner = APIRunner(workspace: workspace, collection: collection, folderID: nil, environment: environment)
        XCTAssertEqual(runner.rows.map(\.request.name), ["Login", "Me", "Broken"])
        var finished = false
        runner.onFinish = { finished = true }
        runner.start()
        XCTAssertTrue(TestSupport.wait(upTo: 10) { finished })
        XCTAssertEqual(runner.rows.map(\.passed), [true, true, false])
        XCTAssertEqual(runner.rows[0].checksPassed, 2)
        XCTAssertEqual(server.received.map(\.path), ["/login", "/me", "/fail"], "one after the other, in order")
        XCTAssertEqual(server.received[1].headers["authorization"], "Bearer abc123", "the captured token reached the next request")
        XCTAssertEqual(runner.failedIndices, [2])
        XCTAssertEqual(runner.rows[2].checks.first?.message, "status 500 is not 200")
        XCTAssertEqual(workspace.history.count, 3)

        // Rerun only what failed, after the server was fixed.
        server.routes["/fail"] = MockHTTPServer.Route(body: Data("{}".utf8))
        finished = false
        runner.start(only: runner.failedIndices)
        XCTAssertTrue(TestSupport.wait(upTo: 10) { finished })
        XCTAssertEqual(server.received.count, 4)
        XCTAssertEqual(runner.rows.map(\.passed), [true, true, true])
        XCTAssertTrue(runner.failedIndices.isEmpty)
    }

    func testRunnerFolderOnlyAndStop() {
        server.routes["/slow"] = MockHTTPServer.Route(body: Data("{}".utf8), delay: 3)
        let quick = APIRequest(name: "Quick", url: "{{base}}/quick")
        let slow = APIRequest(name: "Slow", url: "{{base}}/slow")
        let folder = APIFolder(name: "Only", items: [.request(slow), .request(quick)])
        let collection = APICollection(name: "C", items: [.request(APIRequest(name: "Outside", url: "{{base}}/outside")), .folder(folder)])
        let workspace = APIWorkspace(projectRoot: nil)
        let runner = APIRunner(workspace: workspace, collection: collection, folderID: folder.id,
                               environment: APIEnvironment(name: "L", variables: [APIVariable("base", server.baseURL)]))
        XCTAssertEqual(runner.rows.map(\.request.name), ["Slow", "Quick"])
        var finished = false
        runner.onFinish = { finished = true }
        runner.start()
        XCTAssertTrue(runner.isRunning)
        XCTAssertTrue(TestSupport.wait(upTo: 2) { runner.rows[0].state == .running })
        runner.stop()
        XCTAssertTrue(finished)
        XCTAssertFalse(runner.isRunning)
        XCTAssertEqual(runner.rows[0].error, "Stopped.")
        XCTAssertEqual(runner.rows[1].state, .waiting)
    }
}
