import AppKit

/// Everything the hover card shows about one commit.
struct GitCommitDetails {
    let hash: String
    let author: String
    let date: Date
    let coAuthors: [String]
    let message: String
    let filesChanged: Int
    let insertions: Int
    let deletions: Int
    /// Web page for the commit on GitHub, GitLab or Bitbucket, when the repository has such a remote.
    let webURL: URL?
    let hostName: String?

    private static let recordSeparator = "\u{1e}"
    private static var remoteCache: [URL: (base: String, host: String)?] = [:]

    static func load(_ hash: String, in root: URL, completion: @escaping (GitCommitDetails?) -> Void) {
        let format = "--format=%an%x1f%at%x1f%B%x1e"
        Git.run(["show", "--shortstat", format, hash], in: root) { result in
            guard result.ok else { return completion(nil) }
            let halves = result.output.components(separatedBy: recordSeparator)
            let fields = halves[0].components(separatedBy: GitGraphLayout.separator)
            guard fields.count >= 3 else { return completion(nil) }

            var coAuthors: [String] = []
            var lines: [String] = []
            for line in fields[2...].joined(separator: GitGraphLayout.separator).components(separatedBy: "\n") {
                if line.lowercased().hasPrefix("co-authored-by:") {
                    let name = line.dropFirst("co-authored-by:".count).components(separatedBy: "<")[0]
                    coAuthors.append(name.trimmingCharacters(in: .whitespaces))
                } else {
                    lines.append(line)
                }
            }
            func count(_ word: String) -> Int {
                let stat = halves.count > 1 ? halves[1] : ""
                guard let range = stat.range(of: #"(\d+) "# + word, options: .regularExpression) else { return 0 }
                return Int(stat[range].split(separator: " ")[0]) ?? 0
            }
            remote(for: root) { remote in
                completion(GitCommitDetails(
                    hash: hash, author: fields[0], date: Date(timeIntervalSince1970: TimeInterval(fields[1]) ?? 0),
                    coAuthors: coAuthors,
                    message: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                    filesChanged: count("file"), insertions: count("insertion"), deletions: count("deletion"),
                    webURL: remote.flatMap { URL(string: $0.base + hash) }, hostName: remote?.host))
            }
        }
    }

    /// Turns "git@github.com:org/repo.git" or "https://github.com/org/repo.git" into a commit-page prefix.
    private static func remote(for root: URL, completion: @escaping ((base: String, host: String)?) -> Void) {
        if let cached = remoteCache[root] { return completion(cached) }
        Git.run(["remote", "get-url", "origin"], in: root) { result in
            var address = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            var parsed: (base: String, host: String)?
            if result.ok, !address.isEmpty {
                if address.hasSuffix(".git") { address.removeLast(4) }
                if address.hasPrefix("git@") {
                    address = "https://" + address.dropFirst(4).replacingOccurrences(of: ":", with: "/")
                } else if address.hasPrefix("ssh://git@") {
                    address = "https://" + address.dropFirst("ssh://git@".count)
                }
                if let url = URL(string: address), let host = url.host, url.scheme == "https" {
                    // Drop any "user@" that an https remote may carry.
                    let clean = "https://\(host)\(url.path)"
                    if host.contains("github") { parsed = (clean + "/commit/", "GitHub") }
                    else if host.contains("gitlab") { parsed = (clean + "/-/commit/", "GitLab") }
                    else if host.contains("bitbucket") { parsed = (clean + "/commits/", "Bitbucket") }
                }
            }
            remoteCache[root] = parsed
            completion(parsed)
        }
    }
}

/// The card's content. It tells its owner when the pointer is over it, so moving from the row onto
/// the card (to press Copy or the link) does not dismiss it.
final class CommitHoverView: NSView {
    var onPointerInside: ((Bool) -> Void)?
    private let details: GitCommitDetails
    private static let width: CGFloat = 440

    init(details: GitCommitDetails, theme: Theme) {
        self.details = details
        super.init(frame: .zero)
        let accent = NSColor(hex: theme.isDark ? 0x4DA3FF : 0x0969DA)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7

        func symbol(_ name: String) -> NSAttributedString {
            let attachment = NSTextAttachment()
            let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [theme.lineNumber]))
            attachment.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            attachment.bounds = NSRect(x: 0, y: -2.5, width: 14, height: 14)
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " "))
            return text
        }
        func label(_ text: NSAttributedString) -> NSTextField {
            let field = NSTextField(labelWithAttributedString: text)
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = CommitHoverView.width - 28
            field.isSelectable = true
            return field
        }
        func separator() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            box.widthAnchor.constraint(equalToConstant: CommitHoverView.width - 28).isActive = true
            return box
        }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: theme.foreground]
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: accent]

        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        let absolute = DateFormatter()
        absolute.dateFormat = "d MMMM yyyy 'at' HH:mm"
        let header = NSMutableAttributedString(attributedString: symbol("person.circle"))
        header.append(NSAttributedString(string: details.author, attributes: strong))
        header.append(NSAttributedString(string: ",  ", attributes: body))
        header.append(symbol("clock.arrow.circlepath"))
        header.append(NSAttributedString(
            string: "\(relative.localizedString(for: details.date, relativeTo: Date())) (\(absolute.string(from: details.date)))",
            attributes: body))
        stack.addArrangedSubview(label(header))

        for name in details.coAuthors {
            let line = NSMutableAttributedString(attributedString: symbol("person.circle"))
            line.append(NSAttributedString(string: name, attributes: strong))
            line.append(NSAttributedString(string: "  (Co-author)", attributes: [
                .font: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12.5), toHaveTrait: .italicFontMask),
                .foregroundColor: theme.lineNumber]))
            stack.addArrangedSubview(label(line))
        }

        let message = details.message.count > 900 ? String(details.message.prefix(900)) + "…" : details.message
        stack.addArrangedSubview(label(NSAttributedString(string: message, attributes: body)))
        stack.addArrangedSubview(separator())

        let files = details.filesChanged
        let stats = NSMutableAttributedString(string: "\(files) file\(files == 1 ? "" : "s") changed", attributes: body)
        if details.insertions > 0 {
            stats.append(NSAttributedString(string: ",  ", attributes: body))
            stats.append(NSAttributedString(string: "\(details.insertions) insertion\(details.insertions == 1 ? "" : "s")(+)",
                                            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(hex: 0x3FB950)]))
        }
        if details.deletions > 0 {
            stats.append(NSAttributedString(string: ",  ", attributes: body))
            stats.append(NSAttributedString(string: "\(details.deletions) deletion\(details.deletions == 1 ? "" : "s")(-)",
                                            attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(hex: 0xF14C4C)]))
        }
        stack.addArrangedSubview(label(stats))
        stack.addArrangedSubview(separator())

        func linkButton(_ title: String, symbolName: String, action: Selector) -> NSButton {
            let button = NSButton(title: "", target: self, action: action)
            button.isBordered = false
            let text = NSMutableAttributedString(attributedString: symbol(symbolName))
            text.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: accent]))
            button.attributedTitle = text
            return button
        }
        let copy = linkButton(String(details.hash.prefix(7)), symbolName: "doc.on.doc", action: #selector(copyHash(_:)))
        copy.toolTip = "Copy the full commit hash"
        let footer = NSStackView(views: [copy])
        footer.spacing = 14
        if details.webURL != nil, let host = details.hostName {
            footer.addArrangedSubview(linkButton("Open on \(host)", symbolName: "arrow.up.right.square", action: #selector(openWeb)))
        }
        stack.addArrangedSubview(footer)

        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            widthAnchor.constraint(equalToConstant: CommitHoverView.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onPointerInside?(true) }

    override func mouseExited(with event: NSEvent) { onPointerInside?(false) }

    @objc private func copyHash(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details.hash, forType: .string)
        sender.toolTip = "Copied"
    }

    @objc private func openWeb() {
        if let url = details.webURL { NSWorkspace.shared.open(url) }
    }
}
