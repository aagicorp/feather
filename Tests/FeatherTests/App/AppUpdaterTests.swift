/// Covers App/AppUpdater.swift: a build without a feed URL in its Info.plist (the test bundle, a development
/// build, the bare binary) never starts Sparkle, so it cannot look for updates or offer to replace itself.
import XCTest
@testable import Feather

final class AppUpdaterTests: XCTestCase {
    func testStaysInertWithoutAFeedURL() {
        XCTAssertNil(Bundle.main.infoDictionary?["SUFeedURL"], "the test bundle must not carry a feed, or this would talk to the network")
        let updater = AppUpdater.shared
        updater.start()
        updater.start()                                   // a second call changes nothing
        XCTAssertFalse(updater.isAvailable)
        XCTAssertFalse(updater.checksAutomatically)
        updater.checksAutomatically = true
        XCTAssertFalse(updater.checksAutomatically, "nothing to switch on")
        // The menu item stays enabled so the "development build" explanation can be shown.
        XCTAssertTrue(updater.validateMenuItem(NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")))
    }

    func testWhichFeedsAreTakenAndWhichOverridesAreHonoured() {
        XCTAssertTrue(AppUpdater.isAcceptableFeed("https://www.example.com/feather/appcast.xml"))
        XCTAssertTrue(AppUpdater.isAcceptableFeed("http://localhost:8765/appcast.xml"), "the update lab")
        XCTAssertFalse(AppUpdater.isAcceptableFeed("http://www.example.com/appcast.xml"), "a plain http feed on the internet is never used")
        XCTAssertFalse(AppUpdater.isAcceptableFeed(""))
        XCTAssertEqual(AppUpdater.acceptedOverride(" http://localhost:8765/appcast.xml "), "http://localhost:8765/appcast.xml")
        XCTAssertEqual(AppUpdater.acceptedOverride("http://127.0.0.1:9000/a.xml"), "http://127.0.0.1:9000/a.xml")
        XCTAssertNil(AppUpdater.acceptedOverride("https://evil.example.com/appcast.xml"), "an override cannot point a copy at another server")
        XCTAssertNil(AppUpdater.acceptedOverride(nil))
        XCTAssertNil(AppUpdater.acceptedOverride(""))
    }

    func testACriticalUpdateIsRequiredWhateverElseItIs() {
        XCTAssertEqual(AppUpdater.policy(isCritical: true, isMajor: false), .required)
        XCTAssertEqual(AppUpdater.policy(isCritical: true, isMajor: true), .required)
        XCTAssertEqual(AppUpdater.policy(isCritical: false, isMajor: true), .major)
        XCTAssertEqual(AppUpdater.policy(isCritical: false, isMajor: false), .normal)
        let text = AppUpdater.requiredUpdateText(version: "0.14.4")
        XCTAssertTrue(text.contains("0.14.4") && text.contains("needs to be installed"))
        XCTAssertNil(AppUpdater.shared.requiredUpdate, "nothing required until a feed says so")
    }
}
