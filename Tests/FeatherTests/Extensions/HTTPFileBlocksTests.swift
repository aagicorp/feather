import XCTest
@testable import Feather

/// Reading the request blocks of a `.http` file for the editor strip.
final class HTTPFileBlocksTests: XCTestCase {
    private let sample = """
    @baseUrl = http://localhost:3000
    @token = abc

    ### Login
    # a comment
    POST {{baseUrl}}/auth/login HTTP/1.1
    Content-Type: application/json
    Authorization: Bearer {{token}}

    {
      "email": "a@b.c",
      "password": "{{missing}}"
    }

    ###
    # @name health
    GET {{baseUrl}}/health

    ### Search
    {{baseUrl}}/search
        ?q=coach
        &page=2
    Accept: application/json

    ###
    DELETE https://api.example.com/things/7?force=1
    """

    func testBlocksMethodsAndNames() {
        let blocks = HTTPFileBlocks.parse(sample)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.map(\.request.method), [.post, .get, .get, .delete])
        XCTAssertEqual(blocks.map(\.request.name), ["Login", "health", "Search", "DELETE /things/7"])
        XCTAssertEqual(blocks.map(\.line), [5, 16, 19, 25])
    }

    func testFileVariablesHeadersAndBody() {
        let login = HTTPFileBlocks.parse(sample)[0].request
        XCTAssertEqual(login.url, "http://localhost:3000/auth/login")
        XCTAssertEqual(login.headers.map { "\($0.name)=\($0.value)" }, ["Content-Type=application/json", "Authorization=Bearer abc"])
        XCTAssertEqual(login.body.kind, .raw)
        XCTAssertEqual(login.body.contentType, "application/json")
        XCTAssertTrue(login.body.text.hasPrefix("{\n"))
        XCTAssertTrue(login.body.text.contains("\"password\": \"{{missing}}\""), "an unknown variable is left for the environment")
        XCTAssertTrue(login.body.text.hasSuffix("}"))
    }

    func testQueryContinuationLinesAndMissingMethod() {
        let search = HTTPFileBlocks.parse(sample)[2].request
        XCTAssertEqual(search.method, .get)
        XCTAssertEqual(search.url, "http://localhost:3000/search?q=coach&page=2")
        XCTAssertEqual(search.headers.first?.name, "Accept")
    }

    func testRangesAndBlockUnderCursor() {
        let blocks = HTTPFileBlocks.parse(sample)
        let ns = sample as NSString
        XCTAssertEqual(ns.substring(with: blocks[0].range).hasPrefix("# a comment"), true)
        XCTAssertTrue(ns.substring(with: blocks[0].range).hasSuffix("}"))
        XCTAssertEqual(ns.substring(with: blocks[1].range), "# @name health\nGET {{baseUrl}}/health")
        let inLogin = ns.range(of: "\"email\"").location
        XCTAssertEqual(HTTPFileBlocks.block(at: inLogin, in: blocks)?.request.name, "Login")
        XCTAssertEqual(HTTPFileBlocks.block(at: 0, in: blocks)?.request.name, "Login", "above every block, the first one")
        XCTAssertEqual(HTTPFileBlocks.block(at: ns.length, in: blocks)?.request.name, "DELETE /things/7")
        let betweenBlocks = ns.range(of: "### Search").location - 1
        XCTAssertEqual(HTTPFileBlocks.block(at: betweenBlocks, in: blocks)?.request.name, "health")
    }

    func testFormBodyAndBodyWithoutBlankLine() {
        let text = "POST http://h/form\nContent-Type: application/x-www-form-urlencoded\n\na=1&b=two%20words\n"
        let form = HTTPFileBlocks.parse(text)[0].request
        XCTAssertEqual(form.body.kind, .urlencoded)
        XCTAssertEqual(form.body.fields.map { "\($0.name)=\($0.value)" }, ["a=1", "b=two words"])
        let plain = HTTPFileBlocks.parse("PUT http://h/x\nhello there\n")[0].request
        XCTAssertEqual(plain.body.kind, .raw)
        XCTAssertEqual(plain.body.text, "hello there")
        XCTAssertEqual(plain.body.contentType, "text/plain")
    }

    func testJunkAndEmptyFiles() {
        XCTAssertEqual(HTTPFileBlocks.parse(""), [])
        XCTAssertEqual(HTTPFileBlocks.parse("# only a comment\n\n###\n"), [])
        XCTAssertEqual(HTTPFileBlocks.parse("TRACE http://h/x"), [], "a method the client does not have is skipped")
        XCTAssertEqual(HTTPFileBlocks.parse("GET http://h/a\n###\nGET http://h/b\n").count, 2)
        XCTAssertTrue(HTTPFileBlocks.isHTTPFile(URL(fileURLWithPath: "/x/a.HTTP")))
        XCTAssertTrue(HTTPFileBlocks.isHTTPFile(URL(fileURLWithPath: "/x/a.rest")))
        XCTAssertFalse(HTTPFileBlocks.isHTTPFile(URL(fileURLWithPath: "/x/a.ts")))
        XCTAssertFalse(HTTPFileBlocks.isHTTPFile(nil))
    }

    func testDefaultNames() {
        XCTAssertEqual(HTTPFileBlocks.defaultName(method: .get, url: "http://h:3000/users/42?x=1"), "GET /users/42")
        XCTAssertEqual(HTTPFileBlocks.defaultName(method: .post, url: "https://h"), "POST /")
        XCTAssertEqual(HTTPFileBlocks.defaultName(method: .get, url: "{{baseUrl}}/health"), "GET {{baseUrl}}/health")
    }
}
