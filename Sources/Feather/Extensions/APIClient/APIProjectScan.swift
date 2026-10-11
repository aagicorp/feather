import AppKit

/// What the project already says about its API: an OpenAPI or Swagger file, from which requests can be made.
enum APIProjectScan {
    /// The names an OpenAPI description usually has, in the order they are offered.
    static let openAPIFileNames = ["openapi.json", "openapi.yaml", "openapi.yml", "swagger.json", "swagger.yaml", "swagger.yml"]
    /// Folders next to the root that are looked in as well; nothing deeper, so this stays instant.
    static let openAPIFolders = ["api", "docs", "spec", "specs", "openapi", "swagger"]

    /// OpenAPI files at the project's root (and in the usual folders beside it), root first.
    static func findOpenAPIFiles(root: URL) -> [URL] {
        var found: [URL] = []
        for folder in [root] + openAPIFolders.map({ root.appendingPathComponent($0, isDirectory: true) }) {
            for name in openAPIFileNames {
                let url = folder.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue { found.append(url.standardizedFileURL) }
            }
        }
        return found
    }

    /// Turns an OpenAPI file into a collection. The reading itself belongs to the importer: this is nil until
    /// the import feature is merged, and then it is `APIImportExport.importFile`.
    static var generator: ((URL) throws -> APICollection)? = { file in
        let imported = try APIImportExport.importFile(at: file)
        guard let collection = imported.collections.first else {
            throw APIImportExport.ImportError(message: "No requests were found in \(file.lastPathComponent).")
        }
        return collection
    }
}

/// "openapi.yaml is in this project — Generate Requests": the box the API pane's empty state shows when the
/// project has an OpenAPI file. Built only when there is one (`APIClientController.makeOpenAPIOffer`).
final class APIOpenAPIOfferView: NSView {
    private let files: [URL]
    private let onGenerate: (URL) -> Void

    init(files: [URL], root: URL?, onGenerate: @escaping (URL) -> Void) {
        self.files = files
        self.onGenerate = onGenerate
        super.init(frame: .zero)
        let theme = Settings.shared.theme
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = theme.lineNumber.withAlphaComponent(0.35).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let names = files.map { TerminalText.relativePath(of: $0, root: root) }
        let text = NSTextField(wrappingLabelWithString: files.count == 1
            ? "This project describes its API in \(names[0]). Feather can make a request for every operation in it."
            : "This project describes its API in \(names.joined(separator: ", ")). Feather can make a request for every operation.")
        text.font = .systemFont(ofSize: 12)
        text.textColor = theme.foreground
        let button = NSButton(title: files.count == 1 ? "Generate Requests" : "Generate Requests…", target: self, action: #selector(generate(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        button.keyEquivalent = ""
        let column = NSStackView(views: [text, button])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        let row = NSStackView(views: [icon, column])
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func generate(_ sender: NSButton) {
        guard files.count > 1 else { return onGenerate(files[0]) }
        let menu = NSMenu()
        for file in files {
            let item = NSMenuItem(title: file.lastPathComponent + "  (" + file.deletingLastPathComponent().lastPathComponent + ")", action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = file
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        if let file = sender.representedObject as? URL { onGenerate(file) }
    }
}
