import Foundation
import XCTest
@testable import Feather

/// Helpers shared by the test files. Every test that touches the disk works inside a folder made here and
/// removed afterwards, so nothing is left behind and tests never see each other's files.
enum TestSupport {
    /// A fresh, empty folder under the system temporary directory. Returned standardised (`/private/tmp/…`),
    /// which matters when comparing paths Feather has standardised itself.
    static func temporaryDirectory(_ label: String = "feather-test") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    /// Writes `files` (relative path → text) under `root`, creating folders as needed.
    static func write(_ files: [String: String], under root: URL) throws {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs `git` in `directory` and returns its standard output; fails the test on a non-zero exit.
    @discardableResult
    static func git(_ arguments: [String], in directory: URL, file: StaticString = #filePath, line: UInt = #line) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.email=test@example.com", "-c", "user.name=Feather Tests",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { XCTFail("git could not start: \(error)", file: file, line: line); return "" }
        process.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0 {
            XCTFail("git \(arguments.joined(separator: " ")) failed: " + String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                    file: file, line: line)
        }
        return text
    }

    /// Runs `git` and returns its exit status; for commands that are expected to fail, such as a merge with conflicts.
    @discardableResult
    static func gitAllowingFailure(_ arguments: [String], in directory: URL) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.email=test@example.com", "-c", "user.name=Feather Tests",
                             "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A repository with one commit containing `files`.
    static func makeRepository(_ files: [String: String] = ["README.md": "# Test\n"], file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let root = temporaryDirectory("feather-repo")
        try write(files, under: root)
        git(["init", "-q"], in: root, file: file, line: line)
        git(["add", "."], in: root, file: file, line: line)
        git(["commit", "-qm", "init"], in: root, file: file, line: line)
        return root
    }

    /// Waits for `condition` to become true, pumping the main run loop, for tests of code that finishes on the
    /// main queue. Returns false on timeout.
    @discardableResult
    static func wait(upTo seconds: TimeInterval = 5, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }
}
