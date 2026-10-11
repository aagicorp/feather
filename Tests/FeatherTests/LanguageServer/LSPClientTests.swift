import XCTest
@testable import Feather

/// Covers the message framing of LanguageServer/LSPClient.swift: Content-Length headers, bodies that arrive in
/// pieces or several to a chunk, matching answers to requests by id, cancelled requests, notifications and
/// transforms. The client is fed bytes directly; no server process is ever started.
final class LSPClientFramingTests: XCTestCase {
    private var client: LSPClient!

    override func setUp() {
        // A client whose process is never started: `request` still hands out ids and remembers callbacks.
        client = LSPClient(executable: "/usr/bin/true", arguments: [], environment: [:], directory: URL(fileURLWithPath: "/tmp"))
    }

    private func packet(_ json: String) -> Data {
        Data("Content-Length: \(json.utf8.count)\r\n\r\n".utf8) + Data(json.utf8)
    }

    func testARequestIsAnsweredByIdOnTheMainQueue() {
        var answers: [String] = []
        let id = client.request("textDocument/hover", [:]) { result in
            XCTAssertTrue(Thread.isMainThread)
            answers.append((result as? [String: Any])?["contents"] as? String ?? "?")
        }
        XCTAssertEqual(id, 1)
        client.consume(packet(#"{"jsonrpc":"2.0","id":1,"result":{"contents":"doc"}}"#))
        XCTAssertTrue(TestSupport.wait { !answers.isEmpty })
        XCTAssertEqual(answers, ["doc"])
        // Answering again does nothing: the callback was used up.
        client.consume(packet(#"{"jsonrpc":"2.0","id":1,"result":{"contents":"again"}}"#))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(answers, ["doc"])
    }

    func testAnswersGoToTheRightRequestWhateverTheirOrder() {
        var order: [Int] = []
        client.request("a", [:]) { _ in order.append(1) }
        client.request("b", [:]) { _ in order.append(2) }
        client.request("c", [:]) { _ in order.append(3) }
        client.consume(packet(#"{"jsonrpc":"2.0","id":3,"result":null}"#) + packet(#"{"jsonrpc":"2.0","id":1,"result":null}"#))
        XCTAssertTrue(TestSupport.wait { order.count == 2 })
        XCTAssertEqual(order, [3, 1])
        client.consume(packet(#"{"jsonrpc":"2.0","id":99,"result":null}"#))       // nobody asked
        client.consume(packet(#"{"jsonrpc":"2.0","id":2,"result":null}"#))
        XCTAssertTrue(TestSupport.wait { order.count == 3 })
        XCTAssertEqual(order, [3, 1, 2])
    }

    func testAMessageSplitAcrossChunks() {
        let whole = packet(#"{"jsonrpc":"2.0","id":1,"result":[1,2,3]}"#)
        for cut in [5, 22, whole.count - 3] {                          // inside the header, at its end, inside the body
            let client = LSPClient(executable: "/usr/bin/true", arguments: [], environment: [:], directory: URL(fileURLWithPath: "/tmp"))
            var results: [Any?] = []
            client.request("x", [:]) { results.append($0) }
            client.consume(whole[..<cut])
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            XCTAssertTrue(results.isEmpty, "nothing is delivered before the body is complete (cut at \(cut))")
            client.consume(whole[cut...])
            XCTAssertTrue(TestSupport.wait { !results.isEmpty })
            XCTAssertEqual(results.first.flatMap { $0 } as? [Int], [1, 2, 3])
        }
    }

    func testByteByByte() {
        var result: Any??
        client.request("x", [:]) { result = .some($0) }
        for byte in packet(#"{"jsonrpc":"2.0","id":1,"result":"ok"}"#) { client.consume(Data([byte])) }
        XCTAssertTrue(TestSupport.wait { result != nil })
        XCTAssertEqual(result as? String, "ok")
    }

    func testHeadersAreCaseInsensitiveAndMayHaveCompany() {
        var result: Any??
        client.request("x", [:]) { result = .some($0) }
        let body = #"{"jsonrpc":"2.0","id":1,"result":"ok"}"#
        client.consume(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length:  \(body.utf8.count) \r\n\r\n".utf8) + Data(body.utf8))
        XCTAssertTrue(TestSupport.wait { result != nil })
        XCTAssertEqual(result as? String, "ok")
    }

    func testAnErrorAnswerIsNil() {
        var result: Any??
        client.request("x", [:]) { result = .some($0) }
        client.consume(packet(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"no"}}"#))
        XCTAssertTrue(TestSupport.wait { result != nil })
        XCTAssertNil(result ?? nil)
    }

    func testACancelledRequestNeverHearsBack() {
        var heard = false
        let id = client.request("x", [:]) { _ in heard = true }
        client.cancel(id)
        client.cancel(id)                     // twice is fine
        client.cancel(12345)                  // as is an id nobody has
        client.consume(packet(#"{"jsonrpc":"2.0","id":\#(id),"result":"late"}"#))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(heard)
    }

    func testNotificationsFromTheServer() {
        var notes: [(String, [String: Any])] = []
        client.onNotification = { notes.append(($0, $1)) }
        client.consume(packet(#"{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{"uri":"file:///a.ts","diagnostics":[]}}"#)
                       + packet(#"{"jsonrpc":"2.0","method":"$/progress"}"#))
        XCTAssertTrue(TestSupport.wait { notes.count == 2 })
        XCTAssertEqual(notes[0].0, "textDocument/publishDiagnostics")
        XCTAssertEqual(notes[0].1["uri"] as? String, "file:///a.ts")
        XCTAssertEqual(notes[1].0, "$/progress")
        XCTAssertTrue(notes[1].1.isEmpty, "missing params become an empty dictionary")
    }

    func testATransformRunsBeforeTheCallbackAndNotOnErrors() {
        var results: [Any?] = []
        client.request("x", [:], transform: { ($0 as? [Int])?.count }) { results.append($0) }
        client.request("y", [:], transform: { _ in "never" }) { results.append($0) }
        client.consume(packet(#"{"jsonrpc":"2.0","id":1,"result":[1,2,3]}"#) + packet(#"{"jsonrpc":"2.0","id":2,"error":{"code":1,"message":"m"}}"#))
        XCTAssertTrue(TestSupport.wait { results.count == 2 })
        XCTAssertEqual(results[0] as? Int, 3)
        XCTAssertNil(results[1])
    }

    func testRubbishBetweenMessagesIsSkippedOverAndNonJSONIgnored() {
        var result: Any??
        client.request("x", [:]) { result = .some($0) }
        // A body that is not an object is dropped; the framing stays in step for the next message.
        client.consume(packet("[1, 2]") + packet("not json at all") + packet(#"{"jsonrpc":"2.0","id":1,"result":"ok"}"#))
        XCTAssertTrue(TestSupport.wait { result != nil })
        XCTAssertEqual(result as? String, "ok")
    }

    func testNonASCIIBodiesAreMeasuredInBytes() {
        var result: Any??
        client.request("x", [:]) { result = .some($0) }
        client.consume(packet(#"{"jsonrpc":"2.0","id":1,"result":"größe 😀"}"#))
        XCTAssertTrue(TestSupport.wait { result != nil })
        XCTAssertEqual(result as? String, "größe 😀")
    }
}
