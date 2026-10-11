import XCTest
@testable import Feather

/// OpenAPI descriptions (JSON and YAML) as collections: folders per tag, path parameters, bodies from
/// schemas, servers as environments; and the small YAML reader they rely on.
final class OpenAPIImportTests: XCTestCase {
    static let petstoreYAML = """
    openapi: 3.0.3
    info:
      title: Petstore
      description: |
        A sample API.
        Two lines.
      version: 1.0.0
    servers:
      - url: https://petstore.example.com/api/v3
        description: Production
      - url: http://localhost:{port}/api/v3
        variables:
          port:
            default: "8080"
    tags:
      - name: pet
        description: Everything about pets
      - name: store
    security:
      - api_key: []
    paths:
      /pet:
        post:
          tags: [pet]
          summary: Add a new pet
          operationId: addPet
          security:
            - petstore_auth:
                - write:pets
          requestBody:
            required: true
            content:
              application/json:
                schema:
                  $ref: '#/components/schemas/Pet'
              application/xml:
                schema:
                  $ref: '#/components/schemas/Pet'
          responses:
            '200':
              description: ok
            '405':
              description: bad
      /pet/{petId}:
        parameters:
          - name: petId
            in: path
            required: true
            schema:
              type: integer
            example: 7
        get:
          tags:
            - pet
          summary: Find pet by ID
          parameters:
            - name: X-Trace
              in: header
              schema: { type: string }
            - $ref: '#/components/parameters/Verbose'
          responses:
            "200": { description: ok }
        delete:
          tags: [pet]
          operationId: deletePet
          security: []
          responses:
            '204':
              description: gone
      /store/order:
        post:
          tags: [store]
          summary: Place an order
          deprecated: true
          requestBody:
            content:
              application/x-www-form-urlencoded:
                schema:
                  type: object
                  properties:
                    petId: { type: integer, example: 3 }
                    quantity: { type: integer }
          responses:
            201: { description: created }
      /ping:
        get:
          summary: Ping  # untagged
          responses:
            default: { description: anything }
    components:
      parameters:
        Verbose:
          name: verbose
          in: query
          required: true
          schema:
            type: boolean
            default: false
      securitySchemes:
        api_key:
          type: apiKey
          name: api_key
          in: header
        petstore_auth:
          type: oauth2
          flows: {}
      schemas:
        Category:
          type: object
          properties:
            id: { type: integer, format: int64 }
            name: { type: string, example: Dogs }
        Pet:
          required: [name, photoUrls]
          type: object
          properties:
            id:
              type: integer
              format: int64
              readOnly: true
            name:
              type: string
              example: doggie
            category:
              $ref: '#/components/schemas/Category'
            photoUrls:
              type: array
              items:
                type: string
            tags:
              type: array
              items:
                $ref: '#/components/schemas/Tag'
            status:
              type: string
              enum: [available, pending, sold]
            born:
              type: string
              format: date
            adopted:
              type: boolean
        Tag:
          type: object
          properties:
            name: { type: string }
    """

    private func imported(_ text: String, hint: String = "petstore.yaml") throws -> APIImportExport.Imported {
        try APIImportExport.importText(text, named: "petstore", hint: URL(fileURLWithPath: "/x/" + hint))
    }

    func testYAMLPetstore() throws {
        let result = try imported(OpenAPIImportTests.petstoreYAML)
        let collection = try XCTUnwrap(result.collections.first)
        XCTAssertEqual(collection.name, "Petstore")
        XCTAssertEqual(collection.description, "A sample API.\nTwo lines.\n")

        // Servers: environments named after the address; the first is the collection's own baseUrl.
        XCTAssertEqual(result.environments.map(\.name), ["petstore.example.com/api/v3", "localhost:8080/api/v3"])
        XCTAssertEqual(result.environments[1].variables.map { "\($0.name)=\($0.value)" }, ["baseUrl=http://localhost:8080/api/v3"])
        XCTAssertEqual(collection.variables.first?.value, "https://petstore.example.com/api/v3")

        // Folders per first tag in the file's tag order, untagged at the top level.
        XCTAssertEqual(collection.items.map(\.name), ["pet", "store", "Ping"])
        guard case .folder(let pet) = collection.items[0] else { return XCTFail("pet folder") }
        XCTAssertEqual(pet.description, "Everything about pets")
        XCTAssertEqual(pet.items.map(\.name), ["Add a new pet", "Find pet by ID", "deletePet"])

        let add = try XCTUnwrap(collection.request(id: pet.items[0].id))
        XCTAssertEqual(add.method, .post)
        XCTAssertEqual(add.url, "{{baseUrl}}/pet")
        XCTAssertEqual(add.body.kind, .raw)
        XCTAssertEqual(add.body.contentType, "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(add.body.text.utf8)) as? [String: Any])
        XCTAssertNil(body["id"], "read-only fields are not sent")
        XCTAssertEqual(body["name"] as? String, "doggie")
        XCTAssertEqual((body["category"] as? [String: Any])?["name"] as? String, "Dogs")
        XCTAssertEqual((body["category"] as? [String: Any])?["id"] as? Int, 0)
        XCTAssertEqual(body["photoUrls"] as? [String], ["string"])
        XCTAssertEqual((body["tags"] as? [[String: Any]])?.first?["name"] as? String, "string")
        XCTAssertEqual(body["status"] as? String, "available")
        XCTAssertEqual(body["born"] as? String, "2024-01-01")
        XCTAssertEqual(body["adopted"] as? Bool, false)
        XCTAssertEqual(add.checks.map { APICheckLines.describe($0) }, ["status equals 200"])
        XCTAssertEqual(add.auth.kind, .bearer, "the operation's OAuth differs from the collection's API key")

        let find = try XCTUnwrap(collection.request(id: pet.items[1].id))
        XCTAssertEqual(find.url, "{{baseUrl}}/pet/{{petId}}")
        XCTAssertEqual(find.headers.map { "\($0.name)=\($0.value):\($0.enabled)" }, ["X-Trace=:false"])
        XCTAssertEqual(find.params.map { "\($0.name)=\($0.value):\($0.enabled)" }, ["verbose=false:true"])
        XCTAssertEqual(find.auth, .inherit)
        XCTAssertEqual(collection.variables.map(\.name), ["baseUrl", "petId", "apiKey", "token"])
        XCTAssertEqual(collection.variables[1].value, "7")
        XCTAssertTrue(collection.variables[2].secret)

        let delete = try XCTUnwrap(collection.request(id: pet.items[2].id))
        XCTAssertEqual(delete.method, .delete)
        XCTAssertEqual(delete.auth, .none, "security: [] means no sign-in")
        XCTAssertEqual(delete.checks.first?.expected, "204")

        guard case .folder(let store) = collection.items[1] else { return XCTFail("store folder") }
        let order = try XCTUnwrap(collection.request(id: store.items[0].id))
        XCTAssertEqual(order.body.kind, .urlencoded)
        XCTAssertEqual(order.body.fields.map { "\($0.name)=\($0.value)" }, ["petId=3", "quantity=0"])
        XCTAssertTrue(order.description.hasPrefix("Deprecated."))
        XCTAssertEqual(order.checks.first?.expected, "201")

        XCTAssertEqual(collection.auth, APIAuth(kind: .apiKey, keyName: "api_key", keyValue: "{{apiKey}}", keyIn: .header))
        XCTAssertTrue(result.notes.contains { $0.contains("Path parameters") && $0.contains("petId") }, "\(result.notes)")
        XCTAssertTrue(result.notes.contains { $0.contains("OAuth") }, "\(result.notes)")
    }

    func testJSONPetstoreAndNoServers() throws {
        let json = """
        {
          "openapi": "3.1.0",
          "info": { "title": "Tiny" },
          "paths": {
            "/items": {
              "get": { "summary": "List", "parameters": [ { "name": "page", "in": "query", "schema": { "type": "integer", "default": 1 } } ],
                       "responses": { "200": { "description": "ok" } } },
              "post": { "requestBody": { "content": { "application/json": { "example": { "name": "x", "n": 2 } } } },
                        "responses": { "201": { "description": "made" } } }
            }
          }
        }
        """
        let result = try imported(json, hint: "tiny.json")
        let collection = try XCTUnwrap(result.collections.first)
        XCTAssertEqual(collection.name, "Tiny")
        XCTAssertTrue(result.environments.isEmpty)
        XCTAssertEqual(collection.variables.map { "\($0.name)=\($0.value)" }, ["baseUrl=http://localhost"])
        XCTAssertTrue(result.notes.contains { $0.contains("names no server") })
        XCTAssertEqual(collection.allRequests.map(\.request.name), ["List", "POST /items"])
        XCTAssertEqual(collection.allRequests[0].request.params.map { "\($0.name)=\($0.value)" }, ["page=1"])
        XCTAssertEqual(collection.allRequests[1].request.body.text, "{\n  \"n\" : 2,\n  \"name\" : \"x\"\n}")
        XCTAssertEqual(APIImportExport.detect(text: json), .openAPI)
    }

    func testSwaggerTwoIsRefusedPlainly() {
        XCTAssertThrowsError(try imported(#"{"swagger": "2.0", "info": {"title": "Old"}, "paths": {}}"#, hint: "old.json")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Swagger 2.0"))
        }
    }

    // MARK: YAML

    func testYAMLShapes() throws {
        let text = """
        # a comment
        name: "Quoted \\"x\\""
        single: 'it''s'
        plain: some text with: colon
        url: http://example.com/#anchor
        number: 42
        float: 1.5
        version: 1.0.0
        yes: true
        nothing: ~
        empty:
        list:
          - one
          - key: v
            other: 2
          - [1, 2, "three"]
          - { a: 1, b: [x, y] }
        same_indent_list:
        - a
        - b
        nested:
          deeper:
            deepest: end
        block: |
          line 1
            indented
          line 3
        folded: >-
          one
          two

          three
        multi: first
          second
        """
        let parsed = try XCTUnwrap(try YAMLSubset.parse(text) as? [String: Any])
        XCTAssertEqual(parsed["name"] as? String, "Quoted \"x\"")
        XCTAssertEqual(parsed["single"] as? String, "it's")
        XCTAssertEqual(parsed["plain"] as? String, "some text with: colon")
        XCTAssertEqual(parsed["url"] as? String, "http://example.com/#anchor")
        XCTAssertEqual(parsed["number"] as? Int, 42)
        XCTAssertEqual(parsed["float"] as? Double, 1.5)
        XCTAssertEqual(parsed["version"] as? String, "1.0.0")
        XCTAssertEqual(parsed["yes"] as? Bool, true)
        XCTAssertTrue(parsed["nothing"] is NSNull)
        XCTAssertTrue(parsed["empty"] is NSNull)
        let list = try XCTUnwrap(parsed["list"] as? [Any])
        XCTAssertEqual(list[0] as? String, "one")
        XCTAssertEqual((list[1] as? [String: Any])?["key"] as? String, "v")
        XCTAssertEqual((list[1] as? [String: Any])?["other"] as? Int, 2)
        XCTAssertEqual((list[2] as? [Any])?.count, 3)
        XCTAssertEqual((list[2] as? [Any])?[2] as? String, "three")
        XCTAssertEqual(((list[3] as? [String: Any])?["b"] as? [Any])?.count, 2)
        XCTAssertEqual(parsed["same_indent_list"] as? [String], ["a", "b"])
        XCTAssertEqual(((parsed["nested"] as? [String: Any])?["deeper"] as? [String: Any])?["deepest"] as? String, "end")
        XCTAssertEqual(parsed["block"] as? String, "line 1\n  indented\nline 3\n")
        XCTAssertEqual(parsed["folded"] as? String, "one two\nthree")
        XCTAssertEqual(parsed["multi"] as? String, "first second")
    }

    func testYAMLErrorsCarryLineNumbers() {
        XCTAssertThrowsError(try YAMLSubset.parse("a: 1\n  b: 2\n c: 3")) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("Line 2"), error.localizedDescription)
        }
        XCTAssertThrowsError(try YAMLSubset.parse("a:\n\tb: 1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("tab"), error.localizedDescription)
        }
        XCTAssertThrowsError(try APIImportExport.importText("openapi: 3.0.0\ninfo:\n  title: x\n   bad: y", named: "bad", hint: URL(fileURLWithPath: "/x/bad.yaml"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("YAML"), error.localizedDescription)
        }
    }
}
