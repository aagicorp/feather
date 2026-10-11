/// The redesigned request screen: the section tabs and their pills, bulk editing of name/value lists, the status
/// pill and hidden header of the answer, the method pill's one width, and the history's day labels.
import XCTest
@testable import Feather

final class APIRedesignTests: XCTestCase {
    func testTheTabStripShowsCountsAndKinds() {
        var request = APIRequest(name: "r", url: "http://h/x")
        var items = APIRequestView.sectionItems(for: request)
        XCTAssertEqual(items.map(\.title), ["Params", "Headers", "Body", "Auth", "Checks", "Variables"])
        XCTAssertEqual(items.map(\.badge), [nil, nil, nil, nil, nil, nil], "a bare request has nothing to count")
        request.params = [APIKeyValue("page", "1"), APIKeyValue("", "")]
        request.headers = [APIKeyValue("Accept", "a"), APIKeyValue("X", "b")]
        request.body.kind = .raw
        request.body.contentType = "application/json"
        request.auth.kind = .bearer
        request.checks = [APICheck.status(200)]
        items = APIRequestView.sectionItems(for: request)
        XCTAssertEqual(items.map(\.badge), ["1", "2", "JSON", "Bearer", "1", nil], "a row without a name is not counted")
        request.body.kind = .form
        request.auth.kind = .apiKey
        XCTAssertEqual(APIRequestView.sectionItems(for: request)[2].badge, "Form")
        XCTAssertEqual(APIRequestView.sectionItems(for: request)[3].badge, "Key")

        let strip = APITabStrip()
        strip.items = items
        XCTAssertEqual(strip.buttons.count, 6)
        XCTAssertTrue(strip.buttons[0].isOn)
        var chosen: [Int] = []
        strip.onSelect = { chosen.append($0) }
        strip.buttons[2].performClick(nil)
        XCTAssertEqual(chosen, [2])
        XCTAssertEqual(strip.selectedIndex, 2)
        XCTAssertTrue(strip.buttons[2].isOn && !strip.buttons[0].isOn)
        XCTAssertGreaterThan(strip.buttons[2].intrinsicContentSize.width, strip.buttons[3].intrinsicContentSize.width - 20, "a pill makes room for itself")
        XCTAssertTrue(strip.trailingButton.isHidden, "no text action until one is given")
    }

    func testBulkTextRoundTrips() {
        let rows = [APIKeyValue("page", "2"), APIKeyValue("debug", "true", enabled: false), APIKeyValue("q", "a: b")]
        let text = APIEditableTable.bulkText(rows)
        XCTAssertEqual(text, "page: 2\n// debug: true\nq: a: b")
        let back = APIEditableTable.parseBulk(text, previous: rows)
        XCTAssertEqual(back.map(\.name), ["page", "debug", "q"])
        XCTAssertEqual(back.map(\.value), ["2", "true", "a: b"], "only the first colon separates")
        XCTAssertEqual(back.map(\.enabled), [true, false, true])
        XCTAssertEqual(back.map(\.id), rows.map(\.id), "rows keep their identity by name")
        // Edits: a new row, an = separator, # for off, blank lines, a row removed.
        let edited = APIEditableTable.parseBulk("page=3\n\n# limit: 10\nflag\n", previous: rows)
        XCTAssertEqual(edited.map(\.name), ["page", "limit", "flag"])
        XCTAssertEqual(edited.map(\.value), ["3", "10", ""])
        XCTAssertEqual(edited.map(\.enabled), [true, false, true])
        XCTAssertEqual(edited[0].id, rows[0].id)
        XCTAssertNotEqual(edited[1].id, rows[1].id)
        XCTAssertTrue(APIEditableTable.bulkText([APIKeyValue("", "")]).isEmpty, "an empty row writes nothing")
    }

    func testTheTableOffersAPromptAndADeleteColumn() {
        var rows = [APIKeyValue("a", "1")]
        let table = APIEditableTable(columns: [
            .init(id: "name", title: "Name", width: nil, cell: { .text(rows[$0].name, placeholder: "name") }, set: { rows[$0].name = $1 }),
            .init(id: "value", title: "Value", width: nil, cell: { .text(rows[$0].value, placeholder: "value") }, set: { rows[$0].value = $1 }),
        ])
        table.count = { rows.count }
        table.addPrompt = "Add parameter"
        table.blankRow = { _ in .text("", placeholder: "x") }
        table.onRemove = { rows.remove(at: $0) }
        table.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        table.reload()
        XCTAssertEqual(table.table.numberOfRows, 2, "the real row and the blank one")
        XCTAssertEqual(table.table.tableColumns.last?.identifier.rawValue, APIEditableTable.deleteColumnID)
        let blank = table.tableView(table.table, viewFor: table.table.tableColumns[0], row: 1) as? NSTextField
        XCTAssertEqual(blank?.placeholderString, "Add parameter")
        let real = table.tableView(table.table, viewFor: table.table.tableColumns[0], row: 0) as? NSTextField
        XCTAssertEqual(real?.placeholderString, "name")
        XCTAssertNil(table.table.view(atColumn: 2, row: 1, makeIfNecessary: true), "the blank row has nothing to delete")
        let cross = table.table.view(atColumn: 2, row: 0, makeIfNecessary: true) as? NSButton
        XCTAssertNotNil(cross)
        XCTAssertTrue(cross?.isHidden ?? false, "the ✕ waits for the pointer")
        cross?.performClick(nil)
        XCTAssertTrue(rows.isEmpty, "✕ removes the row")
        // Bulk editing swaps the table for text and applies the text on the way back.
        var applied: [APIKeyValue]?
        table.bulkRows = { rows }
        table.onBulkApply = { applied = $0; rows = $0 }
        XCTAssertTrue(table.canBulkEdit)
        table.setBulkEditing(true)
        XCTAssertTrue(table.isBulkEditing)
        table.setBulkEditing(false)
        XCTAssertNil(applied, "nothing typed, nothing applied")
        // With no rows at all, only the blank row is there and it still says what to type.
        table.reload()
        XCTAssertEqual(table.table.numberOfRows, 1)
        let onlyBlank = table.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTextField
        XCTAssertEqual(onlyBlank?.placeholderString, "Add parameter")
        XCTAssertEqual((table.table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTextField)?.placeholderString, "x")
    }

    func testTheAnswerHeaderWaitsForAnAnswer() {
        let view = APIResponseView()
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        XCTAssertTrue(view.isHeaderHiddenForTests, "nothing sent: the empty state speaks alone")
        view.showSending()
        XCTAssertFalse(view.isHeaderHiddenForTests)
        let theme = Settings.shared.theme
        let ok = APIResponse(status: 200, statusText: "OK", headers: [(name: "Content-Type", value: "application/json"), (name: "X-A", value: "1")],
                             body: Data(#"{"a":1}"#.utf8), bodyFile: nil, duration: 0.124, size: 7, url: nil, cookies: [])
        view.show(.success(ok), checks: [])
        XCTAssertFalse(view.isHeaderHiddenForTests)
        XCTAssertEqual(view.statusTextForTests, "200 OK")
        XCTAssertEqual(view.statusColorForTests, APIFormat.statusColor(200, theme: theme))
        XCTAssertEqual(view.tabLabelsForTests, ["Body", "Headers 2", "Cookies", "Checks"])
        let missing = APIResponse(status: 404, statusText: "Not Found", headers: [], body: Data(), bodyFile: nil, duration: 0.01, size: 0, url: nil, cookies: [])
        view.show(.success(missing), checks: [])
        XCTAssertEqual(view.statusTextForTests, "404 Not Found")
        XCTAssertEqual(view.statusColorForTests, APIFormat.statusColor(404, theme: theme))
        view.show(.failure(.init(message: "Could not connect")), checks: [])
        XCTAssertFalse(view.isHeaderHiddenForTests)
        XCTAssertEqual(view.statusTextForTests, "No answer")
        XCTAssertEqual(view.statusColorForTests, APIFormat.statusColor(nil, theme: theme))
    }

    func testThePillAndTheMethodBadgeHaveOneWidth() {
        let pill = APIPill()
        XCTAssertEqual(pill.intrinsicContentSize.width, 0)
        pill.text = "200 OK"
        XCTAssertGreaterThan(pill.intrinsicContentSize.width, 40)
        let theme = Theme.builtIns[0]
        let widths = Set(APIMethod.allCases.map { APIFormat.methodBadge($0, theme: theme).size.width })
        XCTAssertEqual(widths, [APIFormat.badgeWidth], "every method's pill is as wide as the widest, so names line up")
    }

    func testHistoryDaysAreToldApart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15))!
        XCTAssertEqual(APIPaneViewController.dayLabel(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(APIPaneViewController.dayLabel(for: now.addingTimeInterval(-14 * 3600), now: now, calendar: calendar), "Today", "earlier the same day")
        XCTAssertEqual(APIPaneViewController.dayLabel(for: now.addingTimeInterval(-24 * 3600), now: now, calendar: calendar), "Yesterday")
        let older = APIPaneViewController.dayLabel(for: now.addingTimeInterval(-3 * 24 * 3600), now: now, calendar: calendar)
        XCTAssertTrue(older.contains("2026") || older.contains("8"), older)
        XCTAssertNotEqual(older, "Yesterday")
    }
}
