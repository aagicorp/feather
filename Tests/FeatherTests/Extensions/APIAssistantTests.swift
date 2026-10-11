import XCTest
@testable import Feather

/// The brief handed to the AI assistant about a request and its answer.
final class APIAssistantTests: XCTestCase {
    private func response(status: Int = 200, body: String, contentType: String = "application/json", duration: TimeInterval = 0.184) -> APIResponse {
        APIResponse(status: status, statusText: status == 200 ? "OK" : "Not Found", headers: [(name: "Content-Type", value: contentType)],
                    body: Data(body.utf8), bodyFile: nil, duration: duration, size: body.utf8.count, url: nil, cookies: [])
    }

    private func resolved() throws -> (APIRequest, APIResolvedRequest) {
        var request = APIRequest(name: "Login", method: .post, url: "http://h/login")
        request.body = .json(#"{"email": "a@b.c"}"#)
        let context = APIRequestSender.Context(variables: APIVariables(), inheritedAuth: [], environment: nil, projectRoot: nil)
        return (request, try APIRequestSender.resolve(request, context: context))
    }

    func testBriefHasCurlStatusBodyAndFailedChecks() throws {
        let (request, resolved) = try resolved()
        let answer = response(body: #"{"token":"t","user":{"id":42}}"#)
        let checks = APIChecks.evaluate([.status(200), APICheck(kind: .jsonPath, target: "$.user.role", op: .equals, expected: "admin")], response: answer)
        let brief = APIAssistant.describe(request: request, resolved: resolved, response: answer, checks: checks)
        let lines = brief.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Look at this API request and its answer, and tell me what is wrong or what to do next.")
        XCTAssertEqual(lines[1], "Request: Login")
        XCTAssertEqual(lines[2], #"curl -X POST -H 'Content-Type: application/json' --data-raw '{"email": "a@b.c"}' 'http://h/login'"#, "the cURL on one line")
        XCTAssertEqual(lines[3], "Answer: 200 OK in 184 ms, 30 B, application/json")
        XCTAssertEqual(lines[4], "Body:")
        XCTAssertEqual(lines[5], "{")
        XCTAssertTrue(brief.contains("  \"token\" : \"t\"") || brief.contains("  \"token\": \"t\""), "the body is pretty-printed")
        XCTAssertTrue(brief.contains("Checks: 1 of 2 failed:"))
        XCTAssertTrue(brief.hasSuffix("- $.user.role nothing is not admin"))
    }

    func testLongBodiesAreCut() throws {
        let (request, resolved) = try resolved()
        let body = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n" + String(repeating: "x", count: 500)
        let brief = APIAssistant.describe(request: request, resolved: resolved, response: response(body: body, contentType: "text/plain"), checks: [])
        XCTAssertTrue(brief.contains("line 40\n… and 61 more lines"))
        XCTAssertFalse(brief.contains("line 41\n"))
        XCTAssertFalse(brief.contains("Checks:"))
        let wide = APIAssistant.describe(request: request, resolved: resolved, response: response(body: String(repeating: "y", count: 500), contentType: "text/plain"), checks: [])
        XCTAssertTrue(wide.contains(String(repeating: "y", count: 200) + "…"))
        XCTAssertFalse(wide.contains(String(repeating: "y", count: 201)))
    }

    func testFailureAndUnsentAndSingleLine() throws {
        let (request, resolved) = try resolved()
        let failed = APIAssistant.describe(request: request, resolved: resolved, response: nil, checks: [], failure: "Nothing is listening at that address.")
        XCTAssertTrue(failed.contains("Answer: none. Nothing is listening at that address."))
        let unsent = APIAssistant.describe(request: request, resolved: nil, response: nil, checks: [])
        XCTAssertTrue(unsent.contains("POST http://h/login\n"))
        XCTAssertTrue(unsent.contains("Answer: not sent yet."))
        let one = APIAssistant.singleLine(failed)
        XCTAssertFalse(one.contains("\n"))
        XCTAssertTrue(one.contains("Request: Login ⏎ curl"))
    }

    func testExchangeAndUnits() throws {
        let (request, resolved) = try resolved()
        let exchange = APIAssistant.Exchange(request: request, resolved: resolved, result: .success(response(status: 404, body: "nope", contentType: "text/plain", duration: 2.5)),
                                             checks: [], date: Date())
        XCTAssertTrue(APIAssistant.describe(exchange).contains("Answer: 404 Not Found in 2.5 s, 4 B, text/plain\nBody:\nnope"))
        XCTAssertEqual(APIAssistant.size(2048), "2.0 KB")
        XCTAssertEqual(APIAssistant.size(3 * 1024 * 1024), "3.0 MB")
        XCTAssertEqual(APIAssistant.duration(0.0004), "0 ms")
    }
}
