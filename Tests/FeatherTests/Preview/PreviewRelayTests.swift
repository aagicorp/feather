import XCTest
@testable import Feather

/// Covers Preview/PreviewRelay.swift: the stand-in name the preview visits localhost under, and the pure
/// rewriting of request heads (Host and Origin back to the real name) and response heads (cookies WebKit will
/// keep over plain http, Location and CSP under the stand-in name). The relay's sockets are not tested.
final class PreviewAliasTests: XCTestCase {
    func testTheStandInNamesAndTheirRealHosts() {
        XCTAssertEqual(PreviewAlias.realHost(for: "app.fthr.localhost"), "localhost")
        XCTAssertEqual(PreviewAlias.realHost(for: "IP.FTHR.LOCALHOST"), "127.0.0.1")
        XCTAssertNil(PreviewAlias.realHost(for: "localhost"))
        XCTAssertNil(PreviewAlias.realHost(for: "evil.fthr.localhost"))
        for alias in PreviewAlias.names.values { XCTAssertTrue(alias.hasSuffix("." + PreviewAlias.domain)) }
    }

    func testWireAndShownAreInverses() {
        let real = URL(string: "http://localhost:3000/path?q=1#frag")!
        let wired = PreviewAlias.wire(real)
        XCTAssertEqual(wired.absoluteString, "http://app.fthr.localhost:3000/path?q=1#frag")
        XCTAssertEqual(PreviewAlias.shown(wired), real)
        XCTAssertEqual(PreviewAlias.wire(URL(string: "http://127.0.0.1:8080/")!).host, "ip.fthr.localhost")
        // https keeps its cookies, so it keeps its name; other hosts are not ours.
        XCTAssertEqual(PreviewAlias.wire(URL(string: "https://localhost:3000/")!).host, "localhost")
        XCTAssertEqual(PreviewAlias.wire(URL(string: "http://example.com/")!).host, "example.com")
        XCTAssertEqual(PreviewAlias.shown(URL(string: "http://example.com/")!).host, "example.com")
    }

    func testRequestHeadRestoresTheRealNamesAndClosesTheConnection() {
        let head = ["GET /api HTTP/1.1", "Host: app.fthr.localhost:3000", "Origin: http://APP.fthr.localhost:3000",
                    "Referer: http://app.fthr.localhost:3000/page", "Proxy-Connection: keep-alive", "Keep-Alive: timeout=5",
                    "Connection: keep-alive", "Accept: */*", "junk line without a colon"].joined(separator: "\r\n")
        let result = PreviewAlias.requestHead(head)
        XCTAssertFalse(result.isUpgrade)
        XCTAssertEqual(result.head.components(separatedBy: "\r\n"), [
            "GET /api HTTP/1.1", "Host: localhost:3000", "Origin: http://localhost:3000", "Referer: http://localhost:3000/page",
            "Accept: */*", "Connection: close",
        ])
    }

    func testAWebSocketUpgradeKeepsItsConnectionHeader() {
        let head = "GET /ws HTTP/1.1\r\nHost: ip.fthr.localhost:5173\r\nConnection: Upgrade\r\nUpgrade: websocket"
        let result = PreviewAlias.requestHead(head)
        XCTAssertTrue(result.isUpgrade)
        XCTAssertEqual(result.head, "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:5173\r\nConnection: Upgrade\r\nUpgrade: websocket")
    }

    func testCookiesBecomeOnesWebKitKeepsOverPlainHTTP() {
        XCTAssertEqual(PreviewAlias.cookie("sid=abc; Path=/; Secure; HttpOnly; Domain=localhost; SameSite=None"),
                       "sid=abc; Path=/; HttpOnly; SameSite=Lax")
        XCTAssertEqual(PreviewAlias.cookie("sid=abc; SameSite = none; Partitioned;; Max-Age=3600"), "sid=abc; SameSite=Lax; Max-Age=3600")
        XCTAssertEqual(PreviewAlias.cookie("a=1; SameSite=Strict"), "a=1; SameSite=Strict")
        XCTAssertEqual(PreviewAlias.cookie("a=1"), "a=1")
        XCTAssertEqual(PreviewAlias.cookie("a=b=c; secure"), "a=b=c")
        // Prefixed names promise Secure by their spelling: touching them would only get them refused differently.
        XCTAssertEqual(PreviewAlias.cookie("__Secure-id=1; Secure; Domain=localhost"), "__Secure-id=1; Secure; Domain=localhost")
        XCTAssertEqual(PreviewAlias.cookie("__Host-id=1; Secure; Path=/"), "__Host-id=1; Secure; Path=/")
    }

    func testResponseHeadRewritesCookiesRedirectsAndPolicies() {
        let head = ["HTTP/1.1 302 Found", "Set-Cookie: sid=1; Secure; SameSite=None", "Location: http://localhost:3000/next",
                    "Access-Control-Allow-Origin: http://127.0.0.1:3000", "Content-Location: /localhost/file",
                    "Content-Security-Policy: default-src 'self' localhost:8080 ws://localhost:3000 http://localhost.example",
                    "Keep-Alive: timeout=5", "Connection: keep-alive", "X-Other: localhost"].joined(separator: "\r\n")
        XCTAssertEqual(PreviewAlias.responseHead(head).components(separatedBy: "\r\n"), [
            "HTTP/1.1 302 Found",
            "Set-Cookie: sid=1; SameSite=Lax",
            "Location: http://app.fthr.localhost:3000/next",
            "Access-Control-Allow-Origin: http://ip.fthr.localhost:3000",
            "Content-Location: /localhost/file",                     // only after "//": a path is not a host
            "Content-Security-Policy: default-src 'self' app.fthr.localhost:8080 ws://app.fthr.localhost:3000 http://localhost.example",
            "X-Other: localhost",                                    // an unknown header is passed through untouched
            "Connection: close",
        ])
    }

    func testASwitchingProtocolsAnswerKeepsItsConnection() {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade"
        XCTAssertEqual(PreviewAlias.responseHead(head), head)
    }

    func testAnAnswerWithoutHeadersStillCloses() {
        XCTAssertEqual(PreviewAlias.responseHead("HTTP/1.1 204 No Content"), "HTTP/1.1 204 No Content\r\nConnection: close")
        XCTAssertEqual(PreviewAlias.requestHead("GET / HTTP/1.1").head, "GET / HTTP/1.1\r\nConnection: close")
    }

    func testThePageScriptNamesEveryStandIn() {
        for (real, alias) in PreviewAlias.names {
            XCTAssertTrue(PreviewAlias.pageScript.contains("\"\(real)\":\"\(alias)\""))
        }
        XCTAssertTrue(PreviewAlias.pageScript.contains("window.fetch = function"))
        XCTAssertTrue(PreviewAlias.pageScript.contains("XMLHttpRequest.prototype.open"))
    }
}
