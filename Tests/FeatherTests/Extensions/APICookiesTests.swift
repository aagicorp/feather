import XCTest
@testable import Feather

/// The API client's own cookie jar: parsing Set-Cookie, keeping Secure cookies from localhost (which macOS
/// itself refuses), and sending them back with later requests to the same host.
final class APICookiesTests: XCTestCase {
    func testSplittingJoinedSetCookieHeaders() {
        let joined = "a=1; Path=/; Expires=Sun, 27 Sep 2026 14:21:50 GMT; HttpOnly, b=2; Path=/x, c=3"
        XCTAssertEqual(APICookieParser.split(joined: joined), ["a=1; Path=/; Expires=Sun, 27 Sep 2026 14:21:50 GMT; HttpOnly", "b=2; Path=/x", "c=3"])
        XCTAssertEqual(APICookieParser.split(joined: "single=value; Secure"), ["single=value; Secure"])
    }

    func testParsingAttributes() throws {
        let url = URL(string: "http://localhost:8080/api/v1/login")!
        let cookie = try XCTUnwrap(APICookieParser.parse("auth_token=abc; Path=/; Max-Age=259200; Expires=Sun, 27 Sep 2026 14:21:50 GMT; Secure; HttpOnly; SameSite=None", for: url))
        XCTAssertEqual(cookie.name, "auth_token")
        XCTAssertEqual(cookie.value, "abc")
        XCTAssertEqual(cookie.domain, "localhost")
        XCTAssertEqual(cookie.path, "/")
        XCTAssertTrue(cookie.secure && cookie.httpOnly)
        XCTAssertEqual(cookie.sameSite, "None")
        XCTAssertEqual(cookie.expires!.timeIntervalSinceNow, 259200, accuracy: 5)      // Max-Age wins over Expires
        let bare = try XCTUnwrap(APICookieParser.parse("session=x", for: URL(string: "https://api.example.com/v1/users/42")!))
        XCTAssertEqual(bare.path, "/v1/users")
        XCTAssertNil(bare.expires)
        XCTAssertNil(APICookieParser.parse("=novalue", for: url))
        XCTAssertNil(APICookieParser.parse("junk", for: url))
    }

    func testJarKeepsSecureCookiesFromLocalhostAndSendsThemBack() {
        let jar = APICookieJar(file: nil)
        let login = URL(string: "http://localhost:8080/api/v1/login")!
        let stored = jar.store([APICookieParser.parse("auth_token=abc; Path=/; Secure; HttpOnly", for: login)!], from: login)
        XCTAssertNil(stored.first?.notStored)
        XCTAssertEqual(jar.header(for: URL(string: "http://localhost:8080/api/v1/user/validate")!), "auth_token=abc")
        XCTAssertEqual(jar.header(for: URL(string: "http://localhost:3000/anything")!), "auth_token=abc", "cookies do not care about the port")
        XCTAssertNil(jar.header(for: URL(string: "http://example.com/api")!))
        XCTAssertNil(jar.header(for: URL(string: "http://api.example.com/")!))
        // A Secure cookie for a real host still needs https.
        let remote = URL(string: "https://api.example.com/login")!
        jar.store([APICookieParser.parse("s=1; Secure", for: remote)!], from: remote)
        XCTAssertNil(jar.header(for: URL(string: "http://api.example.com/x")!))
        XCTAssertEqual(jar.header(for: URL(string: "https://api.example.com/x")!), "s=1")
        XCTAssertEqual(jar.header(for: URL(string: "https://sub.api.example.com/x")!), nil, "host-only cookie")
    }

    func testDomainPathReplacementAndExpiry() {
        let jar = APICookieJar(file: nil)
        let url = URL(string: "http://localhost/app/page")!
        let parent = APICookieParser.parse("t=1; Domain=.example.com", for: url)!
        XCTAssertNotNil(jar.store([parent], from: url).first?.notStored, "a cookie for another domain is refused")
        jar.store([APICookieParser.parse("a=1; Path=/app", for: url)!, APICookieParser.parse("b=2; Path=/other", for: url)!], from: url)
        XCTAssertEqual(jar.header(for: URL(string: "http://localhost/app/x")!), "a=1")
        XCTAssertEqual(jar.header(for: URL(string: "http://localhost/apple")!), nil, "path match is by segment")
        jar.store([APICookieParser.parse("a=9; Path=/app", for: url)!], from: url)
        XCTAssertEqual(jar.header(for: URL(string: "http://localhost/app/")!), "a=9", "same name, domain and path replaces")
        jar.store([APICookieParser.parse("a=0; Path=/app; Max-Age=0", for: url)!], from: url)
        XCTAssertNil(jar.header(for: URL(string: "http://localhost/app/")!), "an expired cookie removes the old one")
        jar.clear()
        XCTAssertTrue(jar.cookies.isEmpty)
    }

    func testPersistentCookiesSurviveALaunchButSessionOnesDoNot() {
        let file = TestSupport.temporaryDirectory("feather-cookies").appendingPathComponent("cookies.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let url = URL(string: "http://localhost/")!
        let jar = APICookieJar(file: file)
        jar.store([APICookieParser.parse("keep=1; Max-Age=3600", for: url)!, APICookieParser.parse("temp=2", for: url)!], from: url)
        let again = APICookieJar(file: file)
        XCTAssertEqual(again.cookies.map(\.name), ["keep"])
    }

    func testLoginThenAuthenticatedRequestThroughTheMockServer() throws {
        let personal = TestSupport.temporaryDirectory("feather-api-personal")
        let previous = APIWorkspace.personalBaseDirectory
        APIWorkspace.personalBaseDirectory = personal
        defer { APIWorkspace.personalBaseDirectory = previous; try? FileManager.default.removeItem(at: personal) }
        let server = try MockHTTPServer()
        defer { server.stop() }
        server.routes["/login"] = MockHTTPServer.Route(headers: [("Content-Type", "application/json"), ("Set-Cookie", "auth_token=secret; Path=/; Secure; HttpOnly; SameSite=None")],
                                                       body: Data("{}".utf8))
        let workspace = APIWorkspace(projectRoot: nil)
        let sender = APIRequestSender()
        let login = expectation(description: "login")
        APISending.send(APIRequest(name: "Login", method: .post, url: server.baseURL + "/login"), in: nil, workspace: workspace, environment: nil, sender: sender) { result, _ in
            if case .success(let response) = result {
                XCTAssertEqual(response.cookies.map(\.name), ["auth_token"])
                XCTAssertNil(response.cookies.first?.notStored)
            } else { XCTFail("login failed") }
            login.fulfill()
        }
        wait(for: [login], timeout: 10)
        let validate = expectation(description: "validate")
        APISending.send(APIRequest(name: "Validate", url: server.baseURL + "/user/validate"), in: nil, workspace: workspace, environment: nil, sender: sender) { _, _ in validate.fulfill() }
        wait(for: [validate], timeout: 10)
        XCTAssertEqual(server.received.last?.headers["cookie"], "auth_token=secret", "the second request carries the cookie from the first")
    }
}
