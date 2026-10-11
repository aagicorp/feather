/// Covers Explorer/FileIcons.swift: which logo a file gets by its name, pattern or extension, the drawn fallback
/// for everything else, and that each icon is made once and shared.
import XCTest
@testable import Feather

final class FileIconsTests: XCTestCase {
    private func image(_ name: String, isDirectory: Bool = false) -> NSImage {
        FileIcon.image(for: URL(fileURLWithPath: "/project/" + name), isDirectory: isDirectory)
    }

    func testLogosByExtension() {
        XCTAssertEqual(FileIcon.logoByExtension["ts"], "typescript")
        XCTAssertEqual(FileIcon.logoByExtension["mts"], "typescript")
        XCTAssertEqual(FileIcon.logoByExtension["tsx"], "react_ts")
        XCTAssertEqual(FileIcon.logoByExtension["jsx"], "react")
        XCTAssertEqual(FileIcon.logoByExtension["py"], "python")
        XCTAssertEqual(FileIcon.logoByExtension["kts"], "kotlin")
        XCTAssertEqual(FileIcon.logoByExtension["yml"], "yaml")
        XCTAssertEqual(FileIcon.logoByExtension["md"], "markdown")
        XCTAssertEqual(FileIcon.logoByExtension["woff2"], "font")
        XCTAssertNil(FileIcon.logoByExtension["xyz"])
    }

    func testLogosByNameWinOverExtensions() {
        XCTAssertEqual(FileIcon.logoByName["package.json"], "nodejs")
        XCTAssertEqual(FileIcon.logoByName["package-lock.json"], "npm")
        XCTAssertEqual(FileIcon.logoByName["tsconfig.json"], "tsconfig")
        XCTAssertEqual(FileIcon.logoByName["pom.xml"], "maven")
        XCTAssertEqual(FileIcon.logoByName["build.gradle.kts"], "gradle")
        XCTAssertEqual(FileIcon.logoByName["Dockerfile"], "docker")
        XCTAssertEqual(FileIcon.logoByName[".gitignore"], "git")
        XCTAssertEqual(FileIcon.logoByName["README.md"], "readme")
        XCTAssertEqual(FileIcon.logoByName["Package.swift"], "swift")
    }

    func testLogosByPattern() {
        XCTAssertEqual(FileIcon.logoByPattern("next.config.mjs"), "next")
        XCTAssertEqual(FileIcon.logoByPattern("Tailwind.config.ts"), "tailwindcss")
        XCTAssertEqual(FileIcon.logoByPattern(".eslintrc.json"), "eslint")
        XCTAssertEqual(FileIcon.logoByPattern("eslint.config.js"), "eslint")
        XCTAssertEqual(FileIcon.logoByPattern(".prettierrc"), "prettier")
        XCTAssertEqual(FileIcon.logoByPattern(".env.local"), "tune")
        XCTAssertEqual(FileIcon.logoByPattern("Dockerfile.dev"), "docker")
        XCTAssertEqual(FileIcon.logoByPattern("app.test.tsx"), "test-ts")
        XCTAssertEqual(FileIcon.logoByPattern("app.spec.js"), "test-js")
        XCTAssertNil(FileIcon.logoByPattern("app.test.py"))
        XCTAssertNil(FileIcon.logoByPattern("plain.ts"))
    }

    func testIconsAreSharedAndSixteenPoints() {
        XCTAssertTrue(image("a.ts") === image("b.TS"), "the same kind of file gets the very same image")
        XCTAssertTrue(image("weird.xyz") === image("other.unknown"), "the generic document too")
        XCTAssertFalse(image("a.ts") === image("a.py"))
        XCTAssertFalse(image("a.ts") === image("weird.xyz"))
        // Badges and logos are drawn into 16-point bitmaps; the generic document and photo are system symbols.
        for name in ["a.ts", "package.json", "application.yml", ".env", "Dockerfile.prod"] {
            XCTAssertEqual(image(name).size, NSSize(width: 16, height: 16), name)
        }
    }

    func testFilesWithoutALogoGetABadgeOrAGenericIcon() {
        // Spring's config files keep their own badge even though "yml" and "properties" have logos.
        XCTAssertFalse(image("application.yml") === image("other.yml"))
        XCTAssertTrue(image("application.yml") === image("application.yaml"))
        XCTAssertTrue(image(".env") === image(".env.production"))
        XCTAssertTrue(image("Dockerfile") === image("Dockerfile.ci"))
        XCTAssertTrue(image("photo.heic") === image("photo.bmp"), "image kinds share the photo symbol")
        XCTAssertFalse(image("photo.heic") === image("weird.xyz"))
    }

    func testFolderColoursTellTheirKind() {
        XCTAssertTrue(image("src", isDirectory: true) === image("lib", isDirectory: true))
        XCTAssertTrue(image("test", isDirectory: true) === image("__tests__", isDirectory: true))
        XCTAssertTrue(image("node_modules", isDirectory: true) === image(".build", isDirectory: true))
        XCTAssertTrue(image("assets", isDirectory: true) === image("public", isDirectory: true))
        XCTAssertFalse(image("src", isDirectory: true) === image("test", isDirectory: true))
        XCTAssertFalse(image("src", isDirectory: true) === image("node_modules", isDirectory: true))
        XCTAssertFalse(image(".github", isDirectory: true) === image("src", isDirectory: true))
        XCTAssertFalse(image("src", isDirectory: true) === image("src"), "a file called src is a file")
    }

    func testAttributedIconIsAnAttachmentAndTwoSpaces() {
        let text = FileIcon.attributed(for: URL(fileURLWithPath: "/p/a.ts"))
        XCTAssertEqual(text.length, 3)
        XCTAssertEqual(text.string.suffix(2), "  ")
        let attachment = text.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        XCTAssertTrue(attachment?.image === image("a.ts"))
        XCTAssertEqual(attachment?.bounds.size, NSSize(width: 14, height: 14))
    }
}
