import Foundation

/// A mark the shell prints at the start and the end of every command (the OSC 133 sequences that VS Code and
/// iTerm use), so "the command finished, with this exit code" is known exactly rather than guessed from silence.
enum ShellMark: Equatable {
    case commandStarted
    case commandFinished(exitCode: Int32?)
}

/// Finds the marks in a terminal's raw output. A chunk without an escape character costs one scan for it; the
/// marks themselves are a few bytes each and can be split across two chunks, so a possible beginning is carried.
struct ShellMarkScanner {
    private var carry: [UInt8] = []
    private static let prefix: [UInt8] = Array("\u{1B}]133;".utf8)

    mutating func scan(_ slice: ArraySlice<UInt8>) -> [ShellMark] {
        if carry.isEmpty, !slice.contains(0x1B) { return [] }
        var bytes = carry
        bytes.append(contentsOf: slice)
        carry = []
        var marks: [ShellMark] = []
        var offset = 0
        while offset < bytes.count {
            guard let start = ShellMarkScanner.find(ShellMarkScanner.prefix, in: bytes, from: offset) else {
                keepPossibleStart(of: bytes, from: offset)
                break
            }
            let bodyStart = start + ShellMarkScanner.prefix.count
            var end = bodyStart
            var terminator = 0
            while end < bytes.count {
                if bytes[end] == 0x07 { terminator = 1; break }                                   // BEL
                if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C { terminator = 2; break }   // ESC \
                end += 1
            }
            guard terminator > 0 else {
                if bytes.count - start <= 64 { carry = Array(bytes[start...]) }        // unfinished: wait for the rest
                break
            }
            if let mark = ShellMarkScanner.parse(String(decoding: bytes[bodyStart..<end], as: UTF8.self)) { marks.append(mark) }
            offset = end + terminator
        }
        return marks
    }

    /// "C" starts a command; "D;<code>" ends one. The other marks (prompt start and end) are not needed here.
    static func parse(_ body: String) -> ShellMark? {
        let parts = body.split(separator: ";", omittingEmptySubsequences: false)
        switch parts.first {
        case "C": return .commandStarted
        case "D": return .commandFinished(exitCode: parts.count > 1 ? Int32(parts[1]) : nil)
        default: return nil
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from offset: Int) -> Int? {
        guard bytes.count - offset >= needle.count else { return nil }
        return bytes.withUnsafeBytes { buffer -> Int? in
            guard let base = buffer.baseAddress,
                  let hit = memmem(base + offset, bytes.count - offset, needle, needle.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(hit))
        }
    }

    /// The tail may be the first bytes of a mark whose rest is still to come.
    private mutating func keepPossibleStart(of bytes: [UInt8], from offset: Int) {
        let tailStart = max(offset, bytes.count - ShellMarkScanner.prefix.count + 1)
        guard let escape = bytes[tailStart...].lastIndex(of: 0x1B) else { return }
        let tail = Array(bytes[escape...])
        if Array(ShellMarkScanner.prefix.prefix(tail.count)) == tail { carry = tail }
    }
}

/// Gives a new shell the hooks that print the marks. zsh reads its start-up files from `ZDOTDIR`, so the shell
/// is pointed at a folder of Feather's whose files read the user's own files and then add two hooks; nothing in
/// the user's home is touched, and `ZDOTDIR` is put back before the first prompt. bash takes the hook through
/// `PROMPT_COMMAND` in the environment. Other shells get no marks and Feather guesses from silence as before.
enum ShellIntegration {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Feather/shell", isDirectory: true)
    }()

    /// The environment for a shell, with the integration added where the shell supports it.
    static func environment(forShell shell: String, from environment: [String]) -> [String] {
        let name = (shell as NSString).lastPathComponent
        var result = environment
        // `ls` colours folders, executables and links only when asked; the user's own choice of colours stands.
        if !result.contains(where: { $0.hasPrefix("CLICOLOR=") }) { result.append("CLICOLOR=1") }
        switch name {
        case "zsh":
            guard let shim = installZsh() else { return environment }
            // The user's own ZDOTDIR, if any, is handed to the shim files under another name.
            if let index = result.firstIndex(where: { $0.hasPrefix("ZDOTDIR=") }) {
                result[index] = "FEATHER_USER_" + result[index]
            }
            result.append("ZDOTDIR=" + shim.path)
        case "bash":
            result.removeAll { $0.hasPrefix("PROMPT_COMMAND=") }
            result.append(#"PROMPT_COMMAND=printf '\033]133;D;%s\007' "$?""#)
        default:
            break
        }
        return result
    }

    static let zshFiles: [String: String] = [
        ".zshenv": """
        # Feather's shell integration. This folder stands in for ZDOTDIR only long enough to add two hooks; your own
        # start-up files are read as usual, and ZDOTDIR is put back before the first prompt.
        FEATHER_ZDOTDIR_SHIM="$ZDOTDIR"
        ZDOTDIR="${FEATHER_USER_ZDOTDIR:-$HOME}"
        [[ -f "$ZDOTDIR/.zshenv" ]] && builtin source "$ZDOTDIR/.zshenv"
        FEATHER_USER_ZDOTDIR="${ZDOTDIR:-$HOME}"
        ZDOTDIR="$FEATHER_ZDOTDIR_SHIM"

        """,
        ".zprofile": """
        [[ -f "$FEATHER_USER_ZDOTDIR/.zprofile" ]] && builtin source "$FEATHER_USER_ZDOTDIR/.zprofile"

        """,
        ".zshrc": """
        [[ -f "$FEATHER_USER_ZDOTDIR/.zshrc" ]] && builtin source "$FEATHER_USER_ZDOTDIR/.zshrc"
        if [[ "$FEATHER_USER_ZDOTDIR" == "$HOME" ]]; then unset ZDOTDIR; else ZDOTDIR="$FEATHER_USER_ZDOTDIR"; fi
        unset FEATHER_USER_ZDOTDIR FEATHER_ZDOTDIR_SHIM
        __feather_preexec() { builtin printf '\\e]133;C\\a' }
        __feather_precmd() { local code=$?; builtin printf '\\e]133;D;%s\\a' "$code" }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec __feather_preexec
        add-zsh-hook precmd __feather_precmd

        """,
    ]

    /// Writes the zsh files (only when they differ from what is there). Nil when the folder cannot be written.
    static func installZsh() -> URL? {
        let folder = directory.appendingPathComponent("zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, text) in zshFiles {
                let url = folder.appendingPathComponent(name)
                if (try? String(contentsOf: url, encoding: .utf8)) != text { try text.write(to: url, atomically: true, encoding: .utf8) }
            }
            return folder
        } catch {
            return nil
        }
    }
}
