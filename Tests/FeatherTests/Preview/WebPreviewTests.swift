import XCTest
@testable import Feather

/// Covers the pure parts of Preview/WebPreview.swift: which addresses belong in the preview, turning what a
/// person types into an address, and which file changes are worth a reload. The web view itself is not tested.
final class WebPreviewAddressTests: XCTestCase {
    private func url(_ text: String) -> URL { URL(string: text)! }

    func testLocalAddressesAreThisMacByAnyName() {
        XCTAssertTrue(WebPreviewView.isLocal(url("http://localhost:3000/")))
        XCTAssertTrue(WebPreviewView.isLocal(url("https://127.0.0.1:8443/app")))
        XCTAssertTrue(WebPreviewView.isLocal(url("HTTP://LOCALHOST")))
        XCTAssertTrue(WebPreviewView.isLocal(url("http://[::1]:3000/")))
        XCTAssertTrue(WebPreviewView.isLocal(url("http://app.fthr.localhost:3000/")), "the preview's own stand-in name")
        XCTAssertTrue(WebPreviewView.isLocal(url("http://myapp.localhost/")))
        XCTAssertFalse(WebPreviewView.isLocal(url("http://example.com/")))
        XCTAssertFalse(WebPreviewView.isLocal(url("http://localhost.example.com/")))
        XCTAssertFalse(WebPreviewView.isLocal(url("ftp://localhost/")))
        XCTAssertFalse(WebPreviewView.isLocal(URL(fileURLWithPath: "/tmp/index.html")))
        XCTAssertFalse(WebPreviewView.isLocal(WebPreviewView.blank))
    }

    func testTypedAddresses() {
        XCTAssertEqual(WebPreviewView.url(fromTyped: "3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(WebPreviewView.url(fromTyped: ":8080")?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(WebPreviewView.url(fromTyped: "localhost:3000/app")?.absoluteString, "http://localhost:3000/app")
        XCTAssertEqual(WebPreviewView.url(fromTyped: "  https://example.com/x \n")?.absoluteString, "https://example.com/x")
        XCTAssertEqual(WebPreviewView.url(fromTyped: "example.com")?.absoluteString, "http://example.com")
        XCTAssertEqual(WebPreviewView.url(fromTyped: "0.0.0.0:8080/api")?.absoluteString, "http://localhost:8080/api")
        XCTAssertNil(WebPreviewView.url(fromTyped: ""))
        XCTAssertNil(WebPreviewView.url(fromTyped: "   "))
    }

    func testEveryInterfaceMeansLocalhost() {
        XCTAssertEqual(WebPreviewView.replacingAnyAddress(in: url("http://0.0.0.0:5173/a?b=1")).absoluteString, "http://localhost:5173/a?b=1")
        XCTAssertEqual(WebPreviewView.replacingAnyAddress(in: url("http://127.0.0.1:5173/")).absoluteString, "http://127.0.0.1:5173/")
    }

    func testShortNames() {
        XCTAssertEqual(WebPreviewView.shortName(of: url("http://localhost:3000/deep/path")), "localhost:3000")
        XCTAssertEqual(WebPreviewView.shortName(of: url("https://example.com/")), "example.com")
    }

    func testWhichChangesAreWorthAReload() {
        let folder = URL(fileURLWithPath: "/tmp/site")
        XCTAssertTrue(WebPreviewView.isWorthReloading(for: "/tmp/site/index.html", in: folder))
        XCTAssertTrue(WebPreviewView.isWorthReloading(for: "src/app.js", in: folder))
        XCTAssertFalse(WebPreviewView.isWorthReloading(for: "/tmp/site/node_modules/x/index.js", in: folder))
        XCTAssertFalse(WebPreviewView.isWorthReloading(for: "/tmp/site/.git/index", in: folder))
        XCTAssertFalse(WebPreviewView.isWorthReloading(for: "dist/.cache/a.js", in: folder))
        // Only the part inside the folder counts: a hidden folder above it is the user's business.
        XCTAssertTrue(WebPreviewView.isWorthReloading(for: "/Users/.hidden/site/a.html", in: URL(fileURLWithPath: "/Users/.hidden/site")))
    }
}

/// Covers Preview/MediaPreview.swift: which files open in the media viewer, by extension alone.
final class MediaPreviewKindTests: XCTestCase {
    private func kind(_ name: String) -> MediaPreviewView.Kind? { MediaPreviewView.kind(of: URL(fileURLWithPath: "/x/" + name)) }

    func testPicturesByExtensionInAnyCase() {
        for name in ["a.png", "b.JPG", "c.jpeg", "d.gif", "e.webp", "f.heic", "g.tiff", "h.ico", "i.icns", "j.bmp"] {
            XCTAssertEqual(kind(name), .image, name)
        }
    }

    func testVectorsAndDocuments() {
        XCTAssertEqual(kind("logo.svg"), .svg)
        XCTAssertEqual(kind("paper.PDF"), .pdf)
    }

    func testSoundAndVideo() {
        for name in ["a.mp4", "b.mov", "c.m4v", "d.mp3", "e.wav", "f.m4a", "g.aac", "h.aiff", "i.flac"] {
            XCTAssertEqual(kind(name), .player, name)
        }
    }

    func testEverythingElseIsText() {
        for name in ["a.txt", "b.swift", "Makefile", "c.tar.gz", "d.psd", "e.mkv", "png"] {
            XCTAssertNil(kind(name), name)
        }
    }
}
