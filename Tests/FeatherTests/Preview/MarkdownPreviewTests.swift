import XCTest
import AppKit
@testable import Feather

/// Covers Preview/MarkdownPreview.swift: the block parsing of the renderer (headings, lists, code fences,
/// tables, block quotes, rules, images) and the inline styling inside a block, read off the attributed string
/// it produces. The view that shows it is not tested.
final class MarkdownRendererTests: XCTestCase {
    private let theme = Theme.builtIns[0]
    private let fonts = MarkdownRenderer.Fonts(size: 13)

    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownRenderer.render(markdown, baseURL: nil, theme: theme, fonts: fonts)
    }

    /// The rendered paragraphs, one per line of output.
    private func paragraphs(_ markdown: String) -> [String] {
        let text = render(markdown).string
        return text.isEmpty ? [] : text.dropLast().components(separatedBy: "\n")
    }

    private func font(_ rendered: NSAttributedString, at location: Int) -> NSFont? {
        rendered.attribute(.font, at: location, effectiveRange: nil) as? NSFont
    }

    private func isBold(_ font: NSFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(.bold) == true }
    private func isItalic(_ font: NSFont?) -> Bool { font?.fontDescriptor.symbolicTraits.contains(.italic) == true }

    func testEmptyAndBlankInput() {
        XCTAssertEqual(render("").length, 0)
        XCTAssertEqual(render("\n\n  \n").length, 0)
    }

    func testParagraphsJoinTheirLinesAndSplitOnBlankLines() {
        XCTAssertEqual(paragraphs("first line\nstill first\n\nsecond"), ["first line still first", "second"])
        XCTAssertEqual(paragraphs("a\r\nb\r\n\r\nc"), ["a b", "c"])
    }

    func testHeadingsGetTheirSizeAndTheBigOnesARule() {
        let lines = paragraphs("# Title\ntext\n## Sub ##\n### Third")
        XCTAssertEqual(lines[0], "Title")
        XCTAssertTrue(lines[1].allSatisfy { $0 == "─" })
        XCTAssertEqual(lines[2], "text")
        XCTAssertEqual(lines[3], "Sub")
        XCTAssertTrue(lines[4].allSatisfy { $0 == "─" })
        XCTAssertEqual(lines[5], "Third")
        XCTAssertEqual(lines.count, 6, "a level-3 heading has no rule")
        let rendered = render("# Title\n### Third\n###### Six")
        XCTAssertEqual(font(rendered, at: 0)?.pointSize, 26)
        XCTAssertTrue(isBold(font(rendered, at: 0)))
        let third = rendered.string.range(of: "Third").map { NSRange($0, in: rendered.string) }?.location ?? 0
        XCTAssertEqual(font(rendered, at: third)?.pointSize ?? 0, 13 * 1.3, accuracy: 0.01)
        let six = rendered.string.range(of: "Six").map { NSRange($0, in: rendered.string) }?.location ?? 0
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: six, effectiveRange: nil) as? NSColor, theme.lineNumber)
    }

    func testAHashWithoutASpaceIsNotAHeading() {
        XCTAssertEqual(paragraphs("#hashtag and #another"), ["#hashtag and #another"])
        XCTAssertEqual(paragraphs("####### seven"), ["####### seven"])
    }

    func testFencedCodeKeepsItsLinesLiterally() {
        let rendered = render("```swift\nlet **x** = 1\n    indented\n```\nafter")
        let parts = rendered.string.components(separatedBy: "\n")
        XCTAssertEqual(parts[0], "let **x** = 1\u{2028}    indented")
        XCTAssertEqual(parts[1], "after")
        XCTAssertEqual(font(rendered, at: 0), fonts.mono)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        // A tilde fence works too, and an unclosed fence runs to the end of the document.
        XCTAssertEqual(paragraphs("~~~\ncode\n~~~"), ["code"])
        XCTAssertEqual(paragraphs("```\none\ntwo"), ["one\u{2028}two"])
    }

    func testListsWithMarkersTasksNestingAndContinuationLines() {
        let lines = paragraphs("- one\n  continues\n* two\n+ three\n1. first\n2) second\n- [ ] todo\n- [x] done\n  - nested")
        XCTAssertEqual(lines, ["•\tone continues", "•\ttwo", "•\tthree", "1.\tfirst", "2)\tsecond", "☐\ttodo", "☑\tdone", "•\tnested"])
        let rendered = render("- top\n  - nested\n\t- tabbed")
        let styles = rendered.string.components(separatedBy: "\n").dropLast().enumerated().map { index, _ -> CGFloat in
            let location = rendered.string.components(separatedBy: "\n").prefix(index).map { $0.utf16.count + 1 }.reduce(0, +)
            return (rendered.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.firstLineHeadIndent ?? -1
        }
        XCTAssertEqual(styles, [8, 28, 48])
    }

    func testAListEndsAtAHeadingFenceOrQuote() {
        XCTAssertEqual(paragraphs("- item\n# Head").prefix(2), ["•\titem", "Head"])
        XCTAssertEqual(paragraphs("- item\n> quote"), ["•\titem", "▎ quote"])
        XCTAssertEqual(paragraphs("- item\n```\nc\n```"), ["•\titem", "c"])
    }

    func testANumberThatIsNotAListStaysText() {
        XCTAssertEqual(paragraphs("2024 was a year"), ["2024 was a year"])
        XCTAssertEqual(paragraphs("-not a bullet"), ["-not a bullet"])
    }

    func testTablesArePaddedIntoColumnsWithABoldHeader() {
        let rendered = render("| Name | Qty |\n|---|---:|\n| apple | 3 |\n| kiwi | 12 |")
        let rows = rendered.string.components(separatedBy: "\n").dropLast()
        XCTAssertEqual(Array(rows), ["Name    Qty", "apple   3  ", "kiwi    12 "])
        XCTAssertEqual(font(rendered, at: 0), fonts.monoBold)
        XCTAssertEqual(font(rendered, at: "Name    Qty\n".utf16.count), fonts.mono)
        // A pipe line without a separator under it is a paragraph.
        XCTAssertEqual(paragraphs("| a | b |\nplain"), ["| a | b | plain"])
    }

    func testARaggedTableStillLinesUp() {
        XCTAssertEqual(paragraphs("| a | b | c |\n|--|--|--|\n| 1 |"), ["a   b   c", "1        "])
    }

    func testBlockQuotesJoinTheirLines() {
        let rendered = render("> first\n> second\n\nafter")
        XCTAssertEqual(rendered.string.components(separatedBy: "\n")[0], "▎ first second")
        let quoteText = "▎ ".utf16.count
        XCTAssertEqual(rendered.attribute(.foregroundColor, at: quoteText, effectiveRange: nil) as? NSColor, theme.lineNumber)
        XCTAssertEqual(paragraphs(">no space"), ["▎ no space"])
    }

    func testHorizontalRules() {
        for rule in ["---", "* * *", "___", "-----"] {
            let lines = paragraphs("a\n\(rule)\nb")
            XCTAssertEqual(lines.count, 3, rule)
            XCTAssertTrue(lines[1].allSatisfy { $0 == "─" }, rule)
        }
        XCTAssertEqual(paragraphs("--"), ["--"])
    }

    func testInlineStyles() {
        let rendered = render("plain **bold** *it* ***both*** `code` [link](https://example.com) ~~gone~~")
        let text = rendered.string
        func at(_ word: String) -> Int { NSRange(text.range(of: word)!, in: text).location }
        XCTAssertEqual(text, "plain bold it both code link gone\n")
        XCTAssertFalse(isBold(font(rendered, at: at("plain"))))
        XCTAssertTrue(isBold(font(rendered, at: at("bold"))))
        XCTAssertFalse(isItalic(font(rendered, at: at("bold"))))
        XCTAssertTrue(isItalic(font(rendered, at: at("it"))))
        XCTAssertTrue(isBold(font(rendered, at: at("both"))) && isItalic(font(rendered, at: at("both"))))
        XCTAssertEqual(font(rendered, at: at("code")), fonts.body.code)
        XCTAssertNotNil(rendered.attribute(.backgroundColor, at: at("code"), effectiveRange: nil))
        XCTAssertEqual((rendered.attribute(.link, at: at("link"), effectiveRange: nil) as? URL)?.absoluteString, "https://example.com")
        XCTAssertNotNil(rendered.attribute(.underlineStyle, at: at("link"), effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.strikethroughStyle, at: at("gone"), effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    func testInlineStylesInsideHeadingsAndListItems() {
        let rendered = render("## A **strong** title\n- item with `code`")
        let text = rendered.string
        let strong = NSRange(text.range(of: "strong")!, in: text).location
        XCTAssertTrue(isBold(font(rendered, at: strong)))
        XCTAssertEqual(font(rendered, at: strong)?.pointSize ?? 0, 13 * 1.6, accuracy: 0.01)
        let code = NSRange(text.range(of: "code")!, in: text).location
        XCTAssertEqual(font(rendered, at: code), fonts.body.code)
    }

    func testImagesOnTheirOwnLine() throws {
        // No picture on disk: the alt text stands in, and nothing is ever fetched from the web.
        XCTAssertEqual(paragraphs("![A chart](chart.png)"), ["🖼 A chart"])
        XCTAssertEqual(paragraphs("![](https://example.com/x.png)"), ["🖼 https://example.com/x.png"])
        let folder = TestSupport.temporaryDirectory("feather-md")
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSImage(size: NSSize(width: 4, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 2).fill(); image.unlockFocus()
        let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: folder.appendingPathComponent("pic.png"))
        let rendered = MarkdownRenderer.render("![alt](pic.png \"title\")", baseURL: folder, theme: theme, fonts: fonts)
        XCTAssertNotNil(rendered.attribute(.attachment, at: 0, effectiveRange: nil))
    }

    func testNonASCIIText() {
        XCTAssertEqual(paragraphs("# Überschrift\n\n- 日本語 **太字**\n\n> „Zitat“ – ✓"), ["Überschrift", String(repeating: "─", count: 60), "•\t日本語 太字", "▎ „Zitat“ – ✓"])
    }
}
