import AppKit

/// File-type icons. Real language logos come from the bundled Material Icon Theme SVGs (MIT licence, see
/// Resources/icons); anything without a logo falls back to a badge drawn in code. Each icon is loaded once
/// and shared, so a tree with thousands of files costs a few kilobytes.
enum FileIcon {
    // The three logo tables are internal so the tests can check the mapping without drawing anything.
    static let logoByExtension: [String: String] = {
        var map: [String: String] = [:]
        func add(_ extensions: String, _ logo: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = logo }
        }
        add("ts mts cts", "typescript"); add("tsx", "react_ts"); add("js mjs cjs", "javascript"); add("jsx", "react")
        add("py pyw", "python"); add("ipynb", "jupyter"); add("java", "java"); add("class jar war", "jar")
        add("kt kts", "kotlin"); add("dart", "dart"); add("swift", "swift"); add("go", "go"); add("rs", "rust")
        add("c", "c"); add("cpp cc cxx", "cpp"); add("h hpp hh", "h"); add("m mm", "objective-c")
        add("rb", "ruby"); add("php", "php"); add("sql", "database"); add("json jsonc", "json"); add("yaml yml", "yaml")
        add("toml", "toml"); add("ini cfg conf properties", "settings"); add("xml plist xib storyboard", "xml")
        add("html htm", "html"); add("vue", "vue"); add("css", "css"); add("scss sass", "sass"); add("less", "less")
        add("md markdown", "markdown"); add("mdx", "mdx"); add("txt log", "document")
        add("sh bash zsh fish command", "console"); add("gradle", "gradle"); add("lock", "lock"); add("pdf", "pdf")
        add("zip gz tar tgz rar 7z", "zip"); add("csv tsv", "table"); add("svg", "svg")
        add("png jpg jpeg gif webp ico heic bmp tiff", "image"); add("mp4 mov webm mkv", "video")
        add("mp3 wav m4a ogg", "audio"); add("ttf otf woff woff2", "font")
        return map
    }()

    static let logoByName: [String: String] = [
        "pom.xml": "maven", "mvnw": "maven", "build.gradle": "gradle", "build.gradle.kts": "gradle",
        "settings.gradle": "gradle", "settings.gradle.kts": "gradle", "gradlew": "gradle",
        "package.json": "nodejs", "package-lock.json": "npm", "pnpm-lock.yaml": "pnpm", "yarn.lock": "yarn",
        "bun.lockb": "bun", "bun.lock": "bun", "tsconfig.json": "tsconfig", "pubspec.yaml": "dart", "pubspec.lock": "lock",
        "requirements.txt": "python", "pyproject.toml": "python", "Dockerfile": "docker", ".dockerignore": "docker",
        "docker-compose.yml": "docker", "docker-compose.yaml": "docker", ".gitignore": "git", ".gitattributes": "git",
        "Makefile": "makefile", "LICENSE": "certificate", "README.md": "readme", "Package.swift": "swift",
    ]

    /// Logos whose match depends on part of the name rather than the whole of it.
    static func logoByPattern(_ name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("next.config.") { return "next" }
        if lower.hasPrefix("tailwind.config.") { return "tailwindcss" }
        if lower.hasPrefix(".eslintrc") || lower.hasPrefix("eslint.config.") { return "eslint" }
        if lower.hasPrefix(".prettierrc") || lower.hasPrefix("prettier.config.") { return "prettier" }
        if lower.hasPrefix(".env") { return "tune" }
        if lower.hasPrefix("dockerfile") { return "docker" }
        for marker in [".test.", ".spec."] where lower.contains(marker) {
            if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") { return "test-ts" }
            if lower.hasSuffix(".js") || lower.hasSuffix(".jsx") { return "test-js" }
        }
        return nil
    }

    /// The app bundle when installed; the project's Resources folder when run straight from `swift build`.
    private static let logoDirectory: URL? = {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("icons")) }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("../../../Resources/icons").standardizedFileURL)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("typescript.svg").path) }
    }()

    private static var missingLogos = Set<String>()

    private static func logo(_ name: String) -> NSImage? {
        let key = "logo:" + name
        if let cached = cache[key] { return cached }
        guard !missingLogos.contains(name), let directory = logoDirectory,
              let image = NSImage(contentsOf: directory.appendingPathComponent(name + ".svg")) else {
            missingLogos.insert(name)
            return nil
        }
        let bitmap = rasterized(image)
        cache[key] = bitmap
        return bitmap
    }

    /// SVG logos and drawn badges are vector: each row that shows one could render it again. Drawing it once into
    /// a 1× and 2× bitmap costs a few kilobytes and makes every later use a plain blit.
    private static func rasterized(_ source: NSImage) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let output = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            // The point size must be set before the context is made: that is what scales 16 points onto 32 pixels.
            rep.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: rep) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            source.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            output.addRepresentation(rep)
        }
        return output.representations.isEmpty ? source : output
    }

    private struct Badge {
        let label: String
        let fill: UInt32
        var text: UInt32 = 0xFFFFFF
    }

    private static let byExtension: [String: Badge] = {
        var map: [String: Badge] = [:]
        func add(_ extensions: String, _ badge: Badge) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = badge }
        }
        add("ts mts cts", Badge(label: "TS", fill: 0x3178C6))
        add("tsx", Badge(label: "TSX", fill: 0x1B9CC4))
        add("js mjs cjs", Badge(label: "JS", fill: 0xF0DB4F, text: 0x222222))
        add("jsx", Badge(label: "JSX", fill: 0xF0DB4F, text: 0x222222))
        add("py pyw", Badge(label: "PY", fill: 0x3572A5, text: 0xFFD43B))
        add("ipynb", Badge(label: "NB", fill: 0xF37726))
        add("java", Badge(label: "J", fill: 0xD3432F))
        add("class jar war", Badge(label: "JAR", fill: 0x8A5A44))
        add("kt kts", Badge(label: "K", fill: 0x7F52FF))
        add("dart", Badge(label: "D", fill: 0x0DA5C0))
        add("swift", Badge(label: "S", fill: 0xF05138))
        add("go", Badge(label: "GO", fill: 0x00ADD8))
        add("rs", Badge(label: "RS", fill: 0xC98F6B, text: 0x222222))
        add("c", Badge(label: "C", fill: 0x5C6BC0))
        add("cpp cc cxx", Badge(label: "C+", fill: 0x5C6BC0))
        add("h hpp hh", Badge(label: "H", fill: 0x8E7CC3))
        add("m mm", Badge(label: "M", fill: 0x438EFF))
        add("rb", Badge(label: "RB", fill: 0xCC342D))
        add("php", Badge(label: "PHP", fill: 0x777BB4))
        add("sql", Badge(label: "SQL", fill: 0xC77D0A))
        add("json jsonc", Badge(label: "{}", fill: 0xCBCB41, text: 0x222222))
        add("yaml yml", Badge(label: "YML", fill: 0x9B4DCA))
        add("toml ini cfg conf", Badge(label: "⚙", fill: 0x6D8086))
        add("properties", Badge(label: "⚙", fill: 0x6DB33F))
        add("xml plist xib storyboard", Badge(label: "<>", fill: 0xE37933))
        add("html htm", Badge(label: "<>", fill: 0xE44D26))
        add("vue", Badge(label: "V", fill: 0x41B883))
        add("css", Badge(label: "#", fill: 0x1572B6))
        add("scss sass less", Badge(label: "#", fill: 0xCD6799))
        add("md markdown mdx", Badge(label: "MD", fill: 0x519ABA))
        add("txt log", Badge(label: "T", fill: 0x7A8490))
        add("sh bash zsh fish command", Badge(label: "$", fill: 0x4EAA25))
        add("gradle", Badge(label: "G", fill: 0x1BA8A0))
        add("lock", Badge(label: "L", fill: 0x7A8490))
        add("pdf", Badge(label: "PDF", fill: 0xD93025))
        add("zip gz tar tgz rar 7z", Badge(label: "ZIP", fill: 0x8D6E63))
        add("csv tsv", Badge(label: "CSV", fill: 0x2E9E5B))
        return map
    }()

    /// Exact file names win over extensions.
    private static let byName: [String: Badge] = [
        "pom.xml": Badge(label: "M", fill: 0xC71A36),
        "build.gradle": Badge(label: "G", fill: 0x1BA8A0), "build.gradle.kts": Badge(label: "G", fill: 0x1BA8A0),
        "settings.gradle": Badge(label: "G", fill: 0x1BA8A0), "settings.gradle.kts": Badge(label: "G", fill: 0x1BA8A0),
        "gradlew": Badge(label: "G", fill: 0x1BA8A0), "mvnw": Badge(label: "M", fill: 0xC71A36),
        "application.properties": Badge(label: "SP", fill: 0x6DB33F), "application.yml": Badge(label: "SP", fill: 0x6DB33F),
        "application.yaml": Badge(label: "SP", fill: 0x6DB33F),
        "package.json": Badge(label: "N", fill: 0xCB3837), "package-lock.json": Badge(label: "L", fill: 0x7A8490),
        "pnpm-lock.yaml": Badge(label: "L", fill: 0x7A8490), "yarn.lock": Badge(label: "L", fill: 0x7A8490),
        "tsconfig.json": Badge(label: "TS", fill: 0x235A97),
        "next.config.js": Badge(label: "N", fill: 0x111111), "next.config.mjs": Badge(label: "N", fill: 0x111111),
        "next.config.ts": Badge(label: "N", fill: 0x111111),
        "pubspec.yaml": Badge(label: "F", fill: 0x54C5F8, text: 0x0B3A5B), "pubspec.lock": Badge(label: "L", fill: 0x7A8490),
        "requirements.txt": Badge(label: "PY", fill: 0x3572A5, text: 0xFFD43B),
        "pyproject.toml": Badge(label: "PY", fill: 0x3572A5, text: 0xFFD43B),
        "Dockerfile": Badge(label: "DK", fill: 0x2496ED), "docker-compose.yml": Badge(label: "DK", fill: 0x2496ED),
        "docker-compose.yaml": Badge(label: "DK", fill: 0x2496ED), ".dockerignore": Badge(label: "DK", fill: 0x2496ED),
        ".gitignore": Badge(label: "GIT", fill: 0xF05032), ".gitattributes": Badge(label: "GIT", fill: 0xF05032),
        "Makefile": Badge(label: "MK", fill: 0x6D8086), "LICENSE": Badge(label: "©", fill: 0xB8860B),
        "README.md": Badge(label: "i", fill: 0x2F81F7),
        "Package.swift": Badge(label: "S", fill: 0xF05138), "Podfile": Badge(label: "RB", fill: 0xCC342D),
    ]

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "heic", "bmp", "tiff"]
    private static let dimFolders: Set<String> = ["node_modules", "build", ".build", "dist", "target", ".dart_tool", ".gradle",
                                                  ".next", "__pycache__", "venv", ".venv", "Pods", "DerivedData", ".idea"]
    private static let testFolders: Set<String> = ["test", "tests", "__tests__", "spec", "androidTest", "integration_test"]
    private static let assetFolders: Set<String> = ["assets", "public", "static", "images", "resources", "res"]
    private static var cache: [String: NSImage] = [:]

    static func image(for url: URL, isDirectory: Bool) -> NSImage {
        let name = url.lastPathComponent
        if isDirectory {
            let color: UInt32 = dimFolders.contains(name) ? 0x6B7280 : testFolders.contains(name) ? 0x3FB950
                : assetFolders.contains(name) ? 0xB180D7 : name.hasPrefix(".git") ? 0xF05032 : 0x6CA7E0
            return symbol("folder.fill", color: color)
        }
        // Spring has no logo in the icon set, so its config files keep the green "SP" badge.
        let ext = url.pathExtension.lowercased()
        if !name.hasPrefix("application."),
           let logoName = logoByName[name] ?? logoByPattern(name) ?? logoByExtension[ext], let image = logo(logoName) {
            return image
        }
        if let badge = byName[name] { return badgeImage(badge) }
        if name.hasPrefix(".env") { return badgeImage(Badge(label: "ENV", fill: 0xB8A100, text: 0x222222)) }
        if name.hasPrefix("Dockerfile") { return badgeImage(Badge(label: "DK", fill: 0x2496ED)) }
        if let badge = byExtension[ext] { return badgeImage(badge) }
        if imageExtensions.contains(ext) { return symbol("photo", color: 0xB180D7) }
        return symbol("doc", color: 0x8B949E)
    }

    /// The icon as inline text, for rows that are built from attributed strings.
    static func attributed(for url: URL, isDirectory: Bool = false) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image(for: url, isDirectory: isDirectory)
        attachment.bounds = NSRect(x: 0, y: -3, width: 14, height: 14)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: "  "))
        return text
    }

    private static func symbol(_ name: String, color: UInt32) -> NSImage {
        let key = "symbol:\(name):\(color)"
        if let cached = cache[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(hex: color)]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? NSImage(size: NSSize(width: 16, height: 16))
        cache[key] = image
        return image
    }

    private static func badgeImage(_ badge: Badge) -> NSImage {
        let key = "badge:\(badge.label):\(badge.fill):\(badge.text)"
        if let cached = cache[key] { return cached }
        // A drawing handler keeps the icon resolution-independent, so it is crisp on Retina and when zoomed.
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let body = rect.insetBy(dx: 0.5, dy: 1.5)
            NSColor(hex: badge.fill).setFill()
            NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3).fill()
            let size: CGFloat = badge.label.count >= 3 ? 6.2 : badge.label.count == 2 ? 8 : 10
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .heavy),
                .foregroundColor: NSColor(hex: badge.text),
                .kern: badge.label.count >= 3 ? -0.3 : 0,
            ]
            let label = badge.label as NSString
            let bounds = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: body.midX - bounds.width / 2, y: body.midY - bounds.height / 2), withAttributes: attributes)
            return true
        }
        let bitmap = rasterized(image)
        cache[key] = bitmap
        return bitmap
    }
}
