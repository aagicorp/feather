import XCTest
@testable import Feather

/// Checks (the forms that judge an answer) and captures (values taken from it).
final class APIChecksTests: XCTestCase {
    private func response(status: Int = 200, body: String = #"{"token": "t0k", "user": {"id": 42, "role": "admin"}, "items": [1,2,3]}"#,
                          headers: [(String, String)] = [("Content-Type", "application/json")], duration: TimeInterval = 0.12) -> APIResponse {
        APIResponse(status: status, statusText: "", headers: headers.map { (name: $0.0, value: $0.1) }, body: Data(body.utf8), bodyFile: nil,
                    duration: duration, size: body.utf8.count, url: nil, cookies: [])
    }

    private func result(_ check: APICheck, _ response: APIResponse) -> APIChecks.Result { APIChecks.evaluate([check], response: response)[0] }

    func testStatusAndTime() {
        XCTAssertTrue(result(.status(200), response()).passed)
        let failed = result(.status(200), response(status: 404))
        XCTAssertFalse(failed.passed)
        XCTAssertEqual(failed.message, "status 404 is not 200")
        XCTAssertTrue(result(APICheck(kind: .status, op: .lessThan, expected: "300"), response(status: 204)).passed)
        XCTAssertTrue(result(APICheck(kind: .time, op: .lessThan, expected: "500"), response(duration: 0.12)).passed)
        XCTAssertFalse(result(APICheck(kind: .time, op: .lessThan, expected: "100"), response(duration: 0.12)).passed)
    }

    func testJSONPathChecks() {
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.user.role", op: .equals, expected: "admin"), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.user.id", op: .equals, expected: "42.0"), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.token", op: .exists), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.missing", op: .notExists), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.items.length", op: .greaterThan, expected: "2"), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .jsonPath, target: "$.token", op: .matches, expected: "^t[0-9]k$"), response()).passed)
        let missing = result(APICheck(kind: .jsonPath, target: "$.nope", op: .equals, expected: "x"), response())
        XCTAssertFalse(missing.passed)
        XCTAssertEqual(missing.actual, "not present")
        XCTAssertEqual(missing.message, "$.nope nothing is not x")
        XCTAssertFalse(result(APICheck(kind: .jsonPath, target: "$.x", op: .exists), response(body: "not json")).passed)
    }

    func testHeaderAndBodyChecks() {
        XCTAssertTrue(result(APICheck(kind: .header, target: "content-type", op: .contains, expected: "json"), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .header, target: "X-Missing", op: .notExists), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .bodyContains, op: .contains, expected: "ADMIN"), response()).passed)
        XCTAssertTrue(result(APICheck(kind: .bodyContains, op: .notContains, expected: "guest"), response()).passed)
        var disabled = APICheck.status(500)
        disabled.enabled = false
        XCTAssertTrue(APIChecks.evaluate([disabled], response: response()).isEmpty)
    }

    func testCaptures() {
        let captures = [APICapture(variable: "token", path: "$.token"), APICapture(variable: "kind", path: "Content-Type", source: .header),
                        APICapture(variable: "code", path: "", source: .status), APICapture(variable: "none", path: "$.missing")]
        let found = APIChecks.capture(captures, response: response())
        XCTAssertEqual(found.map { "\($0.capture.variable)=\($0.value)" }, ["token=t0k", "kind=application/json", "code=200"])
    }
}
