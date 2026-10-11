import XCTest
@testable import Feather

/// The API client's saved shapes: JSON round trips, the collection tree helpers, and Copy as cURL.
final class APIModelsTests: XCTestCase {
    private func sample() -> APICollection {
        var login = APIRequest(name: "Login", method: .post, url: "{{baseUrl}}/auth/login")
        login.body = .json(#"{"email": "{{email}}"}"#)
        login.checks = [.status(200), APICheck(kind: .jsonPath, target: "$.token", op: .exists)]
        login.captures = [APICapture(variable: "token", path: "$.token")]
        let health = APIRequest(name: "Health", url: "{{baseUrl}}/health")
        var collection = APICollection(name: "MotorCoach", items: [.folder(APIFolder(name: "Auth", items: [.request(login)])), .request(health)])
        collection.variables = [APIVariable("baseUrl", "http://localhost:8080"), APIVariable("apiKey", "s3cret", secret: true)]
        return collection
    }

    func testCollectionRoundTripsThroughJSON() throws {
        let collection = sample()
        let data = try APIJSON.encoder.encode(collection)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"kind\" : \"folder\""))
        XCTAssertTrue(text.contains("\"format\" : 1"))
        let back = try APIJSON.decoder.decode(APICollection.self, from: data)
        XCTAssertEqual(back, collection)
    }

    func testUnknownKeysAreIgnoredAndMissingOnesDefault() throws {
        let json = #"{"format": 1, "id": "c1", "name": "Old", "items": [{"kind": "request", "request": {"id": "r1", "name": "Ping", "url": "http://x", "futureKey": 5}}], "somethingNew": true}"#
        let collection = try APIJSON.decoder.decode(APICollection.self, from: Data(json.utf8))
        XCTAssertEqual(collection.allRequests.map(\.request.name), ["Ping"])
        XCTAssertEqual(collection.allRequests.first?.request.method, .get)
        XCTAssertEqual(collection.auth, .none)
    }

    func testTreeHelpers() {
        var collection = sample()
        let requests = collection.allRequests
        XCTAssertEqual(requests.map(\.request.name), ["Login", "Health"])
        XCTAssertEqual(requests.first?.path.map(\.name), ["Auth"])
        var login = requests[0].request
        login.name = "Sign in"
        XCTAssertTrue(collection.update(login))
        XCTAssertEqual(collection.request(id: login.id)?.name, "Sign in")
        XCTAssertFalse(collection.update(APIRequest(name: "Stranger")))
        let folderID = collection.items.first!.id
        XCTAssertTrue(collection.insert(.request(APIRequest(name: "Logout")), into: folderID))
        XCTAssertEqual(collection.allRequests.map(\.request.name), ["Sign in", "Logout", "Health"])
        XCTAssertTrue(collection.remove(id: login.id))
        XCTAssertFalse(collection.remove(id: "nope"))
        XCTAssertEqual(collection.allRequests.map(\.request.name), ["Logout", "Health"])
        XCTAssertTrue(collection.insert(.request(APIRequest(name: "Top")), into: nil))
        XCTAssertEqual(collection.items.last?.name, "Top")
    }

    func testCurlLine() {
        let resolved = APIResolvedRequest(method: .post, url: URL(string: "https://api.example.com/v1/users?x=1")!,
                                          headers: [(name: "Content-Type", value: "application/json"), (name: "Authorization", value: "Bearer it's")],
                                          body: Data(#"{"a":1}"#.utf8), bodyDescription: nil)
        let curl = resolved.curl
        XCTAssertTrue(curl.hasPrefix("curl \\\n  -X POST"))
        XCTAssertTrue(curl.contains("-H 'Authorization: Bearer it'\\''s'"))
        XCTAssertTrue(curl.contains("--data-raw '{\"a\":1}'"))
        XCTAssertTrue(curl.hasSuffix("'https://api.example.com/v1/users?x=1'"))
        XCTAssertFalse(APIResolvedRequest(method: .get, url: URL(string: "http://a")!, headers: [], body: nil, bodyDescription: nil).curl.contains("-X"))
    }

    func testResponseHelpers() {
        let response = APIResponse(status: 201, statusText: "Created", headers: [(name: "content-type", value: "application/json; charset=utf-8")],
                                   body: Data(#"{"id": 7}"#.utf8), bodyFile: nil, duration: 0.2, size: 9, url: nil, cookies: [])
        XCTAssertTrue(response.isSuccess)
        XCTAssertTrue(response.isJSON)
        XCTAssertEqual(response.header("CONTENT-TYPE"), "application/json; charset=utf-8")
        XCTAssertEqual((response.json as? [String: Any])?["id"] as? Int, 7)
    }
}
