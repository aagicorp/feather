import Foundation

enum LineChange {
    case added, modified, deletedAbove
}

struct GitResult {
    let status: Int32
    let output: String
    let error: String

    var ok: Bool { status == 0 }
    /// What to show the user when the command failed.
    var message: String {
        let text = error.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}

struct GitFileChange: Equatable {
    let path: String           // relative to the repository root
    let status: Character      // M, A, D, R, U (untracked), ! (conflict)
    let isStaged: Bool
    /// Where a renamed or copied file came from; the diff view needs it to find the old text.
    var originalPath: String? = nil

    var isConflict: Bool { status == "!" }
    var isUntracked: Bool { status == "U" }
}

struct GitStatus: Equatable {
    var branch: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var staged: [GitFileChange] = []
    var unstaged: [GitFileChange] = []
    var isMerging = false
    /// A rebase (a pull with pull.rebase, or an interactive one) is paused on conflicts or between steps.
    var isRebasing = false
    /// "No commits yet": the branch exists only as a name, so there is nothing to push or publish.
    var isUnborn = false

    var conflicts: [GitFileChange] { unstaged.filter(\.isConflict) }
}

enum Git {
    /// Posted by a window after anything that may have changed a repository: a commit, a checkout, a block staged
    /// from a diff tab, coming back from another app. Diff tabs and the blame cache listen for it.
    static let repositoryDidChange = Notification.Name("FeatherGitRepositoryDidChange")

    /// Commands that change the repository run one at a time: they must not overlap on the index.
    private static let queue = DispatchQueue(label: "feather.git", qos: .userInitiated)
    private static let networkQueue = DispatchQueue(label: "feather.git.network", qos: .userInitiated)
    /// Commands that only read run a few at a time on their own pool, so a Stage click or a hover card never
    /// waits behind a background refresh of every repository. (GIT_OPTIONAL_LOCKS=0 makes concurrent reads safe.)
    private static let readQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private static let readOnlyCommands: Set<String> = ["status", "log", "show", "check-ignore", "rev-parse", "for-each-ref", "remote",
                                                       "diff", "blame"]

    // MARK: - Finding git

    /// The git that actually runs, or nil when this Mac has none. `/usr/bin/git` is never used: on a Mac without
    /// Xcode or the Command Line Tools it is a stub that puts up Apple's "install the developer tools?" dialog
    /// and blocks until it is answered, which from a background queue looks like Feather hanging.
    static var executable: URL? = locate()       // settable so tests can take git away
    static var isAvailable: Bool { executable != nil }
    static let notInstalledMessage = "Git is not installed on this Mac. Feather uses it for Source Control, checkpoints and the marks in the Explorer. Install Apple's Command Line Tools (xcode-select --install) or Xcode."

    /// Looks again: after the Command Line Tools were installed, or when the shell's PATH is known.
    static func recheck() {
        let found = locate()
        guard found != executable else { return }
        executable = found
        NotificationCenter.default.post(name: availabilityDidChange, object: nil)
    }
    static let availabilityDidChange = Notification.Name("FeatherGitAvailabilityDidChange")

    /// Candidates tried in order; tests point this at a scratch folder.
    static var asksXcodeSelect = true
    static var developerPaths = ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]

    static func locate(pathDirectories: [String]? = nil) -> URL? {
        let files = FileManager.default
        for path in developerPaths where files.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        // Xcode installed somewhere else: xcode-select is a real tool that answers without a dialog.
        if asksXcodeSelect, let selected = developerDirectory(), files.isExecutableFile(atPath: selected + "/usr/bin/git") {
            return URL(fileURLWithPath: selected + "/usr/bin/git")
        }
        let directories = pathDirectories ?? (ShellEnvironment.shared.pathDirectories.isEmpty
            ? ["/opt/homebrew/bin", "/usr/local/bin"] : ShellEnvironment.shared.pathDirectories)
        for directory in directories where directory != "/usr/bin" {
            let candidate = directory + "/git"
            if files.isExecutableFile(atPath: candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static func developerDirectory() -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcode-select") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// No git command may wait for ever: a stuck credential helper or a hung filesystem would otherwise hold a
    /// queue, and with it every later refresh.
    static let timeout: TimeInterval = 120
    static let networkTimeout: TimeInterval = 600

    /// Runs git and waits. Never prompts: credentials must come from the keychain, a credential helper, or ssh-agent.
    static func runSync(_ arguments: [String], in directory: URL) -> GitResult {
        let raw = runSyncData(arguments, in: directory)
        return GitResult(status: raw.status, output: String(decoding: raw.output, as: UTF8.self), error: raw.error)
    }

    /// The same with the output left as bytes. A patch cut from `git diff` has to go back to `git apply` exactly
    /// as it came out, whatever the file's encoding or line endings, so it must never pass through a String.
    static func runSyncData(_ arguments: [String], in directory: URL) -> (status: Int32, output: Data, error: String) {
        // A repository's own config can name programs for git to run (fsmonitor, hooks, an ssh command), so
        // git stays off in a folder that is not trusted.
        if WorkspaceTrust.shared.blocksExecution(in: directory) {
            return (-1, Data(), "Git is off in Restricted Mode. Trust this folder to use it.")
        }
        guard let executable else { return (-1, Data(), notInstalledMessage) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let shell = ShellEnvironment.shared
        var environment = shell.pathDirectories.isEmpty ? ProcessInfo.processInfo.environment : shell.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_MERGE_AUTOEDIT"] = "no"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return (-1, Data(), "Could not start git: \(error.localizedDescription)")
        }
        let isNetwork = ["push", "pull", "fetch", "clone"].contains(arguments.first ?? "")
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (isNetwork ? networkTimeout : timeout), execute: watchdog)
        defer { watchdog.cancel() }
        // Drain stderr on another thread so a chatty command cannot fill the pipe and deadlock.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, outputData, String(decoding: errorData, as: UTF8.self))
    }

    static func run(_ arguments: [String], in directory: URL, network: Bool = false,
                    completion: @escaping (GitResult) -> Void) {
        run(arguments, in: directory, network: network, transform: { $0 }, completion: completion)
    }

    /// `transform` runs on the background thread, so parsing large output never happens on the main thread.
    static func run<T>(_ arguments: [String], in directory: URL, network: Bool = false,
                       transform: @escaping (GitResult) -> T, completion: @escaping (T) -> Void) {
        let work = {
            let value = transform(runSync(arguments, in: directory))
            DispatchQueue.main.async { completion(value) }
        }
        if network {
            networkQueue.async(execute: work)
        } else if let command = arguments.first, readOnlyCommands.contains(command) {
            readQueue.addOperation(work)
        } else {
            queue.async(execute: work)
        }
    }

    /// Work made of several git calls (a diff needs both versions of the file and the diff itself). `changesIndex`
    /// puts it in line with the other commands that write, so a block being staged cannot overlap a commit.
    static func perform<T>(changesIndex: Bool, _ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        let job = {
            let value = work()
            DispatchQueue.main.async { completion(value) }
        }
        if changesIndex { queue.async(execute: job) } else { readQueue.addOperation(job) }
    }

    /// Runs commands in order, stopping at the first failure; completion gets the last result.
    static func runAll(_ commands: [[String]], in directory: URL, completion: @escaping (GitResult) -> Void) {
        queue.async {
            var last = GitResult(status: 0, output: "", error: "")
            for command in commands {
                last = runSync(command, in: directory)
                if !last.ok { break }
            }
            DispatchQueue.main.async { completion(last) }
        }
    }

    /// The committed (HEAD) version of a file, or nil when it is untracked or outside a repository.
    static func headContent(of file: URL, completion: @escaping (String?) -> Void) {
        run(["show", "HEAD:./" + file.lastPathComponent], in: file.deletingLastPathComponent()) { result in
            completion(result.ok ? result.output : nil)
        }
    }

    /// The same, already split into lines on the background thread (the gutter diff works on lines).
    static func headLines(of file: URL, completion: @escaping ([String]?) -> Void) {
        run(["show", "HEAD:./" + file.lastPathComponent], in: file.deletingLastPathComponent(),
            transform: { $0.ok ? $0.output.components(separatedBy: "\n") : nil }, completion: completion)
    }

    struct BranchStatus: Equatable {
        let name: String?          // nil on a detached HEAD
        let ahead: Int, behind: Int
    }

    /// The branch and how far it is from its upstream, for the status bar: `git status` without the file list.
    static func branchStatus(in directory: URL, completion: @escaping (BranchStatus?) -> Void) {
        run(["status", "--porcelain=v1", "-b", "-z", "--untracked-files=no", "--ignore-submodules"], in: directory,
            transform: { result -> BranchStatus? in
                guard result.ok else { return nil }
                let status = parseStatus(result.output)
                return BranchStatus(name: status.branch, ahead: status.ahead, behind: status.behind)
            }, completion: completion)
    }

    /// The branch checked out in the repository that owns `path`, read from `.git/HEAD` without running git,
    /// so it is cheap enough for a timer. A detached HEAD gives the short hash. Nil outside any repository.
    static func branchByReadingHEAD(nearPath path: String) -> String? {
        let manager = FileManager.default
        // Plain string paths, on purpose: on macOS 15 `URL.deletingLastPathComponent()` turns "/" into "/..",
        // then "/../..", for ever, so a walk that stops when the parent equals the folder never stops and the
        // terminal's branch poll spins the main thread at 100 % (macOS 26 answers "/" and hides the bug).
        var directory = (path as NSString).standardizingPath
        for _ in 0..<256 {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                var gitDirectory = dotGit
                if !isDirectory.boolValue {                // a worktree or submodule: ".git" is a file naming the real one
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDirectory = target.hasPrefix("/") ? target : (directory as NSString).appendingPathComponent(target)
                }
                guard let head = try? String(contentsOfFile: (gitDirectory as NSString).appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("ref: ") {
                    let ref = trimmed.dropFirst("ref: ".count)
                    return String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
                }
                return String(trimmed.prefix(7))
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty || directory == "/" { return nil }
            directory = parent
        }
        return nil
    }

    static func branch(in directory: URL, completion: @escaping (String?) -> Void) {
        run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory) { result in
            let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(result.ok && !name.isEmpty ? name : nil)
        }
    }

    static func repositoryRoot(for directory: URL, completion: @escaping (URL?) -> Void) {
        run(["rev-parse", "--show-toplevel"], in: directory) { result in
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(result.ok && !path.isEmpty ? URL(fileURLWithPath: path) : nil)
        }
    }

    /// Every repository in a workspace: the one the folder itself belongs to (if any) plus repositories nested
    /// inside it, which is the usual layout for a folder of microservices. Dependency folders are not searched.
    static func discoverRepositories(under root: URL, maxDepth: Int = 3, completion: @escaping ([URL]) -> Void) {
        queue.async {
            let files = FileManager.default
            var found: [URL] = []
            func hasGit(_ url: URL) -> Bool { files.fileExists(atPath: url.appendingPathComponent(".git").path) }
            if hasGit(root) {
                found.append(root)
            } else {
                let top = runSync(["rev-parse", "--show-toplevel"], in: root)
                let path = top.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if top.ok, !path.isEmpty { found.append(URL(fileURLWithPath: path)) }
            }
            func walk(_ directory: URL, depth: Int) {
                guard depth <= maxDepth, found.count < 60,
                      let children = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          !ProjectFiles.ignoredDirectories.contains(child.lastPathComponent) else { continue }
                    if hasGit(child) { found.append(child.standardizedFileURL) } else { walk(child, depth: depth + 1) }
                }
            }
            walk(root, depth: 1)
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// `allUntracked` lists every new file individually, which the selected repository's change list needs.
    /// For the other rows in the list a folder of new files can count as one entry, which is far cheaper.
    static func status(in root: URL, allUntracked: Bool = true, completion: @escaping (GitStatus?) -> Void) {
        let arguments = ["status", "--porcelain=v1", "-b", "-z", "--untracked-files=" + (allUntracked ? "all" : "normal")]
        run(arguments, in: root, transform: { result -> GitStatus? in
            guard result.ok else { return nil }
            var status = parseStatus(result.output)
            let gitDirectory = Git.gitDirectory(of: root)
            let files = FileManager.default
            status.isMerging = files.fileExists(atPath: gitDirectory.appendingPathComponent("MERGE_HEAD").path)
            status.isRebasing = files.fileExists(atPath: gitDirectory.appendingPathComponent("rebase-merge").path)
                || files.fileExists(atPath: gitDirectory.appendingPathComponent("rebase-apply").path)
            return status
        }, completion: completion)
    }

    /// The repository's `.git`: a folder, or for a worktree or a submodule a file that names the folder.
    static func gitDirectory(of root: URL) -> URL {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") else { return dotGit }
        let path = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path).standardizedFileURL
    }

    /// The commit HEAD points at; cheap enough to ask before deciding whether anything needs reloading.
    static func headCommit(in directory: URL, completion: @escaping (String?) -> Void) {
        run(["rev-parse", "HEAD"], in: directory) { result in
            completion(result.ok ? result.output.trimmingCharacters(in: .whitespacesAndNewlines) : nil)
        }
    }

    static func parseStatus(_ output: String) -> GitStatus {
        var status = GitStatus()
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)[...]
        while let entry = entries.popFirst() {
            if entry.hasPrefix("## ") {
                parseBranchLine(String(entry.dropFirst(3)), into: &status)
                continue
            }
            guard entry.count > 3 else { continue }
            let characters = Array(entry)
            let index = characters[0], worktree = characters[1]
            let path = String(characters[3...])
            var original: String?
            if index == "R" || index == "C" { original = entries.popFirst() }     // the original path follows
            let pair = String([index, worktree])
            if ["UU", "AA", "DD", "AU", "UA", "DU", "UD"].contains(pair) {
                status.unstaged.append(GitFileChange(path: path, status: "!", isStaged: false))
            } else if pair == "??" {
                status.unstaged.append(GitFileChange(path: path, status: "U", isStaged: false))
            } else if pair == "!!" {
                continue                                  // an ignored path (--ignored); never a change
            } else {
                if index != " " { status.staged.append(GitFileChange(path: path, status: index, isStaged: true, originalPath: original)) }
                if worktree != " " { status.unstaged.append(GitFileChange(path: path, status: worktree, isStaged: false)) }
            }
        }
        return status
    }

    /// A path as git prints it without -z: "unusual" names (non-ASCII, quotes, control characters) come wrapped in
    /// double quotes with C escapes, every non-ASCII byte as octal (`"\303\234n\303\257code"` for "Ünïcode"). Returns
    /// the name itself; a name that is not quoted is returned as it is.
    static func unquotePath(_ text: String) -> String {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return text }
        let inner = Array(text.utf8.dropFirst().dropLast())
        var bytes: [UInt8] = []
        bytes.reserveCapacity(inner.count)
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < inner.count else { bytes.append(byte); index += 1; continue }
            let next = inner[index + 1]
            switch next {
            case UInt8(ascii: "a"): bytes.append(7); index += 2
            case UInt8(ascii: "b"): bytes.append(8); index += 2
            case UInt8(ascii: "t"): bytes.append(9); index += 2
            case UInt8(ascii: "n"): bytes.append(10); index += 2
            case UInt8(ascii: "v"): bytes.append(11); index += 2
            case UInt8(ascii: "f"): bytes.append(12); index += 2
            case UInt8(ascii: "r"): bytes.append(13); index += 2
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = 0, length = 0
                while length < 3, index + 1 + length < inner.count, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index + 1 + length]) {
                    value = value * 8 + Int(inner[index + 1 + length] - UInt8(ascii: "0"))
                    length += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
                index += 1 + length
            default: bytes.append(next); index += 2                  // \" \\ and anything else: the character itself
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "main...origin/main [ahead 1, behind 2]", "No commits yet on main", or "HEAD (no branch)".
    private static func parseBranchLine(_ line: String, into status: inout GitStatus) {
        var text = line
        if let bracket = text.range(of: " [") {
            let counts = text[bracket.upperBound...].dropLast()
            for part in counts.components(separatedBy: ", ") {
                let pieces = part.split(separator: " ")
                guard pieces.count == 2, let number = Int(pieces[1]) else { continue }
                if pieces[0] == "ahead" { status.ahead = number } else if pieces[0] == "behind" { status.behind = number }
            }
            text = String(text[..<bracket.lowerBound])
        }
        if text.hasPrefix("No commits yet on ") {
            status.branch = String(text.dropFirst("No commits yet on ".count))
            status.isUnborn = true
        } else if text.hasPrefix("HEAD (no branch)") {
            status.branch = nil
        } else if let dots = text.range(of: "...") {
            status.branch = String(text[..<dots.lowerBound])
            status.upstream = String(text[dots.upperBound...])
        } else {
            status.branch = text
        }
    }

    /// Local branches first, then remote ones; the current branch is excluded.
    static func otherBranches(in root: URL, completion: @escaping ([String]) -> Void) {
        run(["for-each-ref", "--format=%(HEAD)%(refname:short)", "refs/heads", "refs/remotes"], in: root) { result in
            let names = result.output.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("*") && !$0.hasSuffix("/HEAD") }
                .map { String($0.dropFirst()) }
            completion(names)
        }
    }
}

enum LineDiff {
    static let maxLines = 20_000

    /// Gutter markers keyed by zero-based line in `new`. A removal paired with an insertion reads as "modified".
    static func markers(old: [String], new: [String]) -> [Int: LineChange] {
        guard old.count <= maxLines, new.count <= maxLines else { return [:] }
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var markers: [Int: LineChange] = [:]
        var i = 0, j = 0
        while i < old.count || j < new.count {
            let isRemoved = removed.contains(i), isInserted = inserted.contains(j)
            if isRemoved && isInserted {
                markers[j] = .modified
                i += 1; j += 1
            } else if isRemoved {
                if markers[j] == nil { markers[min(j, max(0, new.count - 1))] = .deletedAbove }
                i += 1
            } else if isInserted {
                markers[j] = .added
                j += 1
            } else {
                i += 1; j += 1
            }
        }
        return markers
    }
}
