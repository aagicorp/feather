import XCTest
@testable import Feather

/// Covers Preview/StaticFileServer.swift: the rules that decide the answer to a request (only GET, only our
/// own host names, never above the folder, never a hidden file, folders redirect to a trailing slash and then
/// serve index.html), the MIME table, and one real server on a port the system picks.
final class StaticFileServerRulesTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        outside = TestSupport.temporaryDirectory("feather-outside")
        root = outside.appendingPathComponent("site", isDirectory: true)
        try TestSupport.write([
            "index.html": "<h1>Home</h1>",
            "app.js": "console.log(1)",
            "docs/index.html": "<p>docs</p>",
            "empty/.keep": "",
            "über straße.txt": "ok",
            ".env": "SECRET=1",
            "secret.txt": "outside",
        ], under: root)
        try FileManager.default.moveItem(at: root.appendingPathComponent("secret.txt"), to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside.appendingPathComponent("secret.txt"))
    }

    override func tearDown() { try? FileManager.default.removeItem(at: outside) }

    private func respond(_ requestLine: String, host: String? = "127.0.0.1:8000") -> StaticFileServer.Response {
        var head = requestLine
        if let host { head += "\r\nHost: \(host)" }
        return StaticFileServer.response(toHead: head, root: root.resolvingSymlinksInPath(), port: 8000)
    }

    private func body(_ response: StaticFileServer.Response) -> String { String(decoding: response.body, as: UTF8.self) }

    func testAFileIsServedWithItsType() {
        let response = respond("GET /app.js HTTP/1.1")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(body(response), "console.log(1)")
        XCTAssertEqual(response.headers.first { $0.0 == "Content-Type" }?.1, "text/javascript; charset=utf-8")
    }

    func testOnlyGetIsAnswered() {
        let post = respond("POST /app.js HTTP/1.1")
        XCTAssertEqual(post.status, 405)
        XCTAssertEqual(post.headers.first { $0.0 == "Allow" }?.1, "GET")
        XCTAssertEqual(respond("HEAD /app.js HTTP/1.1").status, 405)
        XCTAssertEqual(respond("GET /app.js").status, 400)
        XCTAssertEqual(respond("GET /app.js SPDY/3").status, 400)
        XCTAssertEqual(respond("").status, 400)
    }

    func testOnlyOurOwnHostNamesAreAnswered() {
        XCTAssertEqual(respond("GET /app.js HTTP/1.1", host: nil).status, 403)
        XCTAssertEqual(respond("GET /app.js HTTP/1.1", host: "evil.example:8000").status, 403)
        XCTAssertEqual(respond("GET /app.js HTTP/1.1", host: "127.0.0.1:8001").status, 403)
        XCTAssertEqual(respond("GET /app.js HTTP/1.1", host: "LocalHost:8000").status, 200)
        XCTAssertEqual(respond("GET /app.js HTTP/1.1", host: " 127.0.0.1:8000 ").status, 200)
    }

    func testNothingAboveTheFolder() {
        XCTAssertEqual(respond("GET /../secret.txt HTTP/1.1").status, 403)
        XCTAssertEqual(respond("GET /docs/../../secret.txt HTTP/1.1").status, 403)
        XCTAssertEqual(respond("GET /%2e%2e/secret.txt HTTP/1.1").status, 403)
        XCTAssertEqual(respond("GET /..%5Csecret.txt HTTP/1.1").status, 403)
        XCTAssertEqual(respond("GET /escape.txt HTTP/1.1").status, 403, "a symbolic link out of the folder")
        XCTAssertEqual(respond("GET http://127.0.0.1:8000/app.js HTTP/1.1").status, 400)
        XCTAssertEqual(respond("GET * HTTP/1.1").status, 400)
        XCTAssertEqual(respond("GET /app%00.js HTTP/1.1").status, 400)
    }

    func testHiddenFilesAndMissingFilesAreNotFound() {
        XCTAssertEqual(respond("GET /.env HTTP/1.1").status, 404)
        XCTAssertEqual(respond("GET /empty/.keep HTTP/1.1").status, 404)
        XCTAssertEqual(respond("GET /nothing.js HTTP/1.1").status, 404)
        XCTAssertEqual(respond("GET /empty/ HTTP/1.1").status, 404, "a folder without index.html")
    }

    func testFoldersRedirectToTheSlashAndThenServeIndex() {
        let redirect = respond("GET /docs?x=1 HTTP/1.1")
        XCTAssertEqual(redirect.status, 301)
        XCTAssertEqual(redirect.headers.first { $0.0 == "Location" }?.1, "/docs/")
        XCTAssertEqual(body(respond("GET /docs/ HTTP/1.1")), "<p>docs</p>")
        XCTAssertEqual(body(respond("GET / HTTP/1.1")), "<h1>Home</h1>")
        XCTAssertEqual(body(respond("GET /./docs/./index.html HTTP/1.1")), "<p>docs</p>")
    }

    func testQueryFragmentAndPercentEncodingAreHandled() {
        XCTAssertEqual(body(respond("GET /app.js?v=2#top HTTP/1.1")), "console.log(1)")
        XCTAssertEqual(body(respond("GET /%C3%BCber%20stra%C3%9Fe.txt HTTP/1.1")), "ok")
    }

    func testMimeTypes() {
        func type(_ name: String) -> String { StaticFileServer.mimeType(of: URL(fileURLWithPath: "/x/" + name)) }
        XCTAssertEqual(type("a.html"), "text/html; charset=utf-8")
        XCTAssertEqual(type("a.HTM"), "text/html; charset=utf-8")
        XCTAssertEqual(type("a.css"), "text/css; charset=utf-8")
        XCTAssertEqual(type("a.mjs"), "text/javascript; charset=utf-8")
        XCTAssertEqual(type("a.json"), "application/json; charset=utf-8")
        XCTAssertEqual(type("a.svg"), "image/svg+xml")
        XCTAssertEqual(type("a.wasm"), "application/wasm")
        XCTAssertEqual(type("a.png"), "image/png")
        XCTAssertEqual(type("a.jpg"), "image/jpeg")
        XCTAssertEqual(type("a.feather-unknown"), "application/octet-stream")
        XCTAssertEqual(type("Makefile"), "application/octet-stream")
    }

    func testPlainResponsesEndInANewline() {
        let response = StaticFileServer.Response.plain(404, "Not found", headers: [("X-A", "1")])
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "Not found\n")
        XCTAssertEqual(response.headers.map(\.0), ["Content-Type", "X-A"])
    }
}

final class StaticFileServerNetworkTests: XCTestCase {
    private var root: URL!
    private var server: StaticFileServer!

    override func setUpWithError() throws {
        root = TestSupport.temporaryDirectory("feather-site")
        try TestSupport.write(["index.html": "<h1>Hi</h1>", "sub/page.html": "<p>sub</p>"], under: root)
        server = StaticFileServer(root: root)
        var port: UInt16??
        server.start { port = .some($0) }
        XCTAssertTrue(TestSupport.wait { port != nil })
        XCTAssertEqual(port ?? nil, server.port)
        XCTAssertNotEqual(server.port, 0)
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func fetch(_ path: String, method: String = "GET") -> (status: Int, body: String, headers: [String: String])? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var result: (Int, String, [String: String])?
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                let headers = Dictionary(uniqueKeysWithValues: http.allHeaderFields.compactMap { key, value in
                    (key as? String).map { ($0.lowercased(), "\(value)") }
                })
                result = (http.statusCode, String(decoding: data ?? Data(), as: UTF8.self), headers)
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return result
    }

    func testServesAFileAndSaysNotFound() throws {
        let home = try XCTUnwrap(fetch("/"))
        XCTAssertEqual(home.status, 200)
        XCTAssertEqual(home.body, "<h1>Hi</h1>")
        XCTAssertEqual(home.headers["content-type"], "text/html; charset=utf-8")
        XCTAssertEqual(home.headers["cache-control"], "no-store")
        XCTAssertEqual(home.headers["x-content-type-options"], "nosniff")
        XCTAssertEqual(fetch("/sub/page.html")?.body, "<p>sub</p>")
        XCTAssertEqual(fetch("/missing.html")?.status, 404)
        XCTAssertEqual(fetch("/", method: "POST")?.status, 405)
    }

    func testAddressOfAFileBelowTheRoot() {
        XCTAssertEqual(server.address(of: root.appendingPathComponent("sub/page.html"))?.absoluteString,
                       "http://127.0.0.1:\(server.port)/sub/page.html")
        XCTAssertNil(server.address(of: root.deletingLastPathComponent().appendingPathComponent("elsewhere.html")))
        XCTAssertEqual(server.address(of: root.appendingPathComponent("a b.html"))?.path, "/a b.html")
    }

    func testTwoServersGetDifferentPorts() {
        let other = StaticFileServer(root: root)
        var port: UInt16??
        other.start { port = .some($0) }
        XCTAssertTrue(TestSupport.wait { port != nil })
        XCTAssertNotEqual(port ?? nil, server.port)
        other.stop()
    }
}
