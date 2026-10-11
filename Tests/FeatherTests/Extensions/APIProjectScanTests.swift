import XCTest
@testable import Feather

/// Finding a project's OpenAPI files, and what a curl line from the terminal becomes in the workspace.
final class APIProjectScanTests: XCTestCase {
    func testFindsOpenAPIFilesAtTheRootAndInTheUsualFolders() throws {
        let root = TestSupport.temporaryDirectory("feather-openapi")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(APIProjectScan.findOpenAPIFiles(root: root), [])
        try TestSupport.write(["openapi.yaml": "openapi: 3.0.0\n", "docs/swagger.json": "{}", "src/openapi.json": "{}", "api/README.md": "x"], under: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("openapi.json"), withIntermediateDirectories: true)   // a folder, not a file
        let found = APIProjectScan.findOpenAPIFiles(root: root).map { TerminalText.relativePath(of: $0, root: root) }
        XCTAssertEqual(found, ["openapi.yaml", "docs/swagger.json"], "the root first, then the usual folders; nothing deeper")
    }

    func testCurlLineBecomesARequestInTheTerminalCollection() {
        let personal = TestSupport.temporaryDirectory("feather-api-personal")
        let previous = APIWorkspace.personalBaseDirectory
        APIWorkspace.personalBaseDirectory = personal
        defer { APIWorkspace.personalBaseDirectory = previous; try? FileManager.default.removeItem(at: personal) }
        let workspace = APIWorkspace(projectRoot: nil)
        // What APIClientController.addFromTerminal does, without a window.
        func add(_ line: String) -> APICollection? {
            guard let request = CurlParser.parse(line) else { return nil }
            var collection = workspace.collections.first { $0.value.name == APIClientController.terminalCollectionName }?.value
                ?? APICollection(name: APIClientController.terminalCollectionName)
            collection.items.append(.request(request))
            return workspace.save(collection, location: .personal) ? collection : nil
        }
        XCTAssertNotNil(add("curl -s http://localhost:3000/health"))
        XCTAssertNotNil(add("curl -X POST http://localhost:3000/login -d a=1"))
        XCTAssertNil(add("ls"))
        XCTAssertEqual(workspace.collections.count, 1)
        XCTAssertEqual(workspace.collections[0].location, .personal)
        XCTAssertEqual(workspace.collections[0].value.allRequests.map(\.request.name), ["GET /health", "POST /login"])
        let again = APIWorkspace(projectRoot: nil)
        again.load()
        XCTAssertEqual(again.collections.first?.value.allRequests.count, 2)
    }
}
