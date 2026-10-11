import XCTest
@testable import Feather

/// The import/export dispatcher: telling formats apart, files and folders, Feather's own files, curl files
/// with several commands, and exporting a whole workspace.
final class APIImportExportTests: XCTestCase {
    private var root: URL!
    private var personal: URL!
    private var previousPersonal: URL!
    private var previousSecrets: SecretStore!

    override func setUp() {
        super.setUp()
        root = TestSupport.temporaryDirectory("feather-api-import")
        personal = TestSupport.temporaryDirectory("feather-api-import-personal")
        previousPersonal = APIWorkspace.personalBaseDirectory
        previousSecrets = APIWorkspace.secrets
        APIWorkspace.personalBaseDirectory = personal
        APIWorkspace.secrets = MemorySecretStore()
    }

    override func tearDown() {
        APIWorkspace.personalBaseDirectory = previousPersonal
        APIWorkspace.secrets = previousSecrets
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: personal)
        super.tearDown()
    }

    func testDetectsFormatsByContent() throws {
        XCTAssertEqual(APIImportExport.detect(text: PostmanFormatTests.sample), .postmanCollection)
        XCTAssertEqual(APIImportExport.detect(text: #"{"name": "E", "values": []}"#), .postmanEnvironment)
        XCTAssertEqual(APIImportExport.detect(text: #"{"openapi": "3.0.0"}"#), .openAPI)
        XCTAssertEqual(APIImportExport.detect(text: "openapi: 3.0.0\npaths: {}"), .openAPI)
        XCTAssertEqual(APIImportExport.detect(text: String(decoding: try APIJSON.encoder.encode(APICollection(name: "C")), as: UTF8.self)), .featherCollection)
        XCTAssertEqual(APIImportExport.detect(text: String(decoding: try APIJSON.encoder.encode(APIEnvironment(name: "E")), as: UTF8.self)), .featherEnvironment)
        XCTAssertEqual(APIImportExport.detect(text: "$ curl -s http://x"), .curl)
        XCTAssertEqual(APIImportExport.detect(text: "POST http://x/y\n\n{}"), .http)
        XCTAssertNil(APIImportExport.detect(text: "just some prose"))
        XCTAssertNil(APIImportExport.detect(text: "{not json"))
        XCTAssertNil(APIImportExport.detect(text: "a: 1", hint: URL(fileURLWithPath: "/x/notes.yaml")))
    }

    func testCanImportByExtensionContentAndFolder() throws {
        try TestSupport.write(["a.json": "{}", "b.http": "", "c.yaml": "", "d.txt": "", "noext": "curl http://x", "prose": "hello", "e.png": "x"], under: root)
        XCTAssertTrue(APIImportExport.canImport(url: root.appendingPathComponent("a.json")))
        XCTAssertTrue(APIImportExport.canImport(url: root.appendingPathComponent("b.http")))
        XCTAssertTrue(APIImportExport.canImport(url: root.appendingPathComponent("c.yaml")))
        XCTAssertTrue(APIImportExport.canImport(url: root.appendingPathComponent("d.txt")))
        XCTAssertTrue(APIImportExport.canImport(url: root.appendingPathComponent("noext")))
        XCTAssertFalse(APIImportExport.canImport(url: root.appendingPathComponent("prose")))
        XCTAssertFalse(APIImportExport.canImport(url: root.appendingPathComponent("e.png")))
        XCTAssertTrue(APIImportExport.canImport(url: root))
    }

    func testImportsFilesAndFoldersOfMixedFormats() throws {
        var collection = APICollection(name: "Own", items: [.request(APIRequest(name: "Ping", url: "http://x"))])
        collection.variables = [APIVariable("k", "v")]
        try TestSupport.write([
            "postman.json": PostmanFormatTests.sample,
            "env/staging.postman_environment.json": #"{"name": "Staging", "values": [{"key": "a", "value": "1"}]}"#,
            "own.json": String(decoding: APIJSON.encoder.encode(collection), as: UTF8.self),
            "requests.http": HTTPFileFormatTests.sample,
            "commands.txt": "# two commands\ncurl -X POST http://h/a \\\n  -d 'x=1'\n\ncurl http://h/b | jq .\nwget http://ignored\n",
            "notes.txt": "nothing to see here",
            "picture.png": "not text",
            ".hidden/secret.json": PostmanFormatTests.sample,
        ], under: root)
        // One file.
        let one = try APIImportExport.importFile(at: root.appendingPathComponent("commands.txt"))
        XCTAssertEqual(one.collections.map(\.name), ["commands"])
        XCTAssertEqual(one.collections[0].allRequests.map(\.request.name), ["POST /a", "GET /b"])
        XCTAssertEqual(one.collections[0].allRequests[0].request.body.fields.first?.value, "1")
        // Feather's own file comes back as it was.
        XCTAssertEqual(try APIImportExport.importFile(at: root.appendingPathComponent("own.json")).collections, [collection])
        // A folder: everything importable, subfolders one level down, hidden folders left alone.
        let all = try APIImportExport.importFile(at: root)
        XCTAssertEqual(all.collections.map(\.name).sorted(), ["MotorCoach API", "Own", "commands", "requests"])
        XCTAssertEqual(all.environments.map(\.name), ["Staging"])
        XCTAssertTrue(all.notes.contains { $0.contains("notes.txt") }, "\(all.notes)")
        XCTAssertEqual(all.summary, "4 collections and 1 environment")
        // Errors are plain.
        XCTAssertThrowsError(try APIImportExport.importFile(at: root.appendingPathComponent("notes.txt"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("not in a format Feather can import"), error.localizedDescription)
        }
        XCTAssertThrowsError(try APIImportExport.importFile(at: root.appendingPathComponent("missing.json")))
        XCTAssertThrowsError(try APIImportExport.importText("{\"a\": 1}", named: "odd")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a Postman, OpenAPI or Feather file"), error.localizedDescription)
        }
    }

    func testCurlCommandsSplitOnCommandStarts() {
        let text = "curl http://a \\\n -H 'X: 1'\ncurl http://b\n  -H 'continues without backslash'\n"
        let commands = APIImportExport.curlCommands(in: text)
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].contains("X: 1"))
        XCTAssertTrue(commands[1].contains("continues"))
    }

    func testAddingToWorkspaceAndExportingEverything() throws {
        let workspace = APIWorkspace(projectRoot: root)
        let imported = try APIImportExport.importText(PostmanFormatTests.sample, named: "sample")
        var environment = APIEnvironment(name: "Prod/Live", variables: [APIVariable("baseUrl", "https://live"), APIVariable("token", "t", secret: true)])
        environment.id = "env-1"
        var withEnvironment = imported
        withEnvironment.environments = [environment]
        APIImportExport.add(withEnvironment, to: workspace)
        XCTAssertEqual(workspace.collections.map(\.value.name), ["MotorCoach API"])
        XCTAssertEqual(workspace.environments.map(\.value.name), ["Prod/Live"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".feather/api/collections/MotorCoach API.json").path))

        let folder = root.appendingPathComponent("export")
        let written = try APIImportExport.exportWorkspace(to: folder, workspace: workspace)
        XCTAssertEqual(written.map(\.lastPathComponent), ["MotorCoach API.postman_collection.json", "Prod-Live.postman_environment.json"])
        let environmentText = try String(contentsOf: written[1], encoding: .utf8)
        XCTAssertFalse(environmentText.contains("\"t\""), "secret values stay out of exports")
        XCTAssertTrue(environmentText.contains("\"type\" : \"secret\""))

        // And the folder imports back into another workspace.
        let back = try APIImportExport.importFile(at: folder)
        XCTAssertEqual(back.collections.map(\.name), ["MotorCoach API"])
        XCTAssertEqual(back.environments.map(\.name), ["Prod/Live"])
        XCTAssertEqual(back.environments[0].variables.map(\.secret), [false, true])
    }
}
