import XCTest
@testable import Feather

/// Postman collection v2.1 and environment files: reading a real-shaped export, writing one Postman opens,
/// and the round trip through both.
final class PostmanFormatTests: XCTestCase {
    /// A trimmed copy of what Postman exports for a small collection.
    static let sample = #"""
    {
      "info": {
        "_postman_id": "9d1c3e2a-1111-4c1e-9c3a-000000000001",
        "name": "MotorCoach API",
        "description": "Requests for the booking service.",
        "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
      },
      "item": [
        {
          "name": "Auth",
          "item": [
            {
              "name": "Login",
              "event": [
                { "listen": "prerequest", "script": { "type": "text/javascript", "exec": [""] } },
                { "listen": "test", "script": { "type": "text/javascript", "exec": [
                  "pm.test(\"status is 200\", function () { pm.response.to.have.status(200); });",
                  "pm.environment.set(\"token\", pm.response.json().token);"
                ] } }
              ],
              "request": {
                "auth": { "type": "noauth" },
                "method": "POST",
                "header": [
                  { "key": "Content-Type", "value": "application/json" },
                  { "key": "X-Debug", "value": "1", "disabled": true }
                ],
                "body": {
                  "mode": "raw",
                  "raw": "{\n  \"email\": \"{{email}}\",\n  \"password\": \"{{password}}\"\n}",
                  "options": { "raw": { "language": "json" } }
                },
                "url": {
                  "raw": "{{baseUrl}}/auth/login?remember=true",
                  "host": ["{{baseUrl}}"],
                  "path": ["auth", "login"],
                  "query": [ { "key": "remember", "value": "true" } ]
                },
                "description": "Signs in and returns a token."
              },
              "response": []
            }
          ],
          "auth": { "type": "basic", "basic": [ { "key": "username", "value": "admin", "type": "string" }, { "key": "password", "value": "pw", "type": "string" } ] }
        },
        {
          "name": "Get booking",
          "request": {
            "method": "GET",
            "header": [],
            "url": {
              "raw": "{{baseUrl}}/bookings/:id",
              "host": ["{{baseUrl}}"],
              "path": ["bookings", ":id"],
              "variable": [ { "key": "id", "value": "42" } ]
            }
          },
          "response": []
        },
        {
          "name": "Upload photo",
          "request": {
            "auth": { "type": "apikey", "apikey": [ { "key": "key", "value": "X-Api-Key", "type": "string" }, { "key": "value", "value": "{{apiKey}}", "type": "string" }, { "key": "in", "value": "header", "type": "string" } ] },
            "method": "PUT",
            "header": [],
            "body": {
              "mode": "formdata",
              "formdata": [
                { "key": "caption", "value": "Front", "type": "text" },
                { "key": "photo", "type": "file", "src": "/tmp/front.jpg" }
              ]
            },
            "url": "https://api.example.com/photos"
          },
          "response": []
        },
        {
          "name": "Search",
          "request": {
            "method": "POST",
            "header": [ { "key": "Accept", "value": "application/json" } ],
            "body": { "mode": "urlencoded", "urlencoded": [ { "key": "q", "value": "coach" }, { "key": "limit", "value": "10", "disabled": true } ] },
            "url": { "raw": "https://api.example.com/search", "protocol": "https", "host": ["api", "example", "com"], "path": ["search"] }
          },
          "response": []
        },
        {
          "name": "Old digest",
          "request": { "auth": { "type": "digest", "digest": [] }, "method": "PURGE", "url": "https://api.example.com/cache" },
          "response": []
        }
      ],
      "auth": { "type": "bearer", "bearer": [ { "key": "token", "value": "{{token}}", "type": "string" } ] },
      "variable": [
        { "key": "baseUrl", "value": "https://api.example.com", "type": "string" },
        { "key": "apiKey", "value": "", "type": "secret" }
      ]
    }
    """#

    private func imported() throws -> APIImportExport.Imported {
        try APIImportExport.importText(PostmanFormatTests.sample, named: "sample")
    }

    func testReadsCollectionTreeRequestsAndBodies() throws {
        let result = try imported()
        XCTAssertEqual(result.collections.count, 1)
        let collection = result.collections[0]
        XCTAssertEqual(collection.name, "MotorCoach API")
        XCTAssertEqual(collection.id, "9d1c3e2a-1111-4c1e-9c3a-000000000001")
        XCTAssertEqual(collection.description, "Requests for the booking service.")
        XCTAssertEqual(collection.allRequests.map(\.request.name), ["Login", "Get booking", "Upload photo", "Search", "Old digest"])
        XCTAssertEqual(collection.allRequests[0].path.map(\.name), ["Auth"])

        let login = collection.allRequests[0].request
        XCTAssertEqual(login.method, .post)
        XCTAssertEqual(login.url, "{{baseUrl}}/auth/login")
        XCTAssertEqual(login.params.map { "\($0.name)=\($0.value)" }, ["remember=true"])
        XCTAssertEqual(login.headers.map(\.name), ["Content-Type", "X-Debug"])
        XCTAssertEqual(login.headers.map(\.enabled), [true, false])
        XCTAssertEqual(login.body.kind, .raw)
        XCTAssertEqual(login.body.contentType, "application/json")
        XCTAssertTrue(login.body.text.contains("\"email\": \"{{email}}\""))
        XCTAssertEqual(login.auth, .none)
        XCTAssertEqual(login.description, "Signs in and returns a token.")

        let booking = collection.allRequests[1].request
        XCTAssertEqual(booking.url, "{{baseUrl}}/bookings/{{id}}")
        XCTAssertEqual(collection.variables.map(\.name), ["baseUrl", "apiKey", "id"])
        XCTAssertEqual(collection.variables[2].value, "42")

        let upload = collection.allRequests[2].request
        XCTAssertEqual(upload.method, .put)
        XCTAssertEqual(upload.body.kind, .multipart)
        XCTAssertEqual(upload.body.fields.map(\.name), ["caption"])
        XCTAssertEqual(upload.body.files.map(\.path), ["/tmp/front.jpg"])
        XCTAssertEqual(upload.auth.kind, .apiKey)
        XCTAssertEqual(upload.auth.keyName, "X-Api-Key")
        XCTAssertEqual(upload.auth.keyIn, .header)

        let search = collection.allRequests[3].request
        XCTAssertEqual(search.url, "https://api.example.com/search")
        XCTAssertEqual(search.body.kind, .urlencoded)
        XCTAssertEqual(search.body.fields.map(\.enabled), [true, false])

        let digest = collection.allRequests[4].request
        XCTAssertEqual(digest.method, .get, "an unknown method falls back to GET")
        XCTAssertEqual(digest.auth, .inherit)
    }

    func testAuthKindsVariablesAndScripts() throws {
        let collection = try imported().collections[0]
        XCTAssertEqual(collection.auth.kind, .bearer)
        XCTAssertEqual(collection.auth.token, "{{token}}")
        guard case .folder(let auth) = collection.items[0] else { return XCTFail("first item is the Auth folder") }
        XCTAssertEqual(auth.auth, APIAuth(kind: .basic, username: "admin", password: "pw"))
        XCTAssertEqual(collection.variables[0].value, "https://api.example.com")
        XCTAssertTrue(collection.variables[1].secret)

        let login = collection.allRequests[0].request
        XCTAssertEqual(login.importedScripts?.keys.sorted(), ["test"], "an empty prerequest script is not kept")
        XCTAssertTrue(login.importedScripts?["test"]?.contains("pm.environment.set") == true)

        let notes = try imported().notes
        XCTAssertTrue(notes.contains { $0.contains("scripts") && $0.contains("Login") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("digest") }, "\(notes)")
        XCTAssertTrue(notes.contains { $0.contains("PURGE") }, "\(notes)")
    }

    func testExportOpensAsPostmanAndRoundTrips() throws {
        var collection = try imported().collections[0]
        var login = collection.allRequests[0].request
        login.checks = [.status(200), APICheck(kind: .jsonPath, target: "$.token", op: .exists), APICheck(kind: .header, target: "Content-Type", op: .contains, expected: "json")]
        login.captures = [APICapture(variable: "token", path: "$.token"), APICapture(variable: "kind", path: "Content-Type", source: .header, scope: .collection)]
        collection.update(login)
        collection.variables[1].value = "hidden-value"

        let data = APIImportExport.exportPostman(collection)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let info = try XCTUnwrap(json["info"] as? [String: Any])
        XCTAssertEqual(info["schema"] as? String, PostmanFormat.schema)
        XCTAssertEqual(info["name"] as? String, "MotorCoach API")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("hidden-value"), "secrets never reach an export")
        XCTAssertTrue(text.contains("Secret variables are left blank in this export: apiKey."))
        XCTAssertTrue(text.contains("- status equals 200"))
        XCTAssertTrue(text.contains("- json $.token exists"))
        XCTAssertTrue(text.contains("- set kind from header Content-Type (collection)"))
        XCTAssertTrue(text.contains("pm.environment.set"), "scripts kept from Postman go back to Postman")
        let items = try XCTUnwrap(json["item"] as? [[String: Any]])
        let authFolder = try XCTUnwrap(items.first)
        XCTAssertNotNil(authFolder["item"])
        let firstRequest = try XCTUnwrap((authFolder["item"] as? [[String: Any]])?.first?["request"] as? [String: Any])
        let url = try XCTUnwrap(firstRequest["url"] as? [String: Any])
        XCTAssertEqual(url["raw"] as? String, "{{baseUrl}}/auth/login?remember=true")
        XCTAssertEqual(url["host"] as? [String], ["{{baseUrl}}"])
        XCTAssertEqual(url["path"] as? [String], ["auth", "login"])
        XCTAssertEqual((firstRequest["body"] as? [String: Any])?["mode"] as? String, "raw")

        // Back in: everything but the ids of rows (which Postman has no place for) and the blank secret.
        let back = try APIImportExport.importText(text, named: "back").collections[0]
        collection.variables[1].value = ""
        XCTAssertEqual(try fingerprint(back), try fingerprint(collection))
        XCTAssertEqual(back.id, collection.id)
        XCTAssertEqual(back.allRequests.map(\.request.id), collection.allRequests.map(\.request.id))
        XCTAssertEqual(back.allRequests[0].request.checks.map(\.kind), [.status, .jsonPath, .header])
        XCTAssertEqual(back.allRequests[0].request.captures.map(\.scope), [.environment, .collection])
        XCTAssertEqual(back.allRequests[0].request.description, "Signs in and returns a token.")
    }

    func testEnvironmentBothWays() throws {
        let json = #"""
        {
          "id": "e1", "name": "Staging",
          "values": [
            { "key": "baseUrl", "value": "https://staging.example.com", "enabled": true, "type": "default" },
            { "key": "token", "value": "abc", "enabled": true, "type": "secret" },
            { "key": "old", "value": "x", "enabled": false }
          ],
          "_postman_variable_scope": "environment"
        }
        """#
        let imported = try APIImportExport.importText(json, named: "Staging")
        XCTAssertTrue(imported.collections.isEmpty)
        let environment = try XCTUnwrap(imported.environments.first)
        XCTAssertEqual(environment.name, "Staging")
        XCTAssertEqual(environment.variables.map(\.name), ["baseUrl", "token", "old"])
        XCTAssertEqual(environment.variables.map(\.secret), [false, true, false])
        XCTAssertEqual(environment.variables.map(\.enabled), [true, true, false])
        XCTAssertEqual(environment.variables[1].value, "abc")

        let data = APIImportExport.exportPostmanEnvironment(environment)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("abc"))
        let back = try XCTUnwrap(try APIImportExport.importText(text, named: "again").environments.first)
        XCTAssertEqual(back.variables.map(\.name), environment.variables.map(\.name))
        XCTAssertEqual(back.variables.map(\.secret), environment.variables.map(\.secret))
        XCTAssertEqual(back.variables[0].value, "https://staging.example.com")
    }

    func testCheckLinesParseBack() {
        let checks = [APICheck.status(201), APICheck(kind: .time, op: .lessThan, expected: "500"),
                      APICheck(kind: .bodyContains, op: .contains, expected: "hello world"),
                      APICheck(kind: .jsonPath, target: "$.items.length", op: .greaterThan, expected: "0"),
                      APICheck(kind: .header, target: "X-Id", op: .exists)]
        let captures = [APICapture(variable: "id", path: "$.id"), APICapture(variable: "code", path: "", source: .status, scope: .collection)]
        let text = APICheckLines.join("Notes here.", checks: checks, captures: captures)
        let (description, backChecks, backCaptures) = APICheckLines.split(text)
        XCTAssertEqual(description, "Notes here.")
        XCTAssertEqual(backChecks.map { APICheckLines.describe($0) }, checks.map { APICheckLines.describe($0) })
        XCTAssertEqual(backCaptures.map { APICheckLines.describe($0) }, captures.map { APICheckLines.describe($0) })
        XCTAssertEqual(APICheckLines.split("plain").text, "plain")
    }

    /// The collection as JSON with every `id` removed, so two copies compare by content.
    private func fingerprint(_ collection: APICollection) throws -> NSDictionary {
        let object = try JSONSerialization.jsonObject(with: APIJSON.encoder.encode(collection))
        func strip(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var copy: [String: Any] = [:]
                for (key, inner) in dict where key != "id" { copy[key] = strip(inner) }
                return copy
            }
            if let list = value as? [Any] { return list.map(strip) }
            return value
        }
        return try XCTUnwrap(strip(object) as? NSDictionary)
    }
}
