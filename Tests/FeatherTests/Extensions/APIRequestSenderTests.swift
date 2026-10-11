import XCTest
@testable import Feather

/// Resolving a request into what is sent, and sending it to a local server.
final class APIRequestSenderTests: XCTestCase {
    private var server: MockHTTPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = try MockHTTPServer()
        XCTAssertNotEqual(server.port, 0, "the mock server did not start")
    }

    override func tearDown() {
        server.stop()
        super.tearDown()
    }

    private func context(_ variables: [APIVariable] = [], auth: [APIAuth] = []) -> APIRequestSender.Context {
        APIRequestSender.Context(variables: APIVariables(environment: variables), inheritedAuth: auth, environment: nil, projectRoot: nil)
    }

    func testResolvingParamsHeadersAuthAndBody() throws {
        var request = APIRequest(name: "r", method: .post, url: "{{base}}/users?existing=1")
        request.params = [APIKeyValue("page", "{{page}}"), APIKeyValue("off", "x", enabled: false)]
        request.headers = [APIKeyValue("X-Trace", "{{page}}-{{base}}")]
        request.auth = APIAuth(kind: .bearer, token: "{{token}}")
        request.body = .json(#"{"n": {{page}}}"#)
        let resolved = try APIRequestSender.resolve(request, context: context([APIVariable("base", "http://h:1"), APIVariable("page", "2"), APIVariable("token", "T")]))
        XCTAssertEqual(resolved.url.absoluteString, "http://h:1/users?existing=1&page=2")
        XCTAssertEqual(resolved.headers.map { "\($0.name)=\($0.value)" }, ["X-Trace=2-http://h:1", "Authorization=Bearer T", "Content-Type=application/json"])
        XCTAssertEqual(String(decoding: resolved.body ?? Data(), as: UTF8.self), #"{"n": 2}"#)
    }

    func testAuthInheritanceAndKinds() throws {
        var request = APIRequest(name: "r", url: "http://h/x")
        let basic = APIAuth(kind: .basic, username: "u", password: "p")
        var resolved = try APIRequestSender.resolve(request, context: context(auth: [.inherit, basic]))
        XCTAssertEqual(resolved.headers.first?.value, "Basic " + Data("u:p".utf8).base64EncodedString())
        request.auth = .none
        resolved = try APIRequestSender.resolve(request, context: context(auth: [basic]))
        XCTAssertTrue(resolved.headers.isEmpty)
        request.auth = APIAuth(kind: .apiKey, keyName: "key", keyValue: "v", keyIn: .query)
        resolved = try APIRequestSender.resolve(request, context: context())
        XCTAssertEqual(resolved.url.query, "key=v")
    }

    func testFormBodiesAndSchemeDefault() throws {
        var request = APIRequest(name: "r", method: .post, url: "h:9/form")
        request.body = APIBody(kind: .urlencoded, fields: [APIKeyValue("a b", "1&2")])
        let resolved = try APIRequestSender.resolve(request, context: context())
        XCTAssertEqual(resolved.url.absoluteString, "http://h:9/form")
        XCTAssertEqual(String(decoding: resolved.body!, as: UTF8.self), "a%20b=1%262")
        XCTAssertEqual(resolved.headers.first?.value, "application/x-www-form-urlencoded")
        var multipart = request
        multipart.body = APIBody(kind: .multipart, fields: [APIKeyValue("f", "v")])
        let parts = try APIRequestSender.resolve(multipart, context: context())
        XCTAssertTrue(parts.headers.first!.value.hasPrefix("multipart/form-data; boundary="))
        XCTAssertTrue(String(decoding: parts.body!, as: UTF8.self).contains("name=\"f\"\r\n\r\nv\r\n"))
    }

    func testBadAddressesAreRefused() {
        XCTAssertThrowsError(try APIRequestSender.resolve(APIRequest(name: "r", url: ""), context: context()))
        XCTAssertThrowsError(try APIRequestSender.resolve(APIRequest(name: "r", url: "http://"), context: context()))
    }

    func testSendingEchoesWhatWasSent() throws {
        var request = APIRequest(name: "r", method: .put, url: server.baseURL + "/things/{{id}}")
        request.headers = [APIKeyValue("X-Feather", "yes")]
        request.body = .json(#"{"ok": true}"#)
        let resolved = try APIRequestSender.resolve(request, context: context([APIVariable("id", "7")]))
        let sender = APIRequestSender()
        let done = expectation(description: "answered")
        var received: APIResponse?
        sender.send(resolved, environment: nil) { result in
            if case .success(let response) = result { received = response }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let response = try XCTUnwrap(received)
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(response.isJSON)
        let echo = try XCTUnwrap(response.json as? [String: Any])
        XCTAssertEqual(echo["method"] as? String, "PUT")
        XCTAssertEqual(echo["path"] as? String, "/things/7")
        XCTAssertEqual(echo["body"] as? String, #"{"ok": true}"#)
        XCTAssertEqual((echo["headers"] as? [String: String])?["x-feather"], "yes")
        XCTAssertGreaterThan(response.duration, 0)
        XCTAssertEqual(response.size, response.body.count)
        XCTAssertFalse(sender.isSending)
    }

    func testStatusHeadersAndFailures() throws {
        server.routes["/missing"] = MockHTTPServer.Route(status: 404, headers: [("Content-Type", "text/plain"), ("X-Reason", "gone")], body: Data("nope".utf8))
        let sender = APIRequestSender()
        let done = expectation(description: "404")
        var received: APIResponse?
        sender.send(try APIRequestSender.resolve(APIRequest(name: "r", url: server.baseURL + "/missing"), context: context()), environment: nil) { result in
            if case .success(let response) = result { received = response }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(received?.status, 404)
        XCTAssertEqual(received?.header("x-reason"), "gone")
        XCTAssertEqual(received?.text, "nope")
        XCTAssertFalse(received?.isSuccess ?? true)

        let refused = expectation(description: "refused")
        var failure: APIRequestSender.Failure?
        sender.send(try APIRequestSender.resolve(APIRequest(name: "r", url: "http://127.0.0.1:1/"), context: context()), environment: nil) { result in
            if case .failure(let error) = result { failure = error }
            refused.fulfill()
        }
        wait(for: [refused], timeout: 10)
        XCTAssertEqual(failure?.message, "Nothing is listening at that address. Is the server running?")
    }

    func testCancel() throws {
        server.routes["/slow"] = MockHTTPServer.Route(body: Data("late".utf8), delay: 3)
        let sender = APIRequestSender()
        let done = expectation(description: "cancelled")
        sender.send(try APIRequestSender.resolve(APIRequest(name: "r", url: server.baseURL + "/slow"), context: context()), environment: nil) { result in
            if case .failure(let error) = result { XCTAssertEqual(error.message, "Cancelled.") } else { XCTFail("should have been cancelled") }
            done.fulfill()
        }
        XCTAssertTrue(sender.isSending)
        sender.cancel()
        // Cancel drops the completion on purpose; the callback above must not be called at all.
        done.isInverted = true
        wait(for: [done], timeout: 1)
        XCTAssertFalse(sender.isSending)
    }

    func testControllerSendRecordsHistoryChecksAndCaptures() throws {
        let personal = TestSupport.temporaryDirectory("feather-api-personal")
        let previous = APIWorkspace.personalBaseDirectory
        APIWorkspace.personalBaseDirectory = personal
        defer { APIWorkspace.personalBaseDirectory = previous; try? FileManager.default.removeItem(at: personal) }
        server.routes["/login"] = MockHTTPServer.Route(body: Data(#"{"token": "abc"}"#.utf8))
        let workspace = APIWorkspace(projectRoot: nil)
        var request = APIRequest(name: "Login", method: .post, url: server.baseURL + "/login")
        request.checks = [.status(200), APICheck(kind: .jsonPath, target: "$.token", op: .equals, expected: "zzz")]
        request.captures = [APICapture(variable: "token", path: "$.token")]
        let collection = APICollection(name: "C", items: [.request(request)])
        workspace.save(collection)
        let sender = APIRequestSender()
        let done = expectation(description: "sent")
        var results: [APIChecks.Result] = []
        APISending.send(request, in: collection, workspace: workspace, environment: nil, sender: sender) { _, checks in results = checks; done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(results.map(\.passed), [true, false])
        XCTAssertEqual(workspace.history.first?.status, 200)
        XCTAssertEqual(workspace.history.first?.requestID, request.id)
        XCTAssertEqual(workspace.variables(for: collection, environment: nil).resolve("{{token}}"), "abc")
    }
}

final class APICookieTests: XCTestCase {
    func testSetCookieHeadersBecomeCookies() throws {
        let server = try MockHTTPServer()
        defer { server.stop() }
        server.routes["/login"] = MockHTTPServer.Route(status: 200, headers: [("Content-Type", "application/json"),
                                                                              ("Set-Cookie", "token=abc123; Path=/; HttpOnly"),
                                                                              ("Set-Cookie", "theme=dark; Path=/; Max-Age=3600")],
                                                       body: Data("{}".utf8))
        let sender = APIRequestSender()
        let done = expectation(description: "answered")
        var received: APIResponse?
        let context = APIRequestSender.Context(variables: APIVariables(), inheritedAuth: [], environment: nil, projectRoot: nil)
        sender.send(try APIRequestSender.resolve(APIRequest(name: "r", method: .post, url: server.baseURL + "/login"), context: context), environment: nil) { result in
            if case .success(let response) = result { received = response }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        let response = try XCTUnwrap(received)
        XCTAssertEqual(Set(response.cookies.map(\.name)), ["token", "theme"])
        XCTAssertEqual(response.cookies.first { $0.name == "token" }?.httpOnly, true)
        XCTAssertTrue(response.headers.contains { $0.name.lowercased() == "set-cookie" })
    }
}
