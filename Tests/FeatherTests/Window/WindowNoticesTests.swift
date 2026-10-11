/// Covers Window/WindowNotices.swift: the cards in a window's corner (one per kind, newest last, gone when
/// pressed) and the first-time hints ("Got it" remembered for good, an ignored hint back next launch, one card
/// at a time). Windows are made but never shown.
import XCTest
@testable import Feather

final class WindowNoticesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        suiteName = "feather-tests-hints-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        HintCards.defaults = defaults
        HintCards.shownThisSession = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
    }

    override func tearDown() {
        HintCards.defaults = .standard
        HintCards.shownThisSession = []
        defaults.removePersistentDomain(forName: suiteName)
        window = nil
        super.tearDown()
    }

    private func card(_ kind: String, actions: [NoticeCard.Action] = []) -> NoticeCard {
        NoticeCard(kind: kind, symbol: "play.circle", text: "Text for \(kind)", actions: actions, dismissTitle: "Dismiss")
    }

    func testCardsStackNewestLastAndOnePerKind() {
        XCTAssertEqual(WindowNotices.cards(in: window), [])
        XCTAssertEqual(WindowNotices.cards(in: nil), [])
        let first = card("a"), second = card("b"), replacement = card("a")
        WindowNotices.show(first, in: window)
        WindowNotices.show(second, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window), [first, second])
        WindowNotices.show(replacement, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window), [second, replacement])
        XCTAssertNil(first.superview)
    }

    func testRemovingTheLastCardRemovesTheStack() {
        let only = card("a")
        WindowNotices.show(only, in: window)
        let stack = only.superview
        XCTAssertNotNil(stack)
        only.remove()
        XCTAssertNil(stack?.superview)
        XCTAssertEqual(WindowNotices.cards(in: window), [])
    }

    func testButtonsRunTheirActionAndRemoveTheCard() {
        var ran: [String] = []
        let notice = card("preview", actions: [
            NoticeCard.Action(title: "Open Preview", isProminent: true) { ran.append("open") },
            NoticeCard.Action(title: "Open in Browser") { ran.append("browser") },
        ])
        var dismissed = 0
        notice.onDismiss = { dismissed += 1 }
        WindowNotices.show(notice, in: window)
        XCTAssertEqual(notice.buttonTitles, ["Open Preview", "Open in Browser", "Dismiss"])
        XCTAssertEqual(notice.text, "Text for preview")
        XCTAssertEqual(notice.kind, "preview")

        notice.press("No Such Button")
        XCTAssertEqual(WindowNotices.cards(in: window), [notice])
        notice.press("Open in Browser")
        XCTAssertEqual(ran, ["browser"])
        XCTAssertEqual(WindowNotices.cards(in: window), [], "pressing an action takes the card away")
        XCTAssertEqual(dismissed, 0, "an action is not a dismissal")

        let another = card("x")
        another.onDismiss = { dismissed += 1 }
        WindowNotices.show(another, in: window)
        another.press("Dismiss")
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(WindowNotices.cards(in: window), [])
    }

    func testAHintIsShownOnceAndGotItIsRememberedForGood() {
        XCTAssertFalse(HintCards.isDismissed(.activity))
        HintCards.showOnce(.activity, in: window)
        let cards = WindowNotices.cards(in: window)
        XCTAssertEqual(cards.map(\.kind), ["hint.activity"])
        XCTAssertEqual(cards.first?.text, HintCards.Hint.activity.text)
        XCTAssertEqual(cards.first?.buttonTitles, ["Got It"])

        cards.first?.press("Got It")
        XCTAssertTrue(HintCards.isDismissed(.activity))
        XCTAssertEqual(defaults.stringArray(forKey: "dismissedHints"), ["activity"])
        XCTAssertEqual(WindowNotices.cards(in: window), [])

        HintCards.shownThisSession = []                      // the next launch
        HintCards.showOnce(.activity, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window), [], "dismissed for good")
        XCTAssertFalse(HintCards.isDismissed(.previewBanner))
    }

    func testAnIgnoredHintComesBackNextLaunchNotThisSession() {
        HintCards.showOnce(.restrictedMode, in: window)
        WindowNotices.cards(in: window).first?.remove()      // the window closed, say
        HintCards.showOnce(.restrictedMode, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window), [], "not again this session")
        XCTAssertFalse(HintCards.isDismissed(.restrictedMode))

        HintCards.shownThisSession = []
        HintCards.showOnce(.restrictedMode, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window).map(\.kind), ["hint.restrictedMode"])
    }

    func testAHintWaitsWhileAnotherCardIsUp() {
        WindowNotices.show(card("preview"), in: window)
        HintCards.showOnce(.previewBanner, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window).map(\.kind), ["preview"])
        XCTAssertFalse(HintCards.shownThisSession.contains(.previewBanner), "its turn has not been used up")
        WindowNotices.cards(in: window).first?.remove()
        HintCards.showOnce(.previewBanner, in: window)
        XCTAssertEqual(WindowNotices.cards(in: window).map(\.kind), ["hint.previewBanner"])
    }

    func testDismissalsAccumulateWithoutDuplicates() {
        defaults.set(["activity"], forKey: "dismissedHints")
        XCTAssertTrue(HintCards.isDismissed(.activity))
        HintCards.showOnce(.previewSignIn, in: window)
        WindowNotices.cards(in: window).first?.press("Got It")
        XCTAssertEqual(defaults.stringArray(forKey: "dismissedHints"), ["activity", "previewSignIn"])
        for hint in HintCards.Hint.allCases {
            XCTAssertFalse(hint.text.isEmpty)
            XCTAssertFalse(hint.symbol.isEmpty)
        }
    }

    func testNoWindowNoCard() {
        HintCards.showOnce(.activity, in: nil)
        XCTAssertFalse(HintCards.shownThisSession.contains(.activity))
    }
}
