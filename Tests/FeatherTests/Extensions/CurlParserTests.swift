import XCTest
@testable import Feather

/// Reading a `curl` line into a request, and finding one in a line of terminal output.
final class CurlParserTests: XCTestCase {
    func testShellWords() {
        XCTAssertEqual(CurlParser.words(#"curl -H 'X: a b' -d "{\"k\": \"v\"}" http://h"#), ["curl", "-H", "X: a b", "-d", #"{"k": "v"}"#, "http://h"])
        XCTAssertEqual(CurlParser.words("curl \\\n  -s \\\n  http://h"), ["curl", "-s", "http://h"])
        XCTAssertEqual(CurlParser.words("a\\ b 'it'\\''s'"), ["a b", "it's"])
        XCTAssertEqual(CurlParser.words("curl 'unfinished"), ["curl", "unfinished"])
        XCTAssertEqual(CurlParser.words("  "), [])
    }

    func testPostWithJSONAndBearer() throws {
        let request = try XCTUnwrap(CurlParser.parse(#"curl -X POST 'http://localhost:3000/auth/login' -H 'Content-Type: application/json' -H 'Authorization: Bearer T0K' --data-raw '{"email": "a@b.c"}'"#))
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, "http://localhost:3000/auth/login")
        XCTAssertEqual(request.name, "POST /auth/login")
        XCTAssertEqual(request.headers.map(\.name), ["Content-Type"])
        XCTAssertEqual(request.auth.kind, .bearer)
        XCTAssertEqual(request.auth.token, "T0K")
        XCTAssertEqual(request.body.kind, .raw)
        XCTAssertEqual(request.body.text, #"{"email": "a@b.c"}"#)
        XCTAssertEqual(request.body.contentType, "application/json")
    }

    func testMethodsAreInferred() throws {
        XCTAssertEqual(CurlParser.parse("curl http://h/x")?.method, .get)
        XCTAssertEqual(CurlParser.parse("curl -d a=1 http://h/x")?.method, .post)
        XCTAssertEqual(CurlParser.parse("curl -I http://h/x")?.method, .head)
        XCTAssertEqual(CurlParser.parse("curl -XPUT http://h/x")?.method, .put)
        XCTAssertEqual(CurlParser.parse("curl --request=DELETE http://h/x")?.method, .delete)
        let form = try XCTUnwrap(CurlParser.parse("curl -d a=1 -d 'b=two words' http://h/x"))
        XCTAssertEqual(form.body.kind, .urlencoded)
        XCTAssertEqual(form.body.fields.map { "\($0.name)=\($0.value)" }, ["a=1", "b=two words"])
        let get = try XCTUnwrap(CurlParser.parse("curl -G -d q=1 http://h/x"))
        XCTAssertEqual(get.method, .get)
        XCTAssertEqual(get.params.map { "\($0.name)=\($0.value)" }, ["q=1"])
        XCTAssertEqual(get.body.kind, .none)
    }

    func testBasicAuthFormsAndIgnoredOptions() throws {
        let request = try XCTUnwrap(CurlParser.parse("curl -sSL -u me:secret -o out.json --max-time 5 -F name=Ann -F photo=@./me.png -A Feather api.example.com/upload"))
        XCTAssertEqual(request.url, "http://api.example.com/upload", "an address without a scheme gets http://")
        XCTAssertEqual(request.auth.kind, .basic)
        XCTAssertEqual(request.auth.username, "me")
        XCTAssertEqual(request.auth.password, "secret")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body.kind, .multipart)
        XCTAssertEqual(request.body.fields.map(\.value), ["Ann"])
        XCTAssertEqual(request.body.files.map(\.path), ["./me.png"])
        XCTAssertEqual(request.headers.map { "\($0.name)=\($0.value)" }, ["User-Agent=Feather"])
    }

    func testJSONOptionAndCookies() throws {
        let request = try XCTUnwrap(CurlParser.parse(#"curl --json '{"a":1}' -b 'session=x' http://h/x"#))
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body.contentType, "application/json")
        XCTAssertEqual(request.headers.map(\.name), ["Cookie", "Content-Type"])
    }

    func testNotCurlOrNoAddress() {
        XCTAssertNil(CurlParser.parse("ls -la"))
        XCTAssertNil(CurlParser.parse("curl -s"))
        XCTAssertNil(CurlParser.parse("curl --version"))
        XCTAssertNil(CurlParser.parse("curl 'http://'"))
    }

    func testDetectionInTerminalLines() {
        XCTAssertEqual(CurlDetection.command(in: "$ curl -s http://localhost:3000/health"), "curl -s http://localhost:3000/health")
        XCTAssertEqual(CurlDetection.command(in: "❯ curl http://h/x | jq ."), "curl http://h/x | jq .")
        XCTAssertEqual(CurlDetection.command(in: "● Bash(curl -s http://localhost:8080/api/v1/users)"), "curl -s http://localhost:8080/api/v1/users")
        XCTAssertEqual(CurlDetection.command(in: "Try: `curl http://h/x`"), "curl http://h/x")
        XCTAssertEqual(CurlDetection.command(in: "Run `curl -X POST http://h/x \\\n  -d a=1`"), "curl -X POST http://h/x \\\n  -d a=1")
        let continued = CurlDetection.command(in: "$ curl -X POST \\\n> -H 'X: 1' \\\n> http://h/x")
        XCTAssertEqual(continued, "curl -X POST \\\n-H 'X: 1' \\\nhttp://h/x")
        XCTAssertEqual(CurlParser.parse(continued ?? "")?.url, "http://h/x")
        XCTAssertNil(CurlDetection.command(in: "curl: (7) Failed to connect to localhost port 3000"))
        XCTAssertNil(CurlDetection.command(in: "brew install curl"))
        XCTAssertNil(CurlDetection.command(in: "see docs/curl.md for details"))
        XCTAssertNil(CurlDetection.command(in: ""))
    }
}
