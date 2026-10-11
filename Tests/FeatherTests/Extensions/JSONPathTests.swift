import XCTest
@testable import Feather

/// The JSON path evaluator used by checks and captures.
final class JSONPathTests: XCTestCase {
    private let json: Any = try! JSONSerialization.jsonObject(with: Data("""
    {"user": {"id": 42, "name": "Ada", "tags": ["x", "y"], "active": true, "manager": null},
     "items": [{"id": 1, "name": "a", "price": 9.5}, {"id": 2, "name": "b", "price": 20}, {"id": 3, "name": "c b", "price": 3}],
     "a key": "spaced", "nested": {"deep": {"id": 99}}}
    """.utf8))

    private func first(_ path: String) -> String? { JSONPath.firstText(path, in: json) }

    func testPlainPaths() {
        XCTAssertEqual(first("$.user.id"), "42")
        XCTAssertEqual(first("user.name"), "Ada")
        XCTAssertEqual(first("$.user.tags[1]"), "y")
        XCTAssertEqual(first("$.user.tags[-1]"), "y")
        XCTAssertEqual(first("$.user.active"), "true")
        XCTAssertEqual(first("$.user.manager"), "null")
        XCTAssertEqual(first("$['a key']"), "spaced")
        XCTAssertEqual(first("$.items[1].price"), "20")
        XCTAssertEqual(first("$.items[0].price"), "9.5")
        XCTAssertNil(first("$.user.missing"))
        XCTAssertNil(first("$.items[9]"))
    }

    func testWildcardsFiltersAndRecursion() {
        XCTAssertEqual(JSONPath.evaluate("$.items[*].id", in: json).map(JSONPath.text), ["1", "2", "3"])
        XCTAssertEqual(JSONPath.evaluate("$.items[?(@.price > 5)].name", in: json).map(JSONPath.text), ["a", "b"])
        XCTAssertEqual(JSONPath.evaluate("$.items[?(@.name == 'c b')].id", in: json).map(JSONPath.text), ["3"])
        XCTAssertEqual(JSONPath.evaluate("$.items[?(@.id != 2)].id", in: json).map(JSONPath.text), ["1", "3"])
        XCTAssertEqual(JSONPath.evaluate("$..id", in: json).map(JSONPath.text), ["1", "2", "3", "99", "42"])
        XCTAssertEqual(first("$.items.length"), "3")
        XCTAssertEqual(first("$.user.name.length"), "3")
        XCTAssertEqual(JSONPath.evaluate("$.user[*]", in: json).count, 5)
    }

    func testContainersAsText() {
        XCTAssertEqual(first("$.user.tags"), #"["x","y"]"#)
        XCTAssertEqual(first("$.nested"), #"{"deep":{"id":99}}"#)
    }

    func testBadPaths() {
        XCTAssertNil(JSONPath.parse("$.[a"))
        XCTAssertNil(JSONPath.parse("$.."))
        XCTAssertNil(JSONPath.parse("$.items[?(id == 1)]"))
        XCTAssertEqual(JSONPath.evaluate("what", in: json).count, 0)
        XCTAssertEqual(JSONPath.parse("$"), [])
        XCTAssertEqual(JSONPath.evaluate("$", in: json).count, 1)
    }
}
