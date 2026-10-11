import AppKit

/// Turns Markdown into styled text for the preview. It is a native renderer rather than a web view, which keeps
/// the preview as light as the rest of the editor. Blocks are parsed here; the inline syntax inside each block
/// (bold, italic, code, links, strikethrough) is parsed by Foundation.
enum MarkdownRenderer {
    private static let imageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    /// The preview re-renders about five times a second while you type; its pictures should not be re-read each time.
    private static func cachedImage(at url: URL) -> NSImage? {
        if let cached = imageCache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Every font the renderer can need, in its regular, bold, italic and bold-italic forms. It is built on the
    /// main thread (NSFontManager is not safe to use elsewhere) so that rendering can run in the background.
    struct Fonts {
        struct Family {
            let regular: NSFont, bold: NSFont, italic: NSFont, boldItalic: NSFont, code: NSFont

            init(_ base: NSFont) {
                let manager = NSFontManager.shared
                regular = base
                bold = manager.convert(base, toHaveTrait: .boldFontMask)
                italic = manager.convert(base, toHaveTrait: .italicFontMask)
                boldItalic = manager.convert(base, toHaveTrait: [.boldFontMask, .italicFontMask])
                code = .monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular)
            }
        }
        let size: CGFloat
        let body: Family
        let headings: [Family]
        let mono: NSFont
        let monoBold: NSFont
        let thinRule: NSFont
        let rule: NSFont

        init(size: CGFloat) {
            self.size = size
            body = Family(.systemFont(ofSize: size))
            let scales: [CGFloat] = [2.0, 1.6, 1.3, 1.12, 1.0, 0.92]
            headings = scales.enumerated().map { level, scale in Family(.systemFont(ofSize: size * scale, weight: level < 2 ? .bold : .semibold)) }
            mono = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
            monoBold = .monospacedSystemFont(ofSize: size - 1, weight: .bold)
            thinRule = .systemFont(ofSize: 5)
            rule = .systemFont(ofSize: 6)
        }
    }

    /// Pure: it reads nothing from the app and touches no views, so it can run on any thread.
    static func render(_ markdown: String, baseURL: URL?, theme: Theme, fonts: Fonts) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let body = fonts.body
        let mono = fonts.mono
        let dim = theme.lineNumber
        let linkColor = NSColor(hex: theme.isDark ? 0x4DA3FF : 0x0969DA)
        let codeBackground = theme.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.06)

        func paragraph(spacingBefore: CGFloat = 0, spacingAfter: CGFloat = 10, indent: CGFloat = 0, firstIndent: CGFloat? = nil,
                       lineSpacing: CGFloat = 3) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = spacingAfter
            style.headIndent = indent
            style.firstLineHeadIndent = firstIndent ?? indent
            style.lineSpacing = lineSpacing
            return style
        }

        /// Bold, italic, inline code, links and strikethrough within one block of text.
        func inline(_ text: String, font family: Fonts.Family, color: NSColor) -> NSMutableAttributedString {
            let font = family.regular
            let result = NSMutableAttributedString()
            let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                  failurePolicy: .returnPartiallyParsedIfPossible)
            guard let parsed = try? AttributedString(markdown: text, options: options) else {
                return NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            }
            for run in parsed.runs {
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let intent = run.inlinePresentationIntent ?? []
                let isBold = intent.contains(.stronglyEmphasized), isItalic = intent.contains(.emphasized)
                if isBold || isItalic { attributes[.font] = isBold ? (isItalic ? family.boldItalic : family.bold) : family.italic }
                if intent.contains(.code) {
                    attributes[.font] = family.code
                    attributes[.backgroundColor] = codeBackground
                    attributes[.foregroundColor] = theme.string
                }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            return result
        }

        func append(_ text: NSAttributedString, style: NSParagraphStyle) {
            let block = NSMutableAttributedString(attributedString: text)
            block.append(NSAttributedString(string: "\n"))
            block.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: block.length))
            output.append(block)
        }

        func image(_ source: String, alt: String) -> NSAttributedString {
            // Only files from the project are shown; nothing is fetched from the network.
            if !source.contains("://"), let baseURL,
               let picture = cachedImage(at: baseURL.appendingPathComponent(source.removingPercentEncoding ?? source)) {
                let scale = min(1, 640 / max(picture.size.width, 1))
                let attachment = NSTextAttachment()
                attachment.image = picture
                attachment.bounds = NSRect(x: 0, y: 0, width: picture.size.width * scale, height: picture.size.height * scale)
                return NSAttributedString(attachment: attachment)
            }
            return NSAttributedString(string: "🖼 " + (alt.isEmpty ? source : alt), attributes: [.font: body.regular, .foregroundColor: dim])
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(inline(paragraphLines.joined(separator: " "), font: body, color: theme.foreground), style: paragraph())
            paragraphLines = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                // A line separator (not a newline) keeps the block one paragraph, so its lines sit tight together.
                let text = NSMutableAttributedString(string: code.joined(separator: "\u{2028}"),
                                                     attributes: [.font: mono, .foregroundColor: theme.foreground, .backgroundColor: codeBackground])
                append(text, style: paragraph(spacingBefore: 4, spacingAfter: 14, indent: 14, lineSpacing: 2))
                continue
            }
            if trimmed.isEmpty { flushParagraph(); index += 1; continue }

            // Heading
            let first = trimmed.first
            if first == "#", let match = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                let level = trimmed[match].filter { $0 == "#" }.count
                let font = fonts.headings[level - 1]
                var title = String(trimmed[match.upperBound...])
                while title.hasSuffix("#") || title.hasSuffix(" ") { title.removeLast() }
                append(inline(title, font: font, color: level == 6 ? dim : theme.foreground),
                       style: paragraph(spacingBefore: level <= 2 ? 18 : 12, spacingAfter: level <= 2 ? 10 : 6))
                if level <= 2 {     // the rule under the two biggest headings
                    append(NSAttributedString(string: String(repeating: "─", count: 60), attributes: [.font: fonts.thinRule, .foregroundColor: theme.border]),
                           style: paragraph(spacingAfter: 10, lineSpacing: 0))
                }
                index += 1
                continue
            }
            // Horizontal rule
            if first == "-" || first == "*" || first == "_", trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                append(NSAttributedString(string: String(repeating: "─", count: 60), attributes: [.font: fonts.rule, .foregroundColor: theme.border]),
                       style: paragraph(spacingBefore: 8, spacingAfter: 14, lineSpacing: 0))
                index += 1
                continue
            }
            // Table
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               lines[index + 1].range(of: #"^\s*\|?\s*:?-{2,}"#, options: .regularExpression) != nil {
                flushParagraph()
                var rows: [[String]] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    var cells = lines[index].trimmingCharacters(in: .whitespaces).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if cells.first == "" { cells.removeFirst() }
                    if cells.last == "" { cells.removeLast() }
                    rows.append(cells)
                    index += 1
                }
                guard rows.count >= 2 else { continue }
                rows.remove(at: 1)                                  // the |---|---| separator
                let columns = rows.map(\.count).max() ?? 0
                let widths = (0..<columns).map { column in rows.map { $0.count > column ? $0[column].count : 0 }.max() ?? 0 }
                for (rowIndex, row) in rows.enumerated() {
                    let padded = (0..<columns).map { column -> String in
                        let cell = row.count > column ? row[column] : ""
                        return cell + String(repeating: " ", count: widths[column] - cell.count)
                    }.joined(separator: "   ")
                    let font = rowIndex == 0 ? fonts.monoBold : mono
                    append(NSAttributedString(string: padded, attributes: [.font: font, .foregroundColor: theme.foreground]),
                           style: paragraph(spacingAfter: rowIndex == rows.count - 1 ? 14 : (rowIndex == 0 ? 6 : 2), indent: 6))
                }
                continue
            }
            // Block quote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                let text = NSMutableAttributedString(string: "▎ ", attributes: [.font: body.regular, .foregroundColor: theme.border])
                text.append(inline(quoted.joined(separator: " "), font: body, color: dim))
                append(text, style: paragraph(spacingAfter: 12, indent: 18, firstIndent: 4))
                continue
            }
            // List item (bullets, numbers, task boxes), nested by indentation
            if first == "-" || first == "*" || first == "+" || first?.isNumber == true,
               let match = line.range(of: #"^(\s*)([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                flushParagraph()
                let leading = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let depth = CGFloat(leading / 2)
                var content = String(line[match.upperBound...])
                let markerText = line[match].trimmingCharacters(in: .whitespaces)
                var marker = markerText.first?.isNumber == true ? markerText : "•"
                if content.hasPrefix("[ ] ") { marker = "☐"; content.removeFirst(4) }
                else if content.lowercased().hasPrefix("[x] ") { marker = "☑"; content.removeFirst(4) }
                // Lines that continue the item
                while index + 1 < lines.count {
                    let next = lines[index + 1]
                    let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.isEmpty || next.range(of: #"^(\s*)([-*+]|\d+[.)])\s+"#, options: .regularExpression) != nil
                        || nextTrimmed.hasPrefix("#") || nextTrimmed.hasPrefix("```") || nextTrimmed.hasPrefix(">") { break }
                    content += " " + nextTrimmed
                    index += 1
                }
                let text = NSMutableAttributedString(string: marker + "\t", attributes: [.font: body.regular, .foregroundColor: dim])
                text.append(inline(content, font: body, color: theme.foreground))
                let indent = 8 + depth * 20
                let style = NSMutableParagraphStyle()
                style.firstLineHeadIndent = indent
                style.headIndent = indent + 22
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 22)]
                style.paragraphSpacing = 4
                style.lineSpacing = 3
                append(text, style: style)
                index += 1
                continue
            }
            // An image on a line of its own
            if first == "!", let match = trimmed.range(of: #"^!\[([^\]]*)\]\(([^)\s]+)[^)]*\)$"#, options: .regularExpression) {
                flushParagraph()
                let inner = String(trimmed[match])
                let alt = inner.components(separatedBy: "](")[0].dropFirst(2)
                let source = inner.components(separatedBy: "](")[1].dropLast().components(separatedBy: " ")[0]
                append(image(source, alt: String(alt)), style: paragraph(spacingBefore: 4, spacingAfter: 14))
                index += 1
                continue
            }
            paragraphLines.append(trimmed)
            index += 1
        }
        flushParagraph()
        return output
    }
}

/// The rendered view of one Markdown document. It re-renders as the document is edited, in any editor.
final class MarkdownPreviewView: NSView, NSTextViewDelegate, TabPreview {
    var focusView: NSView { textView }
    /// A link to another file in the project was clicked.
    var onOpenFile: ((URL) -> Void)?
    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let document: TextDocument
    private var renderWork: DispatchWorkItem?
    private var hasShownTop = false
    private var needsRender = false
    private var fonts: MarkdownRenderer.Fonts?
    private var renderGeneration = 0
    private static let renderQueue = DispatchQueue(label: "feather.markdown.render", qos: .userInitiated)
    private var hasRenderedOnce = false
    private static let readableWidth: CGFloat = 820

    init(document: TextDocument) {
        self.document = document
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.delegate = self
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [:]              // links keep the colours the renderer gave them

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.useFeatherScrollers()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor), scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor), scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(sourceChanged),
                                               name: NSTextStorage.didProcessEditingNotification, object: document.storage)
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        // Keep lines to a comfortable reading width, centred, however wide the pane is.
        let side = max(28, (bounds.width - MarkdownPreviewView.readableWidth) / 2)
        if abs(textView.textContainerInset.width - side) > 0.5 { textView.textContainerInset = NSSize(width: side, height: 24) }
        if !hasShownTop, bounds.height > 0 {
            // The first layout happens after the first render; start at the top rather than wherever that left us.
            hasShownTop = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollView.contentView.scroll(to: .zero)
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    /// The colours are part of the rendered text, so a theme change re-renders — but only if it is on screen.
    func applyTheme() { render() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, needsRender { render() }
    }

    @objc private func sourceChanged() {
        guard document.storage.editedMask.contains(.editedCharacters) else { return }
        // A preview in a tab that is not showing catches up when it is shown, instead of re-rendering on every edit.
        guard window != nil else { needsRender = true; return }
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.render() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func render() {
        guard window != nil || !hasRenderedOnce else { needsRender = true; return }
        needsRender = false
        hasRenderedOnce = true
        // Everything the renderer needs is captured here, on the main thread; the parsing and styling — the slow
        // part for a long document — then runs in the background, so typing in the source never waits for it.
        let theme = Settings.shared.theme
        let size = CGFloat(Settings.shared.fontSize) + 1
        if fonts?.size != size { fonts = MarkdownRenderer.Fonts(size: size) }
        guard let fonts else { return }
        let text = document.text
        let baseURL = document.url?.deletingLastPathComponent()
        renderGeneration += 1
        let generation = renderGeneration
        textView.backgroundColor = theme.background
        scrollView.backgroundColor = theme.background
        MarkdownPreviewView.renderQueue.async { [weak self] in
            let rendered = MarkdownRenderer.render(text, baseURL: baseURL, theme: theme, fonts: fonts)
            DispatchQueue.main.async {
                guard let self, self.renderGeneration == generation else { return }     // a newer render is on its way
                let scroll = self.scrollView.contentView.bounds.origin
                self.textView.textStorage?.setAttributedString(rendered)
                // Typing in the source should not make the preview jump back to the top.
                self.scrollView.contentView.scroll(to: scroll)
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        // The What's New page's own link, answered here rather than by a trip through Launch Services.
        if url.scheme == "feather", url.host == "check-updates" { AppUpdater.shared.checkForUpdates(nil); return true }
        if url.scheme == nil || url.isFileURL, let base = document.url?.deletingLastPathComponent() {
            let path = url.path.removingPercentEncoding ?? url.path
            let target = url.isFileURL ? url : base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: target.path) { onOpenFile?(target.standardizedFileURL) }
            return true
        }
        return false            // web links open in the browser as usual
    }
}
