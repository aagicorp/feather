import AppKit
import XCTest
@testable import Feather

/// Covers Language/Language.swift: which language a file gets (by extension, by name, by the start of the
/// name, case-insensitively), which of those carry a tree-sitter grammar, how a language's rules are put
/// together, and the regex highlighter that colours languages without a grammar.
final class LanguageDetectionTests: XCTestCase {
    private func name(_ file: String) -> String? { Language.detect(for: URL(fileURLWithPath: "/p/" + file))?.name }

    func testByExtension() {
        let expected: [String: String] = [
            "a.swift": "Swift", "a.js": "JavaScript", "a.mjs": "JavaScript", "a.ts": "TypeScript", "a.tsx": "TypeScript",
            "a.py": "Python", "a.json": "JSON", "a.webmanifest": "JSON", "a.html": "HTML", "a.svg": "HTML", "a.vue": "HTML",
            "a.css": "CSS", "a.scss": "CSS", "a.c": "C/C++", "a.hpp": "C/C++", "a.mm": "C/C++", "a.go": "Go", "a.rs": "Rust",
            "a.java": "Java", "a.kt": "Kotlin", "a.gradle": "Kotlin", "a.dart": "Dart", "a.sh": "Shell", "a.zsh": "Shell",
            "a.fish": "Shell", "a.env": "Environment", "a.dockerfile": "Dockerfile", "a.gitignore": "Ignore", "a.yml": "YAML",
            "a.toml": "TOML", "a.ini": "TOML", "a.conf": "TOML", "a.properties": "Properties", "a.md": "Markdown",
            "a.rb": "Ruby", "a.podspec": "Ruby", "a.sql": "SQL", "a.php": "PHP",
        ]
        for (file, language) in expected { XCTAssertEqual(name(file), language, file) }
        XCTAssertNil(name("a.unknown"))
        XCTAssertNil(name("noextension"))
        XCTAssertNil(name("a."))
    }

    func testExtensionsAreCaseInsensitiveButNamesAreNot() {
        XCTAssertEqual(name("A.PY"), "Python")
        XCTAssertEqual(name("Main.Swift"), "Swift")
        XCTAssertEqual(name("Makefile"), "Shell")
        XCTAssertNil(name("makefile"))
        XCTAssertEqual(name("Podfile"), "Ruby")
        XCTAssertNil(name("podfile"))
    }

    func testByFileName() {
        XCTAssertEqual(name("Gemfile"), "Ruby")
        XCTAssertEqual(name("Rakefile"), "Ruby")
        XCTAssertEqual(name("Dockerfile"), "Dockerfile")
        XCTAssertEqual(name("Containerfile"), "Dockerfile")
        XCTAssertEqual(name(".zshrc"), "Shell")
        XCTAssertEqual(name(".bash_profile"), "Shell")
        XCTAssertEqual(name(".gitignore"), "Ignore")
        XCTAssertEqual(name(".prettierignore"), "Ignore")
        XCTAssertEqual(name(".env"), "Environment")
        XCTAssertEqual(name("Package.resolved"), "JSON")
        XCTAssertEqual(name("nginx.conf"), "Nginx")
    }

    func testFilesKnownByHowTheirNameStarts() {
        XCTAssertEqual(name(".env.local"), "Environment")
        XCTAssertEqual(name(".env.production.example"), "Environment")
        XCTAssertEqual(name("secrets.env"), "Environment")
        XCTAssertEqual(name("Dockerfile.dev"), "Dockerfile")
        XCTAssertEqual(name("dockerfile-base"), "Dockerfile")
        XCTAssertNil(name("Dockerfiles.txt"))
    }

    func testNginxConfIsKnownByItsFolder() {
        XCTAssertEqual(Language.detect(for: URL(fileURLWithPath: "/etc/nginx/sites-available/site.conf"))?.name, "Nginx")
        XCTAssertEqual(Language.detect(for: URL(fileURLWithPath: "/srv/app/nginx-prod.conf"))?.name, "Nginx")
        XCTAssertEqual(Language.detect(for: URL(fileURLWithPath: "/srv/app/app.conf"))?.name, "TOML")
    }

    func testGrammarsAreGivenPerExtension() {
        func grammar(_ file: String) -> TreeSitterLanguage? { Language.detect(for: URL(fileURLWithPath: "/p/" + file))?.treeSitterLanguage }
        XCTAssertEqual(grammar("a.mjs"), .javascript)
        XCTAssertEqual(grammar("a.kts"), .kotlin)
        XCTAssertEqual(grammar("a.htm"), .html)
        XCTAssertEqual(grammar("a.geojson"), .json)
        XCTAssertEqual(grammar("a.yaml"), .yaml)
        XCTAssertEqual(grammar("a.command"), .bash)
        XCTAssertEqual(grammar(".bashrc"), .bash)
        XCTAssertNil(grammar("a.gradle"))            // Kotlin's rules without its grammar
        XCTAssertNil(grammar("a.fish"))
        XCTAssertNil(grammar("a.xml"))
        XCTAssertNil(grammar("a.less"))
        XCTAssertNil(grammar("Dockerfile"))
        XCTAssertNil(grammar("a.c"))
    }
}

final class LanguageRulesTests: XCTestCase {
    private static let all: [Language] = [.swift, .javascript, .typescript, .python, .json, .html, .css, .c, .go, .rust, .java,
                                          .kotlin, .dart, .shell, .yaml, .toml, .properties, .markdown, .ruby, .sql, .php,
                                          .dotenv, .dockerfile, .nginx, .ignoreFile]

    func testEveryLanguageCompiles() {
        for language in LanguageRulesTests.all {
            XCTAssertNotNil(language.regex, language.name)
            XCTAssertFalse(language.rules.isEmpty, language.name)
        }
    }

    func testMakeOrdersTheRulesSoTheLeftmostWins() {
        let language = Language.make("Test", lineComment: "//", blockComment: ("/*", "*/"), first: [(.type, "@x")],
                                     strings: [Language.doubleQuoted], keywords: "if else", numbers: true, types: true, functions: true)
        XCTAssertEqual(language.rules.map(\.0), [.type, .comment, .comment, .string, .number, .keyword, .type, .function])
        XCTAssertEqual(language.keywordList, ["if", "else"])
        XCTAssertEqual(language.lineComment, "//")
        XCTAssertFalse(language.indentAfterColon)
        XCTAssertFalse(language.caseInsensitive)
        let bare = Language.make("Bare", strings: [], numbers: false, types: false, functions: false)
        XCTAssertTrue(bare.rules.isEmpty)
        XCTAssertTrue(bare.keywordList.isEmpty)
        XCTAssertNil(bare.lineComment)
    }

    func testLanguageTraits() {
        XCTAssertTrue(Language.python.indentAfterColon)
        XCTAssertTrue(Language.yaml.indentAfterColon)
        XCTAssertFalse(Language.swift.indentAfterColon)
        XCTAssertTrue(Language.sql.caseInsensitive)
        XCTAssertEqual(Language.python.lineComment, "#")
        XCTAssertEqual(Language.sql.lineComment, "--")
        XCTAssertNil(Language.css.lineComment)
        XCTAssertNil(Language.html.lineComment)
        XCTAssertTrue(Language.swift.keywordList.contains("guard"))
        XCTAssertTrue(Language.typescript.keywordList.contains("satisfies"))
    }

    func testTreeAssignsAGrammarWithoutTouchingTheRules() {
        let ruby = Language.ruby
        XCTAssertNil(ruby.treeSitterLanguage)
        let withTree = ruby.tree(.bash)
        XCTAssertEqual(withTree.treeSitterLanguage, .bash)
        XCTAssertEqual(withTree.rules.count, ruby.rules.count)
        XCTAssertEqual(withTree.name, ruby.name)
    }
}

final class SyntaxHighlighterTests: XCTestCase {
    private let theme = Settings.shared.theme

    private func colours(_ text: String, _ language: Language?, range: NSRange? = nil) -> (NSLayoutManager, NSString) {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        SyntaxHighlighter.highlight(storage: storage, layoutManager: layoutManager, language: language,
                                    range: range ?? NSRange(location: 0, length: storage.length), theme: theme)
        return (layoutManager, storage.mutableString)
    }

    private func kind(of needle: String, in text: NSString, _ layoutManager: NSLayoutManager) -> TokenKind? {
        let range = text.range(of: needle)
        precondition(range.location != NSNotFound)
        guard let colour = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor else { return nil }
        let table: [(TokenKind, NSColor)] = [(.comment, theme.comment), (.string, theme.string), (.number, theme.number),
                                             (.keyword, theme.keyword), (.type, theme.type), (.function, theme.function)]
        return table.first { $0.1 == colour }?.0
    }

    func testRubyIsColouredByItsRules() {
        let text = "# note\ndef total(x) # 'not a string'\n  puts \"a # b\" + :sym + @ivar + 42\nend\n"
        let (layoutManager, ns) = colours(text, .ruby)
        XCTAssertEqual(kind(of: "# note", in: ns, layoutManager), .comment)
        XCTAssertEqual(kind(of: "def", in: ns, layoutManager), .keyword)
        XCTAssertEqual(kind(of: "total", in: ns, layoutManager), .function)
        XCTAssertEqual(kind(of: "\"a # b\"", in: ns, layoutManager), .string)   // the "#" inside the string is not a comment
        XCTAssertEqual(kind(of: "# 'not", in: ns, layoutManager), .comment)     // and the quote in the comment is not a string
        XCTAssertEqual(kind(of: ":sym", in: ns, layoutManager), .type)
        XCTAssertEqual(kind(of: "@ivar", in: ns, layoutManager), .type)
        XCTAssertEqual(kind(of: "42", in: ns, layoutManager), .number)
        XCTAssertEqual(kind(of: "end", in: ns, layoutManager), .keyword)
        XCTAssertNil(kind(of: "puts", in: ns, layoutManager))
    }

    func testMarkdownAndDotenvAndSQL() {
        let (markdown, md) = colours("# Title\n> quote\n`code` **bold** [link](http://x)\n- item\n```\nfenced\n```\n", .markdown)
        XCTAssertEqual(kind(of: "# Title", in: md, markdown), .keyword)
        XCTAssertEqual(kind(of: "> quote", in: md, markdown), .comment)
        XCTAssertEqual(kind(of: "`code`", in: md, markdown), .string)
        XCTAssertEqual(kind(of: "**bold**", in: md, markdown), .type)
        XCTAssertEqual(kind(of: "[link]", in: md, markdown), .function)
        XCTAssertEqual(kind(of: "- ", in: md, markdown), .number)
        XCTAssertEqual(kind(of: "```\nfenced", in: md, markdown), .string)
        let (env, dotenv) = colours("# c\nexport API_KEY=abc${HOME}\nDEBUG=true\n", .dotenv)
        XCTAssertEqual(kind(of: "# c", in: dotenv, env), .comment)
        XCTAssertEqual(kind(of: "export API_KEY", in: dotenv, env), .keyword)
        XCTAssertEqual(kind(of: "${HOME}", in: dotenv, env), .type)
        XCTAssertEqual(kind(of: "true", in: dotenv, env), .keyword)
        let (sql, query) = colours("SELECT name FROM users WHERE id = 1; -- done\n", .sql)
        XCTAssertEqual(kind(of: "SELECT", in: query, sql), .keyword)               // case does not matter here
        XCTAssertEqual(kind(of: "FROM", in: query, sql), .keyword)
        XCTAssertEqual(kind(of: "-- done", in: query, sql), .comment)
        XCTAssertNil(kind(of: "name", in: query, sql))
    }

    func testOnlyTheAskedRangeIsColouredAndNoLanguageClearsIt() {
        let text = "x = 1\ny = 2\n"
        let (layoutManager, ns) = colours(text, .python, range: NSRange(location: 0, length: 6))
        XCTAssertEqual(kind(of: "1", in: ns, layoutManager), .number)
        XCTAssertNil(kind(of: "2", in: ns, layoutManager))
        let storage = NSTextStorage(string: text)
        let fresh = NSLayoutManager()
        storage.addLayoutManager(fresh)
        let whole = NSRange(location: 0, length: storage.length)
        SyntaxHighlighter.highlight(storage: storage, layoutManager: fresh, language: .python, range: whole, theme: theme)
        XCTAssertNotNil(fresh.temporaryAttribute(.foregroundColor, atCharacterIndex: 4, effectiveRange: nil))
        SyntaxHighlighter.highlight(storage: storage, layoutManager: fresh, language: nil, range: whole, theme: theme)
        XCTAssertNil(fresh.temporaryAttribute(.foregroundColor, atCharacterIndex: 4, effectiveRange: nil))
        SyntaxHighlighter.highlight(storage: storage, layoutManager: fresh, language: .python, range: NSRange(location: 0, length: 0), theme: theme)
    }

    func testTripleQuotedStringsRunToTheEndWhenUnclosed() {
        let (layoutManager, ns) = colours("s = \"\"\"open\n# still string\n", .python)
        XCTAssertEqual(kind(of: "# still", in: ns, layoutManager), .string)
    }
}
