import AppKit

/// A path as people type it on a command line or paste it from a compiler error: `src/App.tsx`, `src/App.tsx:12`
/// or `src/App.tsx:12:5`. Lines and columns count from 1.
struct PathArgument: Equatable {
    let path: String
    var line: Int?
    var column: Int?

    /// A file that really is called `notes:12` wins over line 12 of `notes`, which is why this asks the disk.
    static func parse(_ argument: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> PathArgument {
        if exists(argument) { return PathArgument(path: argument) }
        var parts = argument.components(separatedBy: ":")
        var numbers: [Int] = []
        // A trailing colon ("file.c:12:" from grep) leaves an empty last part.
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        while numbers.count < 2, parts.count > 1, let last = parts.last, let number = Int(last), number >= 0, last.allSatisfy(\.isNumber) {
            numbers.insert(number, at: 0)
            parts.removeLast()
        }
        let path = parts.joined(separator: ":")
        guard !numbers.isEmpty, !path.isEmpty else { return PathArgument(path: argument) }
        return PathArgument(path: path, line: max(1, numbers[0]), column: numbers.count > 1 ? max(1, numbers[1]) : nil)
    }

    /// What a URL handed to the app means when it is more than a plain existing path: a `feather://` link, or a
    /// file URL made from "file:12". Nil for everything else, which opens as it always did.
    static func resolve(_ url: URL) -> PathArgument? {
        if url.scheme == CommandLineTool.urlScheme { return parse(url: url) }
        guard url.isFileURL, !FileManager.default.fileExists(atPath: url.path) else { return nil }
        let parsed = parse(url.path)
        return parsed.line != nil && FileManager.default.fileExists(atPath: parsed.path) ? parsed : nil
    }

    /// `feather://open?path=/abs/file&line=12&column=5`, which is how the `feather` command passes a position to
    /// an app that is already running (a plain file argument cannot carry one).
    static func parse(url: URL) -> PathArgument? {
        guard url.scheme == CommandLineTool.urlScheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let path = value("path"), path.hasPrefix("/") else { return nil }
        return PathArgument(path: path, line: value("line").flatMap(Int.init).map { max(1, $0) },
                            column: value("column").flatMap(Int.init).map { max(1, $0) })
    }
}

/// Feather ▸ Install 'feather' Command…: a small shell script on the PATH that opens files and folders in Feather.
final class CommandLineTool: NSObject, NSMenuItemValidation {
    static let shared = CommandLineTool()
    static let urlScheme = "feather"

    /// Where the script goes: the first of these that can be written without asking for a password.
    static var destinations: [URL] {
        [URL(fileURLWithPath: "/usr/local/bin/feather"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/feather")]
    }
    private static let marker = "# Installed by Feather"

    /// The script. `appPath` is the app that installed it; if that has moved, macOS finds Feather by name.
    static func script(appPath: String?) -> String {
        let app = appPath.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? "''"
        return """
        #!/bin/bash
        \(marker). Opens files and folders in Feather:
        #   feather .            feather src/App.tsx            feather src/App.tsx:12        feather src/App.tsx:12:5
        APP=\(app)
        if [ -n "$APP" ] && [ -d "$APP" ]; then target=(-a "$APP"); else target=(-a Feather); fi

        urlencode() {
            local LC_ALL=C text="$1" out="" c i
            for ((i = 0; i < ${#text}; i++)); do
                c="${text:i:1}"
                case "$c" in
                    [a-zA-Z0-9/._~-]) out+="$c" ;;
                    *) out+=$(printf '%%%02X' "'$c") ;;
                esac
            done
            printf '%s' "$out"
        }

        absolute() {
            case "$1" in
                /*) printf '%s' "$1" ;;
                *) printf '%s' "$PWD/$1" ;;
            esac
        }

        if [ $# -eq 0 ]; then exec open "${target[@]}"; fi

        status=0
        paths=()
        urls=()
        for arg in "$@"; do
            if [ -e "$arg" ]; then
                paths+=("$(absolute "$arg")")
            elif [[ "$arg" =~ ^(.+):([0-9]+):([0-9]+):?$ ]] && [ -e "${BASH_REMATCH[1]}" ]; then
                urls+=("feather://open?path=$(urlencode "$(absolute "${BASH_REMATCH[1]}")")&line=${BASH_REMATCH[2]}&column=${BASH_REMATCH[3]}")
            elif [[ "$arg" =~ ^(.+):([0-9]+):?$ ]] && [ -e "${BASH_REMATCH[1]}" ]; then
                urls+=("feather://open?path=$(urlencode "$(absolute "${BASH_REMATCH[1]}")")&line=${BASH_REMATCH[2]}")
            else
                echo "feather: no such file or folder: $arg" >&2
                status=1
            fi
        done
        if [ ${#paths[@]} -gt 0 ]; then open "${target[@]}" "${paths[@]}" || status=1; fi
        for url in "${urls[@]}"; do open "${target[@]}" "$url" || status=1; done
        exit $status

        """
    }

    enum InstallResult: Equatable {
        case installed(URL, onPath: Bool)
        case failed(String)
    }

    /// Writes the script to the first destination whose folder is, or can be made, writable. Never asks for a
    /// password: `/usr/local/bin` is often the user's own (Homebrew on Intel), and `~/.local/bin` always is.
    static func install(to destinations: [URL] = CommandLineTool.destinations, appPath: String? = installedAppPath,
                        isOnPath: (URL) -> Bool = CommandLineTool.isOnLoginShellPath) -> InstallResult {
        let files = FileManager.default
        var lastError = "No destination was given."
        for destination in destinations {
            let folder = destination.deletingLastPathComponent()
            // `~/.local/bin` is made if need be; a missing /usr/local/bin would take sudo, so it is passed over.
            if !files.fileExists(atPath: folder.path), !folder.path.hasPrefix("/usr/") {
                try? files.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            guard files.isWritableFile(atPath: folder.path) else { lastError = "\(folder.path) is not writable."; continue }
            // Something else called "feather" is not ours to replace.
            if files.fileExists(atPath: destination.path), !isOurs(destination) {
                lastError = "\(destination.path) exists and was not installed by Feather."
                continue
            }
            do {
                try script(appPath: appPath).write(to: destination, atomically: true, encoding: .utf8)
                try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                return .installed(destination, onPath: isOnPath(folder))
            } catch {
                lastError = error.localizedDescription
            }
        }
        return .failed(lastError)
    }

    /// Asks the user's own login shell, the one a terminal starts, since its PATH is set in files only it reads.
    /// Waits at most three seconds; this follows a menu command, not a keystroke.
    static func isOnLoginShellPath(_ folder: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "echo __FEATHER__${PATH}__FEATHER__"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        timeout.cancel()
        let parts = String(decoding: data, as: UTF8.self).components(separatedBy: "__FEATHER__")
        guard parts.count >= 3 else { return false }
        let wanted = folder.standardizedFileURL.path
        return parts[1].split(separator: ":").contains { URL(fileURLWithPath: String($0)).standardizedFileURL.path == wanted }
    }

    /// Removes the scripts Feather wrote, and only those. Returns what was removed.
    @discardableResult
    static func uninstall(from destinations: [URL] = CommandLineTool.destinations) -> [URL] {
        destinations.filter { isOurs($0) && (try? FileManager.default.removeItem(at: $0)) != nil }
    }

    static func installedCopies(in destinations: [URL] = CommandLineTool.destinations) -> [URL] { destinations.filter(isOurs) }

    private static func isOurs(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 400)) ?? Data(), as: UTF8.self)
        return head.contains(marker)
    }

    /// The `.app` this process runs from; nil for a bare binary (a development build), which `open -a` cannot take.
    static var installedAppPath: String? {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? path : nil
    }

    // MARK: - Menu

    private weak var uninstallItem: NSMenuItem?

    /// The two items for the Feather menu. Uninstall is only there while there is something to uninstall.
    func menuItems() -> [NSMenuItem] {
        let install = NSMenuItem(title: "Install 'feather' Command…", action: #selector(installCommand(_:)), keyEquivalent: "")
        let uninstall = NSMenuItem(title: "Uninstall 'feather' Command", action: #selector(uninstallCommand(_:)), keyEquivalent: "")
        install.target = self
        uninstall.target = self
        uninstall.isHidden = CommandLineTool.installedCopies().isEmpty
        uninstallItem = uninstall
        return [install, uninstall]
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(uninstallCommand(_:)) { menuItem.isHidden = CommandLineTool.installedCopies().isEmpty }
        return true
    }

    @objc private func installCommand(_ sender: Any?) {
        let alert = NSAlert()
        switch CommandLineTool.install() {
        case .installed(let url, let onPath):
            let shown = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            alert.messageText = "The 'feather' command is installed."
            alert.informativeText = "It is at \(shown). In a terminal, try:\n\n    feather .\n    feather src/App.tsx:12"
            if !onPath {
                let folder = (shown as NSString).deletingLastPathComponent
                alert.informativeText += "\n\n\(folder) is not on your PATH yet. Add this line to ~/.zshrc and open a new terminal:\n\n    export PATH=\"\(folder.replacingOccurrences(of: "~", with: "$HOME")):$PATH\""
            }
        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = "The 'feather' command could not be installed."
            alert.informativeText = reason
        }
        uninstallItem?.isHidden = CommandLineTool.installedCopies().isEmpty
        alert.runModal()
    }

    @objc private func uninstallCommand(_ sender: Any?) {
        let removed = CommandLineTool.uninstall()
        uninstallItem?.isHidden = CommandLineTool.installedCopies().isEmpty
        let alert = NSAlert()
        alert.messageText = removed.isEmpty ? "The 'feather' command could not be removed." : "The 'feather' command was removed."
        alert.informativeText = removed.map(\.path).joined(separator: "\n")
        alert.runModal()
    }
}
