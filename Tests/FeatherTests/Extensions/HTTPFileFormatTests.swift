import XCTest
@testable import Feather

/// `.http` files the way VS Code's REST Client writes them, read and written back.
final class HTTPFileFormatTests: XCTestCase {
    static let sample = """
    @baseUrl = http://localhost:8080
    @token = abc123

    ### Health
    GET {{baseUrl}}/health HTTP/1.1
    Accept: application/json

    ###
    # @name login
    # Signs in and keeps the token.
    POST {{baseUrl}}/auth/login
    Content-Type: application/json

    {
      "email": "ann@example.com",
      "password": "pw"
    }

    ### Search with a long query
    GET {{baseUrl}}/search
        ?q=coach
        &limit=10
    Authorization: Bearer {{token}}

    ### Form post
    // @name form
    POST {{baseUrl}}/form
    Content-Type: application/x-www-form-urlencoded

    a=1&b=two%20words

    ### Basic
    GET {{baseUrl}}/private
    Authorization: Basic admin:secret
    """

    func testParsesRequestsHeadersBodiesAndVariables() throws {
        let imported = try APIImportExport.importText(HTTPFileFormatTests.sample, named: "requests", hint: URL(fileURLWithPath: "/x/requests.http"))
        let collection = try XCTUnwrap(imported.collections.first)
        XCTAssertEqual(collection.name, "requests")
        XCTAssertEqual(collection.variables.map { "\($0.name)=\($0.value)" }, ["baseUrl=http://localhost:8080", "token=abc123"])
        let requests = collection.allRequests.map(\.request)
        XCTAssertEqual(requests.map(\.name), ["Health", "login", "Search with a long query", "form", "Basic"])
        XCTAssertEqual(requests.map(\.method), [.get, .post, .get, .post, .get])

        XCTAssertEqual(requests[0].url, "{{baseUrl}}/health")
        XCTAssertEqual(requests[0].headers.map { "\($0.name)=\($0.value)" }, ["Accept=application/json"])
        XCTAssertEqual(requests[0].body.kind, .none)

        XCTAssertEqual(requests[1].description, "Signs in and keeps the token.")
        XCTAssertEqual(requests[1].body.kind, .raw)
        XCTAssertEqual(requests[1].body.contentType, "application/json")
        XCTAssertEqual(requests[1].body.text, "{\n  \"email\": \"ann@example.com\",\n  \"password\": \"pw\"\n}")
        XCTAssertTrue(requests[1].headers.isEmpty, "the content type lives on the body")

        XCTAssertEqual(requests[2].url, "{{baseUrl}}/search?q=coach&limit=10")
        XCTAssertEqual(requests[2].auth, APIAuth(kind: .bearer, token: "{{token}}"))

        XCTAssertEqual(requests[3].body.kind, .urlencoded)
        XCTAssertEqual(requests[3].body.fields.map { "\($0.name)=\($0.value)" }, ["a=1", "b=two words"])

        XCTAssertEqual(requests[4].auth, APIAuth(kind: .basic, username: "admin", password: "secret"))
    }

    func testRoundTrip() throws {
        var login = APIRequest(name: "Login", method: .post, url: "{{baseUrl}}/auth/login")
        login.body = .json("{\"email\": \"{{email}}\"}")
        login.description = "Signs in."
        login.checks = [.status(200), APICheck(kind: .jsonPath, target: "$.token", op: .exists)]
        login.captures = [APICapture(variable: "token", path: "$.token")]
        var list = APIRequest(name: "List bookings", url: "{{baseUrl}}/bookings")
        list.params = [APIKeyValue("page", "2"), APIKeyValue("off", "x", enabled: false)]
        list.headers = [APIKeyValue("Accept", "application/json")]
        list.auth = APIAuth(kind: .bearer, token: "{{token}}")
        var form = APIRequest(name: "Form", method: .put, url: "{{baseUrl}}/form")
        form.body = APIBody(kind: .urlencoded, fields: [APIKeyValue("a b", "1&2")])
        var collection = APICollection(name: "Bookings", items: [.folder(APIFolder(name: "Auth", items: [.request(login)])), .request(list), .request(form)])
        collection.variables = [APIVariable("baseUrl", "http://localhost:8080"), APIVariable("email", "a@b.c"), APIVariable("apiKey", "hidden", secret: true)]

        let text = APIImportExport.exportHTTP(collection)
        XCTAssertTrue(text.hasPrefix("# Bookings\n@baseUrl = http://localhost:8080\n@email = a@b.c\n@apiKey = \n# @secret apiKey\n"))
        XCTAssertFalse(text.contains("hidden"))
        XCTAssertTrue(text.contains("### Auth / Login\n# @name Login\n# Signs in.\n# @check status equals 200\n# @check json $.token exists\n# @set token from json $.token\nPOST {{baseUrl}}/auth/login\nContent-Type: application/json\n\n{\"email\": \"{{email}}\"}\n"))
        XCTAssertTrue(text.contains("GET {{baseUrl}}/bookings?page=2\nAccept: application/json\nAuthorization: Bearer {{token}}\n"))
        XCTAssertTrue(text.contains("PUT {{baseUrl}}/form\nContent-Type: application/x-www-form-urlencoded\n\na%20b=1%262\n"))

        let back = try XCTUnwrap(try APIImportExport.importText(text, named: "Bookings").collections.first)
        let requests = back.allRequests.map(\.request)
        XCTAssertEqual(requests.map(\.name), ["Login", "List bookings", "Form"])
        XCTAssertEqual(requests[0].method, .post)
        XCTAssertEqual(requests[0].body, login.body)
        XCTAssertEqual(requests[0].description, "Signs in.")
        XCTAssertEqual(requests[0].checks.map { APICheckLines.describe($0) }, login.checks.map { APICheckLines.describe($0) })
        XCTAssertEqual(requests[0].captures.map { APICheckLines.describe($0) }, login.captures.map { APICheckLines.describe($0) })
        XCTAssertEqual(requests[1].url, "{{baseUrl}}/bookings?page=2")
        XCTAssertEqual(requests[1].auth, list.auth)
        XCTAssertEqual(requests[1].headers.map(\.name), ["Accept"])
        XCTAssertEqual(requests[2].body.fields.map { "\($0.name)=\($0.value)" }, ["a b=1&2"])
        XCTAssertEqual(back.variables.map { "\($0.name)=\($0.value)" }, ["baseUrl=http://localhost:8080", "email=a@b.c", "apiKey="])
        XCTAssertEqual(back.variables.map(\.secret), [false, false, true])
        // Once more: the text is stable.
        XCTAssertEqual(APIImportExport.exportHTTP(back).components(separatedBy: "###"), text.replacingOccurrences(of: "### Auth / Login", with: "### Login").components(separatedBy: "###"))
    }

    func testMultipartAndInheritedAuthAreWritten() {
        var upload = APIRequest(name: "Upload", method: .post, url: "http://h/photos")
        upload.body = APIBody(kind: .multipart, fields: [APIKeyValue("caption", "Front")], files: [APIFormFile(name: "photo", path: "shots/a.jpg")])
        var collection = APICollection(name: "Photos", items: [.request(upload)])
        collection.auth = APIAuth(kind: .apiKey, keyName: "X-Api-Key", keyValue: "{{apiKey}}")
        let text = APIImportExport.exportHTTP(collection)
        XCTAssertTrue(text.contains("X-Api-Key: {{apiKey}}\n"))
        XCTAssertTrue(text.contains("Content-Type: multipart/form-data; boundary=FeatherBoundary\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"photo\"; filename=\"a.jpg\"\n\n< shots/a.jpg\n"))
        XCTAssertTrue(text.hasSuffix("--FeatherBoundary--\n\n"))
    }

    func testDetection() {
        XCTAssertTrue(HTTPFileFormat.looksLikeHTTPFile("GET http://x/y"))
        XCTAssertTrue(HTTPFileFormat.looksLikeHTTPFile("# a\n\n###\nPOST http://x"))
        XCTAssertFalse(HTTPFileFormat.looksLikeHTTPFile("hello there"))
        XCTAssertEqual(APIImportExport.detect(text: "GET http://x/y"), .http)
        XCTAssertEqual(APIImportExport.detect(text: "curl http://x"), .curl)
    }
}
