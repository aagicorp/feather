import XCTest
@testable import Feather

/// Covers Terminal/AITools.swift: which assistant Start AI Assistant runs for a given setting, how a running
/// tool is recognised by its process name or title, and how installed tools are found on a PATH. The disk test
/// uses a made-up tool, never a file named after a real one.
final class AIToolsTests: XCTestCase {
    private var claude: AITool { AITools.all[0] }
    private var codex: AITool { AITools.all[1] }

    func testAutomaticTakesTheFirstInstalledInTableOrder() {
        XCTAssertEqual(AITools.choice(setting: AITools.automatic, customCommand: "", installed: [codex, claude]),
                       AITools.Choice(name: "Codex", command: "codex"))
        XCTAssertEqual(AITools.choice(setting: AITools.automatic, customCommand: "", installed: [claude, codex])?.name, "Claude Code")
        XCTAssertNil(AITools.choice(setting: AITools.automatic, customCommand: "", installed: []))
    }

    func testAChosenToolWinsWhenInstalledAndFallsBackOtherwise() {
        XCTAssertEqual(AITools.choice(setting: "codex", customCommand: "", installed: [claude, codex])?.name, "Codex")
        XCTAssertEqual(AITools.choice(setting: "gemini", customCommand: "", installed: [claude, codex])?.name, "Claude Code")
        XCTAssertNil(AITools.choice(setting: "gemini", customCommand: "", installed: []))
    }

    func testACustomCommandIsNamedAfterItsProgram() {
        let own = AITools.choice(setting: AITools.custom, customCommand: "  FOO=bar /opt/tools/aider --model x  ", installed: [])
        XCTAssertEqual(own, AITools.Choice(name: "aider", command: "FOO=bar /opt/tools/aider --model x"))
        XCTAssertEqual(AITools.choice(setting: AITools.custom, customCommand: "ollama run qwen3-coder", installed: [])?.name, "ollama")
        XCTAssertEqual(AITools.choice(setting: AITools.custom, customCommand: "./my-agent.sh", installed: [])?.name, "my-agent.sh")
        XCTAssertEqual(AITools.choice(setting: AITools.custom, customCommand: "claude --model opus", installed: [])?.name, "Claude Code")
        // Only the leading NAME=value words are skipped; a value with "=" inside an argument is left alone.
        XCTAssertEqual(AITools.choice(setting: AITools.custom, customCommand: "A=1 B=2 codex --flag=x", installed: [])?.name, "Codex")
    }

    func testAnEmptyCustomCommandMeansAutomatic() {
        XCTAssertEqual(AITools.choice(setting: AITools.custom, customCommand: "   ", installed: [codex])?.name, "Codex")
        XCTAssertNil(AITools.choice(setting: AITools.custom, customCommand: "", installed: []))
    }

    func testRecognisingARunningTool() {
        XCTAssertEqual(AITools.toolName(processName: "claude", title: ""), "Claude Code")
        XCTAssertEqual(AITools.toolName(processName: "node", title: "✳ claude code — ~/proj"), "Claude Code")
        XCTAssertEqual(AITools.toolName(processName: "zsh", title: "Codex"), "Codex")
        XCTAssertNil(AITools.toolName(processName: "node", title: "npm run dev"))
        XCTAssertNil(AITools.toolName(processName: "", title: ""))
    }

    func testInstalledLooksForExecutablesInTheGivenFolders() throws {
        let bin = TestSupport.temporaryDirectory("feather-bin")
        defer { try? FileManager.default.removeItem(at: bin) }
        let pretend = AITool(id: "pretend", name: "Pretend Assistant", executable: "feather-pretend-assistant",
                             installCommand: "n/a", website: "n/a")
        let absent = AITool(id: "absent", name: "Absent", executable: "feather-absent-assistant", installCommand: "n/a", website: "n/a")
        let script = bin.appendingPathComponent(pretend.executable)
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        // Present but not executable: not installed.
        XCTAssertEqual(AITools.installed(in: [bin.path], tools: [pretend, absent]), [])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertEqual(AITools.installed(in: ["/nonexistent-folder", bin.path], tools: [pretend, absent]), [pretend])
        XCTAssertEqual(AITools.installed(in: [], tools: [pretend]), [])
        // The real table is only ever consulted for its own names.
        XCTAssertEqual(AITools.installed(in: [bin.path]), [])
    }

    func testTheTableIsWellFormed() {
        let ids = AITools.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertFalse(ids.contains(AITools.automatic))
        XCTAssertFalse(ids.contains(AITools.custom))
        for tool in AITools.all {
            XCTAssertFalse(tool.name.isEmpty)
            XCTAssertFalse(tool.executable.contains("/"), tool.id)
            XCTAssertTrue(tool.website.hasPrefix("https://"), tool.id)
            XCTAssertFalse(tool.installCommand.isEmpty, tool.id)
        }
    }
}
