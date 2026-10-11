/// Extensions.swift: the Extensions window shows the coming-soon card and one switch per built-in extension,
/// and the Requests pane is on by default.
import XCTest
@testable import Feather

final class ExtensionsWindowTests: XCTestCase {
    func testTheWindowShowsWhatIsComingAndWhatIsBuiltIn() {
        let controller = ExtensionsWindowController()
        XCTAssertNotNil(controller.comingSoonForTests, "the coming-soon card is there")
        XCTAssertEqual(Set(controller.switchesForTests.keys), Set(ExtensionRegistry.shared.available.map { $0.id }))
        XCTAssertEqual(controller.window?.title, "Extensions")
    }

    func testTheRequestsPaneIsOnUnlessSwitchedOff() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: "enabledExtensions")
        defer { if let saved { defaults.set(saved, forKey: "enabledExtensions") } else { defaults.removeObject(forKey: "enabledExtensions") } }
        defaults.removeObject(forKey: "enabledExtensions")
        XCTAssertTrue(ExtensionRegistry.shared.isEnabled(APIClientExtension.self))
        defaults.set([String](), forKey: "enabledExtensions")
        XCTAssertFalse(ExtensionRegistry.shared.isEnabled(APIClientExtension.self), "switched off stays off")
    }
}
