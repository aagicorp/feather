import AppKit

enum TokenKind {
    case comment, string, number, keyword, type, function
}

/// A language is an ordered list of (kind, pattern) rules compiled into one alternation regex,
/// so the leftmost rule wins and e.g. "//" inside a string is never coloured as a comment.
/// Patterns must not contain capturing groups.
struct Language {
    let name: String
    let lineComment: String?
    let indentAfterColon: Bool
    let caseInsensitive: Bool
    let rules: [(TokenKind, String)]
    /// Offered as suggestions when no language server is running.
    let keywordList: [String]
    /// The grammar that colours and folds files of this language from a syntax tree; without one, `rules` do
    /// the colouring and indentation the folding. Set per extension: TypeScript and TSX share rules, not a grammar.
    var treeSitterLanguage: TreeSitterLanguage? = nil

    private static let q3 = String(repeating: "\"", count: 3)
    static let doubleQuoted = #""(?:\\.|[^"\\\n])*""#
    static let singleQuoted = #"'(?:\\.|[^'\\\n])*'"#
    static let backtick = #"`(?:\\.|[^`\\])*`"#
    static let charLiteral = #"'(?:\\.|[^'\\\n])'"#
    static let tripleDouble = q3 + #"[\s\S]*?(?:"# + q3 + #"|\z)"#
    static let tripleSingle = #"'''[\s\S]*?(?:'''|\z)"#
    private static let numberPattern = #"\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
    private static let typePattern = #"\b[A-Z][A-Za-z0-9_]*\b"#
    private static let functionPattern = #"\b[A-Za-z_][A-Za-z0-9_]*(?=\()"#

    static func make(_ name: String,
                     lineComment: String? = nil,
                     blockComment: (String, String)? = nil,
                     first: [(TokenKind, String)] = [],
                     strings: [String] = [doubleQuoted, singleQuoted],
                     keywords: String = "",
                     numbers: Bool = true,
                     types: Bool = true,
                     functions: Bool = true,
                     indentAfterColon: Bool = false,
                     caseInsensitive: Bool = false) -> Language {
        var rules = first
        if let (start, end) = blockComment {
            let s = NSRegularExpression.escapedPattern(for: start)
            let e = NSRegularExpression.escapedPattern(for: end)
            rules.append((.comment, s + #"[\s\S]*?(?:"# + e + #"|\z)"#))
        }
        if let lineComment {
            rules.append((.comment, NSRegularExpression.escapedPattern(for: lineComment) + #"[^\n]*"#))
        }
        for s in strings { rules.append((.string, s)) }
        if numbers { rules.append((.number, numberPattern)) }
        let words = keywords.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        if !words.isEmpty {
            rules.append((.keyword, #"\b(?:"# + words.joined(separator: "|") + #")\b"#))
        }
        if types { rules.append((.type, typePattern)) }
        if functions { rules.append((.function, functionPattern)) }
        return Language(name: name, lineComment: lineComment, indentAfterColon: indentAfterColon,
                        caseInsensitive: caseInsensitive, rules: rules,
                        keywordList: keywords.split(separator: " ").map(String.init))
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    var regex: NSRegularExpression? {
        if let cached = Language.regexCache[name] { return cached }
        let pattern = rules.map { "(" + $0.1 + ")" }.joined(separator: "|")
        var options: NSRegularExpression.Options = [.anchorsMatchLines]
        if caseInsensitive { options.insert(.caseInsensitive) }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        Language.regexCache[name] = compiled
        return compiled
    }

    // MARK: - Definitions

    private static let cBlock = ("/*", "*/")

    static let swift = make("Swift", lineComment: "//", blockComment: cBlock,
        strings: [tripleDouble, doubleQuoted],
        keywords: "actor any as associatedtype async await break case catch class continue convenience default defer deinit didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in indirect infix init inout internal is lazy let mutating nil nonisolated nonmutating open operator optional override postfix precedencegroup prefix private protocol public repeat required rethrows return self Self set some static struct subscript super switch throw throws true try typealias unowned var weak where while willSet")

    static let javascript = make("JavaScript", lineComment: "//", blockComment: cBlock,
        strings: [doubleQuoted, singleQuoted, backtick],
        keywords: "async await break case catch class const continue debugger default delete do else export extends false finally for from function get if import in instanceof let new null of return set static super switch this throw true try typeof undefined var void while with yield")

    static let typescript = make("TypeScript", lineComment: "//", blockComment: cBlock,
        strings: [doubleQuoted, singleQuoted, backtick],
        keywords: "abstract any as asserts async await boolean break case catch class const continue debugger declare default delete do else enum export extends false finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new null number object of private protected public readonly return satisfies set static string super switch symbol this throw true try type typeof undefined unique unknown var void while with yield")

    static let python = make("Python", lineComment: "#",
        strings: [tripleDouble, tripleSingle, doubleQuoted, singleQuoted],
        keywords: "and as assert async await break case class continue def del elif else except False finally for from global if import in is lambda match None nonlocal not or pass raise return self True try while with yield",
        indentAfterColon: true)

    static let json = make("JSON",
        first: [(.keyword, doubleQuoted + #"(?=\s*:)"#)],
        strings: [doubleQuoted],
        keywords: "true false null", types: false, functions: false)

    static let html = make("HTML",
        first: [(.comment, #"<!--[\s\S]*?(?:-->|\z)"#),
                (.keyword, #"</?[A-Za-z][A-Za-z0-9:\-]*|/?>"#),
                (.type, #"\b[A-Za-z_:][A-Za-z0-9_:\-]*(?==)"#)],
        numbers: false, types: false, functions: false)

    static let css = make("CSS", lineComment: nil, blockComment: cBlock,
        first: [(.keyword, #"@[a-z\-]+"#), (.type, #"[a-z\-]+(?=\s*:)"#), (.number, #"#[0-9a-fA-F]{3,8}\b|\b\d+(?:\.\d+)?(?:px|em|rem|vh|vw|%|s|ms|deg|fr)?"#)],
        numbers: false, types: false)

    static let c = make("C/C++", lineComment: "//", blockComment: cBlock,
        first: [(.keyword, #"^\s*#\s*[a-z]+"#)],
        strings: [doubleQuoted, charLiteral],
        keywords: "alignas alignof auto bool break case catch char class const constexpr const_cast continue decltype default delete do double dynamic_cast else enum explicit extern false float for friend goto if inline int long mutable namespace new noexcept nullptr operator private protected public register reinterpret_cast return short signed sizeof static static_assert static_cast struct switch template this throw true try typedef typeid typename union unsigned using virtual void volatile while id nil self super YES NO instancetype")

    static let go = make("Go", lineComment: "//", blockComment: cBlock,
        strings: [doubleQuoted, charLiteral, backtick],
        keywords: "break case chan const continue default defer else fallthrough false for func go goto if import interface iota map nil package range return select struct switch true type var any bool byte error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64")

    static let rust = make("Rust", lineComment: "//", blockComment: cBlock,
        strings: [doubleQuoted, charLiteral],
        keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize")

    static let java = make("Java", lineComment: "//", blockComment: cBlock,
        strings: [tripleDouble, doubleQuoted, charLiteral],
        keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends false final finally float for goto if implements import instanceof int interface long native new null package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient true try var void volatile while yield")

    static let kotlin = make("Kotlin", lineComment: "//", blockComment: cBlock,
        strings: [tripleDouble, doubleQuoted, charLiteral],
        keywords: "abstract as break by catch class companion const constructor continue crossinline data do else enum false final finally for fun get if import in init inline inner interface internal is lateinit null object open operator out override package private protected public return sealed set super suspend this throw true try typealias val var vararg when where while")

    static let dart = make("Dart", lineComment: "//", blockComment: cBlock,
        strings: [tripleDouble, tripleSingle, doubleQuoted, singleQuoted],
        keywords: "abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return sealed set show static super switch sync this throw true try typedef var void when while with yield")

    static let shell = make("Shell", lineComment: "#",
        first: [(.type, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9@#?*!$]"#)],
        keywords: "alias break case cd continue do done echo elif else esac eval exec exit export fi for function if in local read readonly return set shift source then trap unset until while",
        types: false, functions: false)

    static let yaml = make("YAML", lineComment: "#",
        first: [(.keyword, #"^\s*(?:-\s+)?[\w.\-/]+(?=\s*:(?:\s|$))"#)],
        keywords: "true false null yes no on off", types: false, functions: false,
        indentAfterColon: true)

    static let toml = make("TOML", lineComment: "#",
        first: [(.type, #"^\s*\[[^\]\n]*\]+"#), (.keyword, #"^\s*[\w.\-]+(?=\s*=)"#)],
        strings: [tripleDouble, doubleQuoted, singleQuoted],
        keywords: "true false", types: false, functions: false)

    static let properties = make("Properties", lineComment: "#",
        first: [(.comment, #"^\s*![^\n]*"#), (.keyword, #"^\s*[\w.\-\[\]]+(?=\s*[=:])"#),
                (.type, #"\$\{[^}\n]*\}"#)],
        strings: [], keywords: "true false", types: false, functions: false)

    static let markdown = make("Markdown",
        first: [(.string, #"```[\s\S]*?(?:```|\z)"#),
                (.keyword, #"^#{1,6}\s[^\n]*"#),
                (.comment, #"^>[^\n]*"#),
                (.string, #"`[^`\n]+`"#),
                (.type, #"\*\*[^*\n]+\*\*"#),
                (.function, #"\[[^\]\n]+\]\([^)\n]+\)"#),
                (.number, #"^\s*(?:[-*+]|\d+\.)\s"#)],
        strings: [], numbers: false, types: false, functions: false)

    static let ruby = make("Ruby", lineComment: "#",
        first: [(.type, #":[A-Za-z_][A-Za-z0-9_]*\b|@{1,2}[A-Za-z_][A-Za-z0-9_]*"#)],
        keywords: "alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo require require_relative rescue retry return self super then true undef unless until when while yield")

    static let sql = make("SQL", lineComment: "--", blockComment: cBlock,
        keywords: "add all alter and as asc begin between by case check column commit constraint create database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references right rollback select set table then union unique update values view when where with",
        types: false, caseInsensitive: true)

    static let php = make("PHP", lineComment: "//", blockComment: cBlock,
        first: [(.comment, #"#[^\n]*"#), (.type, #"\$[A-Za-z_][A-Za-z0-9_]*"#)],
        keywords: "abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enum extends false final finally fn for foreach function global if implements include include_once instanceof interface isset list match namespace new null or print private protected public readonly require require_once return static switch this throw trait true try unset use var while yield")

    /// .env, .env.local, .env.production.example: KEY=value lines.
    static let dotenv = make("Environment",
        first: [(.comment, #"^\s*#[^\n]*"#),
                (.keyword, #"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.]*(?=\s*=)"#),
                (.type, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#)],
        keywords: "true false null", types: false, functions: false)

    static let dockerfile = make("Dockerfile", lineComment: "#",
        first: [(.keyword, #"^\s*(?i:FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#),
                (.type, #"\$\{[^}\n]*\}|\$[A-Za-z_][A-Za-z0-9_]*"#),
                (.function, #"--[a-z][a-z\-]*(?==)"#)],
        keywords: "AS as", types: false, functions: false)

    static let nginx = make("Nginx", lineComment: "#",
        first: [(.type, #"\$[A-Za-z_][A-Za-z0-9_]*"#),
                (.keyword, #"^\s*[a-z_]+(?=[\s;{])"#)],
        keywords: "on off", types: false, functions: false)

    /// .gitignore, .dockerignore, .npmignore: patterns, comments and negations.
    /// `.http` / `.rest` request files (VS Code REST Client): `###` separators and `#` comments, the method,
    /// header names and `{{variables}}`.
    static let http = make("HTTP", lineComment: "#",
        first: [(.comment, #"^\s*//[^\n]*"#), (.keyword, #"^(?:GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\b"#),
                (.type, #"\{\{[^}\n]*\}\}|^@[A-Za-z0-9_.$-]+"#), (.function, #"^[A-Za-z0-9-]+(?=:)"#)],
        strings: [doubleQuoted], types: false, functions: false)

    static let ignoreFile = make("Ignore", first: [(.comment, #"^\s*#[^\n]*"#), (.keyword, #"^![^\n]*"#),
                                                     (.type, #"[*?]+|\[[^\]\n]*\]"#)],
        strings: [], numbers: false, types: false, functions: false)

    private static let byExtension: [String: Language] = {
        var map: [String: Language] = [:]
        func add(_ lang: Language, _ exts: String) {
            for ext in exts.split(separator: " ") { map[String(ext)] = lang }
        }
        add(swift.tree(.swift), "swift")
        add(javascript.tree(.javascript), "js jsx mjs cjs")
        add(typescript.tree(.typescript), "ts")
        add(typescript.tree(.tsx), "tsx")
        add(python.tree(.python), "py pyw")
        add(json.tree(.json), "json jsonc geojson webmanifest")
        add(html.tree(.html), "html htm")
        add(html, "xml svg plist xib storyboard vue entitlements")
        add(css.tree(.css), "css")
        add(css, "scss less")
        add(c, "c h m mm cpp cc cxx hpp hh")
        add(go.tree(.go), "go")
        add(rust.tree(.rust), "rs")
        add(java.tree(.java), "java")
        add(kotlin.tree(.kotlin), "kt kts")
        add(kotlin, "gradle")
        add(dart.tree(.dart), "dart")
        add(shell.tree(.bash), "sh bash zsh command")
        add(shell, "fish")
        add(dotenv, "env")
        add(dockerfile, "dockerfile")
        add(ignoreFile, "gitignore dockerignore npmignore eslintignore prettierignore")
        add(yaml.tree(.yaml), "yml yaml")
        add(toml, "toml ini cfg conf")
        add(properties, "properties")
        add(markdown, "md markdown")
        add(ruby, "rb podspec")
        add(sql, "sql")
        add(php, "php")
        add(http, "http rest")
        return map
    }()

    private static let byFileName: [String: Language] = [
        "Podfile": ruby, "Fastfile": ruby, "Gemfile": ruby, "Rakefile": ruby,
        "Dockerfile": dockerfile, "Containerfile": dockerfile, "Makefile": shell, "nginx.conf": nginx, ".zshrc": shell.tree(.bash), ".bashrc": shell.tree(.bash),
        ".zprofile": shell.tree(.bash), ".bash_profile": shell.tree(.bash), ".gitignore": ignoreFile, ".dockerignore": ignoreFile,
        ".npmignore": ignoreFile, ".eslintignore": ignoreFile, ".prettierignore": ignoreFile, ".env": dotenv,
        "Package.resolved": json.tree(.json),
    ]

    static func detect(for url: URL) -> Language? {
        let name = url.lastPathComponent
        if let lang = byFileName[name] { return lang }
        // Files known by how their name starts, whatever comes after: .env.production.example, Dockerfile.dev.
        if name.hasPrefix(".env.") || name.hasSuffix(".env") { return dotenv }
        if name.hasPrefix("Dockerfile.") || name.hasPrefix("dockerfile") { return dockerfile }
        if name.hasSuffix(".conf"), url.path.contains("nginx") { return nginx }
        return byExtension[url.pathExtension.lowercased()]
    }
}

enum SyntaxHighlighter {
    /// Colours `range` using temporary attributes, which never touch the text storage or undo stack.
    static func highlight(storage: NSTextStorage, layoutManager: NSLayoutManager,
                          language: Language?, range: NSRange, theme: Theme) {
        guard range.length > 0 else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        guard let language, let regex = language.regex else { return }
        let chunk = storage.mutableString.substring(with: range)
        let rules = language.rules
        regex.enumerateMatches(in: chunk, options: [], range: NSRange(location: 0, length: (chunk as NSString).length)) { match, _, _ in
            guard let match else { return }
            for index in 0..<rules.count where match.range(at: index + 1).location != NSNotFound {
                let r = match.range(at: index + 1)
                layoutManager.addTemporaryAttribute(.foregroundColor,
                                                    value: theme.color(for: rules[index].0),
                                                    forCharacterRange: NSRange(location: r.location + range.location, length: r.length))
                break
            }
        }
    }
}
