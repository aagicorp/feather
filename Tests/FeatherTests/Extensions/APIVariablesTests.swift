import XCTest
@testable import Feather

/// `{{variables}}`: precedence, nesting, built-ins, secrets, and what is reported missing.
final class APIVariablesTests: XCTestCase {
    func testPrecedenceAndNesting() {
        let variables = APIVariables(collection: [APIVariable("host", "localhost"), APIVariable("baseUrl", "http://{{host}}:{{port}}"), APIVariable("port", "1")],
                                     environment: [APIVariable("port", "8080"), APIVariable("off", "x", secret: false)],
                                     captured: ["token": "abc"])
        XCTAssertEqual(variables.resolve("{{baseUrl}}/users?t={{token}}"), "http://localhost:8080/users?t=abc")
        XCTAssertEqual(variables.resolve("{{ port }}"), "8080")
        XCTAssertEqual(variables.resolve("plain"), "plain")
        XCTAssertEqual(variables.resolve("{{unknown}}/{{token}}"), "{{unknown}}/abc")
        XCTAssertEqual(variables.unresolved(in: "{{unknown}}/{{token}}/{{$uuid}}"), ["unknown"])
        XCTAssertEqual(variables.names, ["baseUrl", "host", "off", "port", "token"])
    }

    func testDisabledVariablesAreSkipped() {
        var disabled = APIVariable("a", "1")
        disabled.enabled = false
        XCTAssertEqual(APIVariables(environment: [disabled]).resolve("{{a}}"), "{{a}}")
    }

    func testBuiltIns() {
        let variables = APIVariables()
        XCTAssertNotNil(Int(variables.resolve("{{$timestamp}}")))
        XCTAssertEqual(variables.resolve("{{$uuid}}").count, 36)
        XCTAssertNotNil(Int(variables.resolve("{{$randomInt}}")))
        XCTAssertTrue(variables.resolve("{{$isoTimestamp}}").contains("T"))
    }

    func testSecretsComeFromTheStore() {
        let store = MemorySecretStore()
        store.write(scope: "env1", name: "apiKey", value: "from-keychain")
        let variables = APIVariables(environment: [APIVariable("apiKey", "", secret: true)], secrets: store, environmentID: "env1")
        XCTAssertEqual(variables.resolve("k={{apiKey}}"), "k=from-keychain")
        XCTAssertEqual(variables.secretNames, ["apiKey"])
        XCTAssertEqual(APIVariables(environment: [APIVariable("apiKey", "inline", secret: true)], secrets: store, environmentID: "other").resolve("{{apiKey}}"), "inline")
    }

    func testACycleStopsAfterAFewRounds() {
        let variables = APIVariables(environment: [APIVariable("a", "{{b}}"), APIVariable("b", "{{a}}")])
        XCTAssertTrue(variables.resolve("{{a}}").hasPrefix("{{"))
    }
}
