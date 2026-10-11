import XCTest
@testable import Feather

/// Covers LanguageServer/LanguageServerStore.swift: the catalogue of servers Feather can fetch (every entry
/// consistent with the server table), and how an installed copy is found under the store's folder, tried on a
/// temporary folder so the real Application Support is never touched. Installing is not tested: it downloads.
final class ManagedServerCatalogueTests: XCTestCase {
    func testIdsAreUniqueFolderNames() {
        let ids = ManagedServer.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertFalse(id.contains("/"), id)
            XCTAssertFalse(id.hasPrefix("."), id)
        }
    }

    func testEveryEntryNamesAServerTableEntryAndItsExecutables() {
        let configs = Dictionary(uniqueKeysWithValues: LSPServerConfig.all.map { ($0.name, $0) })
        for server in ManagedServer.all {
            XCTAssertFalse(server.language.isEmpty, server.id)
            XCTAssertFalse(server.serverName.isEmpty, server.id)
            XCTAssertFalse(server.executables.isEmpty, server.id)
            XCTAssertFalse(server.configNames.isEmpty, server.id)
            for name in server.configNames {
                let config = configs[name]
                XCTAssertNotNil(config, "\(server.id) names the unknown server table entry \(name)")
                // The table must ask for at least one of the executables this entry provides, or installing it changes nothing.
                // xcrun-started servers are named in the arguments ("/usr/bin/xcrun sourcekit-lsp").
                let asked = config?.commands.flatMap { [($0.executable as NSString).lastPathComponent] + $0.arguments } ?? []
                XCTAssertFalse(Set(asked).isDisjoint(with: server.executables), "\(server.id): \(name) never runs \(server.executables)")
            }
            if !server.isExternal { XCTAssertFalse(server.sizeHint.isEmpty, "\(server.id) should say how big it is") }
        }
    }

    func testNoTwoEntriesProvideTheSameExecutable() {
        var providers: [String: String] = [:]
        for server in ManagedServer.all {
            for executable in server.executables {
                XCTAssertNil(providers[executable], "\(executable) is provided by both \(providers[executable] ?? "") and \(server.id)")
                providers[executable] = server.id
            }
        }
    }

    func testSourcesAreWellFormed() {
        for server in ManagedServer.all {
            switch server.source {
            case .npm(let packages):
                XCTAssertFalse(packages.isEmpty, server.id)
                XCTAssertFalse(server.isExternal)
            case .github(let release):
                XCTAssertEqual(release.repository.split(separator: "/").count, 2, server.id)
                XCTAssertFalse(release.armAsset.isEmpty, server.id)
                XCTAssertFalse(release.intelAsset.isEmpty, server.id)
                XCTAssertFalse(release.binary.isEmpty, server.id)
                XCTAssertFalse(release.asset.isEmpty)
            case .external(let origin):
                XCTAssertTrue(server.isExternal)
                XCTAssertFalse(origin.isEmpty, server.id)
            case .xcode:
                XCTAssertTrue(server.isExternal)
            case .jdtls, .rustAnalyzer, .gopls:
                XCTAssertFalse(server.isExternal)
            }
        }
    }
}

final class LanguageServerStoreLookupTests: XCTestCase {
    private var savedBase: URL!
    private var base: URL!

    override func setUp() {
        savedBase = LanguageServerStore.baseDirectory
        base = TestSupport.temporaryDirectory("feather-servers")
        LanguageServerStore.baseDirectory = base
    }

    override func tearDown() {
        LanguageServerStore.baseDirectory = savedBase
        try? FileManager.default.removeItem(at: base)
    }

    private func install(_ relativePath: String, executable: Bool = true) throws -> URL {
        let file = base.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
        return file
    }

    func testNothingInstalledMeansNothingFound() {
        XCTAssertNil(LanguageServerStore.executable(named: "typescript-language-server"))
        XCTAssertNil(LanguageServerStore.executable(named: "no-such-server"))
    }

    func testAnNpmServerLivesInItsNodeModulesBin() throws {
        let file = try install("typescript/node_modules/.bin/typescript-language-server")
        XCTAssertEqual(LanguageServerStore.executable(named: "typescript-language-server"), file.path)
        XCTAssertTrue(LanguageServerStore.isManaged(file.path))
        XCTAssertFalse(LanguageServerStore.isManaged("/usr/local/bin/typescript-language-server"))
        XCTAssertFalse(LanguageServerStore.isManaged(base.path + "-other/x"))
    }

    func testOneNpmPackageProvidesSeveralServers() throws {
        let css = try install("web/node_modules/.bin/vscode-css-language-server")
        XCTAssertEqual(LanguageServerStore.executable(named: "vscode-css-language-server"), css.path)
        XCTAssertNil(LanguageServerStore.executable(named: "vscode-html-language-server"), "the same package, but that file is not there")
    }

    func testDownloadedServersUseTheReleaseLayout() throws {
        let kotlin = try install("kotlin/server/bin/kotlin-language-server")
        XCTAssertEqual(LanguageServerStore.executable(named: "kotlin-language-server"), kotlin.path)
        let jdtls = try install("jdtls/bin/jdtls")
        XCTAssertEqual(LanguageServerStore.executable(named: "jdtls"), jdtls.path)
        let rust = try install("rust-analyzer/rust-analyzer")
        XCTAssertEqual(LanguageServerStore.executable(named: "rust-analyzer"), rust.path)
        let gopls = try install("gopls/gopls")
        XCTAssertEqual(LanguageServerStore.executable(named: "gopls"), gopls.path)
    }

    func testAFileWithoutTheExecutableBitDoesNotCount() throws {
        _ = try install("toml/taplo", executable: false)
        XCTAssertNil(LanguageServerStore.executable(named: "taplo"))
    }

    func testExternalServersAreNeverLookedForInTheStore() throws {
        _ = try install("dart/dart")
        _ = try install("swift/sourcekit-lsp")
        XCTAssertNil(LanguageServerStore.executable(named: "dart"))
        XCTAssertNil(LanguageServerStore.executable(named: "sourcekit-lsp"))
    }

    func testStatusBeforeTheMachineHasBeenProbed() throws {
        let store = LanguageServerStore()
        let toml = try XCTUnwrap(ManagedServer.all.first { $0.id == "toml" })
        // Nothing on the PATH in tests, nothing in the store: the answer is "not yet known".
        if case .needs(let text) = store.status(of: toml) { XCTAssertEqual(text, "Checking…") } else { XCTFail("expected .needs") }
        XCTAssertFalse(store.canInstall(toml))
        XCTAssertFalse(store.isBusy(toml))
        // Once a copy is in the store it is reported with its version file.
        _ = try install("toml/taplo")
        if case .managed(let version) = store.status(of: toml) { XCTAssertNil(version) } else { XCTFail("expected .managed") }
        try "0.9.3\n".write(to: base.appendingPathComponent("toml/.feather-version"), atomically: true, encoding: .utf8)
        if case .managed(let version) = store.status(of: toml) { XCTAssertEqual(version, "0.9.3") } else { XCTFail("expected .managed") }
        XCTAssertTrue(store.missingServers.isEmpty, "nothing can be installed before the probe")
    }

    func testEnvironmentIsOnlyChangedForManagedServers() {
        let store = LanguageServerStore()
        let base = ["PATH": "/usr/bin", "HOME": "/Users/me"]
        XCTAssertEqual(store.environment(for: "/usr/local/bin/pyright-langserver", base: base), base)
        let managed = store.environment(for: LanguageServerStore.baseDirectory.appendingPathComponent("pyright/node_modules/.bin/pyright-langserver").path, base: base)
        XCTAssertEqual(managed["HOME"], "/Users/me")
        XCTAssertTrue(managed["PATH"]?.hasSuffix("/usr/bin") == true)
    }
}
