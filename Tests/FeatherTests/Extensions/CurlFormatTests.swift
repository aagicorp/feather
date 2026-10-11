import XCTest
@testable import Feather

/// curl command lines as people paste them, and the line Feather writes for a request.
final class CurlFormatTests: XCTestCase {
    private func parse(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> APIRequest {
        try XCTUnwrap(APIImportExport.importCurl(text), "not read as curl: \(text)", file: file, line: line)
    }

    func testSimpleGet() throws {
        let request = try parse("curl https://api.example.com/users?page=2")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.url, "https://api.example.com/users?page=2")
        XCTAssertEqual(request.name, "GET /users")
        XCTAssertEqual(request.body.kind, .none)
        XCTAssertEqual(request.auth, .inherit)
    }

    func testMultiLineJSONPost() throws {
        let request = try parse("""
        curl -X POST https://api.example.com/v1/users \\
          -H 'Content-Type: application/json' \\
          -H "Authorization: Bearer abc.def" \\
          -d '{"name": "Ann O'\\''Brien", "tags": ["a", "b"]}'
        """)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url, "https://api.example.com/v1/users")
        XCTAssertEqual(request.headers.map { "\($0.name): \($0.value)" }, ["Content-Type: application/json"])
        XCTAssertEqual(request.auth, APIAuth(kind: .bearer, token: "abc.def"))
        XCTAssertEqual(request.body.kind, .raw)
        XCTAssertEqual(request.body.contentType, "application/json")
        XCTAssertEqual(request.body.text, #"{"name": "Ann O'Brien", "tags": ["a", "b"]}"#)
    }

    func testDataImpliesPostAndFormFields() throws {
        let request = try parse("curl -d 'user=ann&pass=s%20cret' -d 'remember=1' http://localhost:8080/login")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body.kind, .urlencoded)
        XCTAssertEqual(request.body.fields.map { "\($0.name)=\($0.value)" }, ["user=ann", "pass=s cret", "remember=1"])
    }

    func testJSONDataWithoutHeaderIsJSON() throws {
        let request = try parse(#"curl --data-raw '{"a": 1}' http://h/x"#)
        XCTAssertEqual(request.body, .json(#"{"a": 1}"#))
    }

    func testLowercaseMethodAttachedValueAndUrlOption() throws {
        let request = try parse("curl -XPatch --url 'http://h/items/7' -H'X-Trace: 1'")
        XCTAssertEqual(request.method, .patch)
        XCTAssertEqual(request.url, "http://h/items/7")
        XCTAssertEqual(request.headers.map(\.name), ["X-Trace"])
    }

    func testFormWithFilesAndFields() throws {
        let request = try parse("curl -F 'photo=@/tmp/front.jpg;type=image/jpeg' -F caption='Front view' -F 'meta=<meta.json' https://h/photos")
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body.kind, .multipart)
        XCTAssertEqual(request.body.files.map { "\($0.name)=\($0.path)" }, ["photo=/tmp/front.jpg"])
        XCTAssertEqual(request.body.fields.map { "\($0.name)=\($0.value)" }, ["caption=Front view", "meta=<meta.json"])
    }

    func testBasicAuthUser() throws {
        let request = try parse("curl -u admin:s3cr:et https://h/private")
        XCTAssertEqual(request.auth, APIAuth(kind: .basic, username: "admin", password: "s3cr:et"))
        let header = try parse("curl -H 'Authorization: Basic \(Data("u:p".utf8).base64EncodedString())' https://h/")
        XCTAssertEqual(header.auth, APIAuth(kind: .basic, username: "u", password: "p"))
        XCTAssertTrue(header.headers.isEmpty)
    }

    func testHeadersWithColonsInValues() throws {
        let request = try parse("curl -H 'X-Time: 12:30:00' -H \"Accept: text/html; q=0.9\" -H 'X-Empty;' https://h/a")
        XCTAssertEqual(request.headers.map { "\($0.name)=\($0.value)" }, ["X-Time=12:30:00", "Accept=text/html; q=0.9", "X-Empty="])
    }

    func testJSONOptionAndBunchedFlags() throws {
        let request = try parse(#"curl -sSL --json '{"q": "x"}' https://h/search | jq ."#)
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.body.kind, .raw)
        XCTAssertEqual(request.headers.map { "\($0.name)=\($0.value)" }, ["Content-Type=application/json", "Accept=application/json"])
        XCTAssertEqual(request.url, "https://h/search")
    }

    func testGetWithDataBecomesParams() throws {
        let request = try parse("curl -G -d 'q=coach bus' --data-urlencode 'sort=name' https://h/search")
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.params.map { "\($0.name)=\($0.value)" }, ["q=coach bus", "sort=name"])
        XCTAssertEqual(request.body.kind, .none)
    }

    func testBrowserCopyAsCurl() throws {
        let request = try parse("""
        curl 'https://example.com/api/items?limit=20' \\
          -H 'accept: application/json, text/plain, */*' \\
          -H 'accept-language: en-GB,en;q=0.9' \\
          -H 'cookie: session=abc123; theme=dark' \\
          -H 'user-agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' \\
          --compressed
        """)
        XCTAssertEqual(request.method, .get)
        XCTAssertEqual(request.headers.count, 4)
        XCTAssertEqual(request.headers[2].value, "session=abc123; theme=dark")
        XCTAssertEqual(request.url, "https://example.com/api/items?limit=20")
    }

    func testPromptSudoHeadAndUnknownOptions() throws {
        XCTAssertEqual(try parse("$ curl -I https://h/").method, .head)
        XCTAssertEqual(try parse("sudo curl -k --max-time 5 -o out.bin https://h/file").url, "https://h/file")
        XCTAssertEqual(try parse("curl -X delete http://h/x").method, .delete)
        XCTAssertNil(APIImportExport.importCurl("wget https://h/"))
        XCTAssertNil(APIImportExport.importCurl("curl -H 'X: y'"), "no address, no request")
        XCTAssertTrue(CurlFormat.looksLikeCurl("  curl -s http://x"))
        XCTAssertFalse(CurlFormat.looksLikeCurl("GET http://x"))
    }

    func testDoubleQuotedEscapesAndAnsiQuotes() throws {
        let request = try parse(#"curl -d "{\"a\": \"b\"}" -H $'X-Multi: one\ttwo' http://h/"#)
        XCTAssertEqual(request.body.text, #"{"a": "b"}"#)
        XCTAssertEqual(request.headers.first?.value, "one\ttwo")
    }

    func testWritingResolvesVariablesAndAuth() throws {
        var request = APIRequest(name: "r", method: .post, url: "{{base}}/items")
        request.body = .json(#"{"n": "{{name}}"}"#)
        request.auth = APIAuth(kind: .bearer, token: "{{token}}")
        let variables = APIVariables(environment: [APIVariable("base", "http://h:9"), APIVariable("name", "x"), APIVariable("token", "T")])
        let curl = APIImportExport.curl(for: request, variables: variables)
        XCTAssertTrue(curl.contains("-X POST"))
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer T'"))
        XCTAssertTrue(curl.contains(#"--data-raw '{"n": "x"}'"#))
        XCTAssertTrue(curl.hasSuffix("'http://h:9/items'"))
        // What Feather writes, Feather reads back.
        let back = try parse(curl)
        XCTAssertEqual(back.method, .post)
        XCTAssertEqual(back.auth.token, "T")
        XCTAssertEqual(back.body.text, #"{"n": "x"}"#)

        var upload = APIRequest(name: "u", method: .post, url: "http://h/photos")
        upload.body = APIBody(kind: .multipart, fields: [APIKeyValue("caption", "Front")], files: [APIFormFile(name: "photo", path: "/tmp/a.jpg")])
        let form = APIImportExport.curl(for: upload, variables: APIVariables())
        XCTAssertTrue(form.contains("-F 'caption=Front'"))
        XCTAssertTrue(form.contains("-F 'photo=@/tmp/a.jpg'"))
        XCTAssertFalse(form.contains("--data-raw"))

        // A request without a valid address still gets a line, unresolved.
        XCTAssertTrue(APIImportExport.curl(for: APIRequest(name: "x", url: ""), variables: APIVariables()).hasPrefix("curl"))
    }
}
