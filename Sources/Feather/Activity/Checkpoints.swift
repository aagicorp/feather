import AppKit
import CryptoKit

/// A snapshot of the whole project folder that the user can return to.
struct Checkpoint: Equatable {
    /// Why it was taken. A safety checkpoint is the one Feather takes just before it undoes changes, so that the
    /// undo can itself be undone.
    enum Kind: String { case automatic, manual, safety }

    /// Its name inside the private store; also the moment it was taken, in milliseconds, so ids sort by age.
    let id: String
    let commit: String
    let name: String
    let date: Date
    let kind: Kind

    /// "5 min ago", for the pane and the menus.
    var age: String { Checkpoint.age(of: date) }

    static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(seconds) sec ago"
        case ..<3600: return "\(seconds / 60) min ago"
        case ..<86_400: return "\(seconds / 3600) hr ago"
        default: return "\(seconds / 86_400) d ago"
        }
    }

    /// The same, as short as it gets, for a row that is 170 points wide.
    static func shortAge(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

/// One file that is different from what the checkpoint holds.
struct ActivityChange: Equatable {
    enum Kind: Int { case changed, created, deleted }

    /// Relative to the project folder.
    let path: String
    var kind: Kind
    /// Lines added and taken away; nil when they were not counted (a binary file, or too many files to count).
    var insertions: Int?
    var deletions: Int?
    /// When the file last changed on disk. A deleted file has no date of its own.
    var modified: Date?
    var isBinary = false
}

/// Everything the Activity pane shows, worked out in one go off the main thread.
struct ActivitySnapshot {
    let checkpoint: Checkpoint
    /// Newest change first.
    var changes: [ActivityChange]
    /// How many more files changed than are listed (a huge change set is cut short).
    var unlisted = 0
    var milliseconds = 0.0

    var insertions: Int { changes.reduce(0) { $0 + ($1.insertions ?? 0) } }
    var deletions: Int { changes.reduce(0) { $0 + ($1.deletions ?? 0) } }
}

/// What an undo did, for the message afterwards and for bringing open documents up to date.
struct RestoreOutcome {
    var restored: [String] = []
    var trashed: [String] = []
    var skipped: [String] = []
    /// Where each new file went in the Trash.
    var trashedURLs: [URL] = []
    /// The checkpoint of how things were just before, which undoes this undo.
    var safety: Checkpoint?
    var error: String?

    var touched: [String] { restored + trashed }
}

/// The checkpoints of one project folder.
///
/// They live in a private git repository of Feather's own, outside the project, that uses the project folder as
/// its work tree (`GIT_DIR` + `GIT_WORK_TREE`). The project's own `.git`, index, stash and config are never read
/// or written: git is told exactly which repository to use and is given no user or system config. The project's
/// `.gitignore` files still apply, because they are part of the work tree, which is what keeps `node_modules` and
/// build output out. Nothing here can run a program the project names (no hooks, no filters, no fsmonitor), so it
/// is safe in a folder that is open in Restricted Mode.
final class CheckpointStore {
    /// Where every project's checkpoints are kept. A test points this somewhere else before any store is made.
    static var baseDirectory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Feather/checkpoints", isDirectory: true)
    }()

    /// Posted on the main thread after an undo or a block undo changed files (object: the store).
    static let didRestoreFiles = Notification.Name("FeatherCheckpointStoreDidRestoreFiles")
    /// Posted on the main thread when the list of checkpoints changed (object: the store).
    static let didChangeCheckpoints = Notification.Name("FeatherCheckpointStoreDidChangeCheckpoints")

    static let keepCount = 30
    /// A new file bigger than this is left out of checkpoints (a video, a database, a model file).
    static let maxFileBytes = 5_000_000
    /// A folder with more new files than this is not a project (someone opened their home folder).
    static let maxNewFiles = 40_000
    /// How many changed files the pane lists, and how many new files get their lines counted.
    static let maxListedChanges = 500
    static let maxCountedNewFiles = 300

    /// Folders that are never part of a checkpoint even when the project has no `.gitignore` of its own: packages
    /// that are downloaded and output that is built, for the tools Feather's users work with.
    static let builtInExcludes = [
        ".DS_Store", "node_modules/", ".build/", "build/", "target/", "dist/", ".next/", ".nuxt/", ".turbo/",
        ".dart_tool/", "__pycache__/", "*.pyc", ".venv/", "venv/", ".gradle/", ".idea/", "Pods/", "DerivedData/",
        ".cache/", ".pytest_cache/", ".mypy_cache/", "*.class", ".feather-trash/",
    ]
    /// The same names as plain folder names, for throwing away file-system events nobody needs to look at.
    static let noisyFolders: Set<String> = [
        ".git", "node_modules", ".build", "build", "target", "dist", ".next", ".nuxt", ".turbo", ".dart_tool",
        "__pycache__", ".venv", "venv", ".gradle", ".idea", "Pods", "DerivedData", ".cache", ".pytest_cache", ".mypy_cache",
    ]

    private static var stores: [String: CheckpointStore] = [:]

    /// One store per folder, shared by every window showing it, so their work stays in one line.
    static func store(for root: URL) -> CheckpointStore {
        let root = root.standardizedFileURL
        let key = baseDirectory.path + "\n" + root.path
        if let existing = stores[key] { return existing }
        let store = CheckpointStore(root: root)
        stores[key] = store
        return store
    }

    let root: URL
    /// This project's folder inside `baseDirectory`.
    let directory: URL
    private var gitDirectory: URL { directory.appendingPathComponent("git", isDirectory: true) }
    private var hooksDirectory: URL { directory.appendingPathComponent("no-hooks", isDirectory: true) }
    /// Everything runs here, one thing at a time: a checkpoint being written must not overlap a comparison.
    private let queue = DispatchQueue(label: "feather.checkpoints", qos: .userInitiated)
    private var isReady = false
    private var prunesSinceTidy = 0
    /// What the list was when it was last read; the main thread's copy.
    private(set) var checkpoints: [Checkpoint] = []

    private init(root: URL) {
        self.root = root
        let digest = SHA256.hash(data: Data(root.path.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
        directory = CheckpointStore.baseDirectory.appendingPathComponent(digest, isDirectory: true)
    }

    // MARK: - Running git

    /// `/usr/bin/git` is a small program that looks for the real one each time it runs, which costs more than git
    /// itself for the short commands used here. A checkpoint is nine of them, so the real one is found once.
    private static var gitExecutable: URL? { Git.executable }

    private struct Output {
        let status: Int32
        let data: Data
        let error: String
        var ok: Bool { status == 0 }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    /// Git with nothing inherited: no user or system config, no hooks, no filters, no pager, no prompts, a fixed
    /// author. Every setting that matters is passed on each call, so it holds even if the stored config were edited.
    private func git(_ arguments: [String], input: Data? = nil, date: Date? = nil) -> Output {
        guard let executable = CheckpointStore.gitExecutable else { return Output(status: -1, data: Data(), error: Git.notInstalledMessage) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = root
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": directory.path,
            "LC_ALL": "C",
            "GIT_DIR": gitDirectory.path,
            "GIT_WORK_TREE": root.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_LITERAL_PATHSPECS": "1",
            "GIT_PAGER": "cat",
            "GIT_EDITOR": "true",
            "GIT_AUTHOR_NAME": "Feather", "GIT_AUTHOR_EMAIL": "checkpoints@feather.invalid",
            "GIT_COMMITTER_NAME": "Feather", "GIT_COMMITTER_EMAIL": "checkpoints@feather.invalid",
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { environment["DEVELOPER_DIR"] = developer }
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            environment["GIT_AUTHOR_DATE"] = stamp
            environment["GIT_COMMITTER_DATE"] = stamp
        }
        let config: [(String, String)] = [
            ("core.hooksPath", hooksDirectory.path), ("core.fsmonitor", "false"), ("core.autocrlf", "false"),
            ("core.safecrlf", "false"), ("core.quotePath", "false"), ("core.untrackedCache", "true"),
            ("core.excludesFile", "/dev/null"), ("core.attributesFile", "/dev/null"), ("core.bare", "false"),
            ("gc.auto", "0"), ("commit.gpgSign", "false"), ("diff.external", ""), ("diff.renames", "false"),
            ("advice.addEmbeddedRepo", "false"), ("maintenance.auto", "false"),
        ]
        environment["GIT_CONFIG_COUNT"] = String(config.count)
        for (index, entry) in config.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = entry.0
            environment["GIT_CONFIG_VALUE_\(index)"] = entry.1
        }
        process.environment = environment
        let output = Pipe(), error = Pipe(), stdin = Pipe()
        process.standardOutput = output
        process.standardError = error
        if input != nil { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        do { try process.run() } catch {
            return Output(status: -1, data: Data(), error: "Could not start git: \(error.localizedDescription)")
        }
        // Each pipe gets a thread of its own, so none can fill up and stall the others.
        let group = DispatchGroup()
        var errorData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = error.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if let input {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = stdin.fileHandleForWriting
                try? handle.write(contentsOf: input)
                try? handle.close()
                group.leave()
            }
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: outputData, error: String(decoding: errorData, as: UTF8.self))
    }

    /// Makes the private repository the first time it is needed. Returns a message when it cannot.
    private func prepare() -> String? {
        if isReady { return nil }
        guard Git.isAvailable else { return Git.notInstalledMessage }
        let files = FileManager.default
        do {
            try files.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
            if !files.fileExists(atPath: gitDirectory.appendingPathComponent("HEAD").path) {
                let made = git(["init", "--quiet"])
                guard made.ok else { return made.error }
            }
            let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
            try files.createDirectory(at: info, withIntermediateDirectories: true)
            try (CheckpointStore.builtInExcludes.joined(separator: "\n") + "\n")
                .write(to: info.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)
            // Files come back byte for byte: no line-ending conversion, no filters, whatever the project's own
            // `.gitattributes` says. This file outranks those.
            try "* -text -filter -ident -working-tree-encoding\n"
                .write(to: info.appendingPathComponent("attributes"), atomically: true, encoding: .utf8)
            try (root.path + "\n").write(to: directory.appendingPathComponent("project-folder.txt"), atomically: true, encoding: .utf8)
        } catch {
            return error.localizedDescription
        }
        isReady = true
        return nil
    }

    private static func nulSeparated(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func nulJoined(_ paths: [String]) -> Data {
        var data = Data()
        for path in paths {
            data.append(contentsOf: path.utf8)
            data.append(0)
        }
        return data
    }

    private func size(of path: String) -> Int? {
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return nil }
        return Int(info.st_size)
    }

    private func modificationDate(of path: String) -> Date? {
        var info = stat()
        guard lstat(root.appendingPathComponent(path).path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// New files that belong in a checkpoint: not ignored, not a folder with a repository of its own (git names
    /// those with a trailing slash and cannot hold them), not enormous.
    private func newFiles() -> [String] {
        let listed = git(["ls-files", "-z", "--others", "--exclude-standard"])
        guard listed.ok else { return [] }
        return CheckpointStore.nulSeparated(listed.data).filter { path in
            guard !path.hasSuffix("/"), let size = size(of: path) else { return false }
            return size <= CheckpointStore.maxFileBytes
        }
    }

    // MARK: - Taking and listing checkpoints (on the queue)

    private func readCheckpoints() -> [Checkpoint] {
        let listed = git(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(contents)%00%00", "refs/checkpoints"])
        guard listed.ok else { return [] }
        var result: [Checkpoint] = []
        // Records end in two NULs; a name cannot hold one.
        let text = listed.text
        for record in text.components(separatedBy: "\0\0") {
            let fields = record.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
            guard fields.count >= 3, let id = fields[0].split(separator: "/").last.map(String.init),
                  let milliseconds = Double(id.prefix { $0.isNumber }) else { continue }
            let lines = fields[2].components(separatedBy: "\n")
            let kind = lines.first { $0.hasPrefix("kind: ") }.flatMap { Checkpoint.Kind(rawValue: String($0.dropFirst(6))) } ?? .manual
            result.append(Checkpoint(id: id, commit: fields[1], name: lines.first ?? "Checkpoint",
                                     date: Date(timeIntervalSince1970: milliseconds / 1000), kind: kind))
        }
        return result.sorted { $0.id > $1.id }
    }

    private func takeCheckpoint(name: String, kind: Checkpoint.Kind) -> Result<Checkpoint, CheckpointError> {
        if let problem = prepare() { return .failure(.failed(problem)) }
        let added = newFiles()
        guard added.count <= CheckpointStore.maxNewFiles else { return .failure(.tooBig(added.count)) }
        let known = git(["ls-files", "-z", "--modified", "--deleted"])
        guard known.ok else { return .failure(.failed(known.error)) }
        let paths = Array(Set(added + CheckpointStore.nulSeparated(known.data)))
        if !paths.isEmpty {
            let updated = git(["update-index", "-z", "--add", "--remove", "--stdin"], input: CheckpointStore.nulJoined(paths))
            guard updated.ok else { return .failure(.failed(updated.error)) }
        }
        let tree = git(["write-tree"])
        guard tree.ok else { return .failure(.failed(tree.error)) }
        let now = Date()
        let message = name.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\0", with: "") + "\n\nkind: \(kind.rawValue)\n"
        let commit = git(["commit-tree", tree.text.trimmingCharacters(in: .whitespacesAndNewlines), "-m", message], date: now)
        guard commit.ok else { return .failure(.failed(commit.error)) }
        let hash = commit.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var id = String(format: "%013.0f", (now.timeIntervalSince1970 * 1000).rounded())
        if let last = readCheckpoints().first, last.id >= id { id = String(format: "%013.0f", (Double(last.id) ?? 0) + 1) }
        let named = git(["update-ref", "refs/checkpoints/" + id, hash])
        guard named.ok else { return .failure(.failed(named.error)) }
        prune()
        return .success(Checkpoint(id: id, commit: hash, name: name, date: now, kind: kind))
    }

    /// Keeps the newest `keepCount`; what only the older ones held is given back to the disk.
    private func prune() {
        let old = readCheckpoints().dropFirst(CheckpointStore.keepCount)
        guard !old.isEmpty else { return }
        for checkpoint in old { _ = git(["update-ref", "-d", "refs/checkpoints/" + checkpoint.id]) }
        // Tidying the store costs more than a checkpoint does, so it is done now and then.
        prunesSinceTidy += 1
        if prunesSinceTidy == 1 || prunesSinceTidy % 10 == 0 { _ = git(["gc", "--quiet", "--prune=now"]) }
    }

    enum CheckpointError: Error {
        case tooBig(Int), failed(String)

        var message: String {
            switch self {
            case .tooBig(let count):
                return "This folder has \(count) files that are not ignored, which is too many to keep checkpoints of. Open the project’s own folder instead of one that contains many projects."
            case .failed(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: - What changed (on the queue)

    private func snapshot(since checkpoint: Checkpoint) -> ActivitySnapshot {
        let started = Date()
        var changes: [String: ActivityChange] = [:]
        // Files the store knows: one call gives what happened to each ("raw") and its line counts ("numstat").
        let compared = git(["diff", "--raw", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-color", checkpoint.commit, "--"])
        if compared.ok {
            let fields = CheckpointStore.nulSeparated(compared.data)
            var index = 0
            while index < fields.count {
                let field = fields[index]
                if field.hasPrefix(":") {
                    // ":100644 100644 1234567 89abcde M" and the path in the next field.
                    guard index + 1 < fields.count, let status = field.last else { break }
                    let path = fields[index + 1]
                    changes[path] = ActivityChange(path: path, kind: status == "A" ? .created : (status == "D" ? .deleted : .changed))
                    index += 2
                } else {
                    let parts = field.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3 {
                        let path = String(parts[2])
                        changes[path]?.insertions = Int(parts[0])
                        changes[path]?.deletions = Int(parts[1])
                        if parts[0] == "-" { changes[path]?.isBinary = true }
                    }
                    index += 1
                }
            }
        }
        // Files made since the last checkpoint was taken: the store has never seen them.
        var fresh: [(path: String, date: Date?)] = newFiles().map { ($0, modificationDate(of: $0)) }
        fresh.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        for (position, entry) in fresh.enumerated() {
            if var existing = changes[entry.path] {
                // It was in the checkpoint, went away, and is back: that is a changed file.
                existing.kind = .changed
                changes[entry.path] = existing
                continue
            }
            var change = ActivityChange(path: entry.path, kind: .created)
            if position < CheckpointStore.maxCountedNewFiles {
                let counted = CheckpointStore.countLines(root.appendingPathComponent(entry.path))
                change.insertions = counted.lines
                change.deletions = counted.lines == nil ? nil : 0
                change.isBinary = counted.isBinary
            }
            changes[entry.path] = change
        }
        var list = Array(changes.values)
        for index in list.indices where list[index].kind != .deleted { list[index].modified = modificationDate(of: list[index].path) }
        list.sort { ($0.modified ?? .distantPast, $1.path) > ($1.modified ?? .distantPast, $0.path) }
        let unlisted = max(0, list.count - CheckpointStore.maxListedChanges)
        if unlisted > 0 { list.removeLast(unlisted) }
        return ActivitySnapshot(checkpoint: checkpoint, changes: list, unlisted: unlisted,
                                milliseconds: Date().timeIntervalSince(started) * 1000)
    }

    static func countLines(_ url: URL) -> (lines: Int?, isBinary: Bool) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return (nil, false) }
        if data.prefix(8192).contains(0) { return (nil, true) }
        var count = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes where byte == 0x0A { count += 1 }
        }
        if let last = data.last, last != 0x0A { count += 1 }
        return (count, false)
    }

    // MARK: - Undoing (on the queue)

    /// Puts files back as the checkpoint has them. `only` limits it to some files; `skipping` leaves files alone
    /// (ones with unsaved edits the user chose to keep). A checkpoint of how things are now is taken first.
    private func restore(to checkpoint: Checkpoint, only: Set<String>?, skipping: Set<String>) -> RestoreOutcome {
        var outcome = RestoreOutcome()
        let single = only?.count == 1 ? only?.first.map { ($0 as NSString).lastPathComponent } : nil
        let label = single.map { "Before restoring “\($0)”" } ?? "Before undoing changes"
        switch takeCheckpoint(name: label + " (" + CheckpointStore.clock(Date()) + ")", kind: .safety) {
        case .failure(let error):
            outcome.error = error.message
            return outcome
        case .success(let safety):
            outcome.safety = safety
            // Both are complete pictures now, so comparing them is exact and reads no file.
            let compared = git(["diff-tree", "-r", "-z", "--no-renames", "--name-status", checkpoint.commit, safety.commit])
            guard compared.ok else {
                outcome.error = compared.error
                return outcome
            }
            let fields = CheckpointStore.nulSeparated(compared.data)
            var toRestore: [String] = [], toTrash: [String] = []
            var index = 0
            while index + 1 < fields.count {
                let status = fields[index], path = fields[index + 1]
                index += 2
                if let only, !only.contains(path) { continue }
                if skipping.contains(path) { outcome.skipped.append(path); continue }
                if status == "A" { toTrash.append(path) } else { toRestore.append(path) }
            }
            // A new file goes to the Trash, where it can be found again; it is never deleted.
            for path in toTrash {
                let url = root.appendingPathComponent(path)
                do {
                    var landed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
                    outcome.trashed.append(path)
                    if let landed = landed as URL? { outcome.trashedURLs.append(landed) }
                    removeEmptyFolders(above: url)
                } catch {
                    outcome.skipped.append(path)
                }
            }
            if !toRestore.isEmpty {
                let checkedOut = git(["checkout", checkpoint.commit, "--pathspec-from-file=-", "--pathspec-file-nul"],
                                     input: CheckpointStore.nulJoined(toRestore))
                if checkedOut.ok { outcome.restored = toRestore } else { outcome.error = checkedOut.error }
            }
            return outcome
        }
    }

    /// A folder that held only files that were just moved to the Trash goes too, so the project looks as it did.
    private func removeEmptyFolders(above url: URL) {
        var folder = url.deletingLastPathComponent().standardizedFileURL
        while folder.path.hasPrefix(root.path + "/"), rmdir(folder.path) == 0 {
            folder = folder.deletingLastPathComponent()
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Comparing one file (on the queue, called by the diff tab)

    /// Both versions of one file and the blocks between them, in the shape the diff tab already draws.
    func loadDiff(path: String, since checkpoint: Checkpoint) -> Result<FileDiff, FileDiff.Problem> {
        let old = git(["show", checkpoint.commit + ":" + path])
        let oldData = old.ok ? old.data : Data()
        let newData = (try? Data(contentsOf: root.appendingPathComponent(path), options: .mappedIfSafe)) ?? Data()
        guard oldData.count <= FileDiff.maxBytes, newData.count <= FileDiff.maxBytes else { return .failure(.tooLarge) }
        guard !oldData.prefix(8192).contains(0), !newData.prefix(8192).contains(0) else { return .failure(.binary) }
        var diff = FileDiff()
        diff.oldLines = FileDiff.lines(of: oldData)
        diff.newLines = FileDiff.lines(of: newData)
        guard diff.oldLines.count <= FileDiff.maxLines, diff.newLines.count <= FileDiff.maxLines else { return .failure(.tooLarge) }
        if old.ok, !newData.isEmpty || FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            // Both exist. The file may be one the store has not seen since (made after the last checkpoint), so
            // the two are compared as plain files rather than through the store's list of files.
            let result = git(["diff", "--no-color", "--no-ext-diff", "-U0", checkpoint.commit, "--", path])
            guard result.ok else { return .failure(.failed(result.error.trimmingCharacters(in: .whitespacesAndNewlines))) }
            let (header, hunks) = FileDiff.parse(result.data)
            let text = String(decoding: header, as: UTF8.self)
            if text.contains("\nBinary files ") { return .failure(.binary) }
            // The store can believe a file is gone or new when it is neither (it left and came back between two
            // checkpoints); its blocks would not line up with the two texts, so the file is shown as one block.
            let lopsided = text.contains("\ndeleted file mode") || text.contains("\nnew file mode")
            diff.header = header
            diff.hunks = lopsided ? [] : hunks
            diff.canPatchBlocks = !diff.hunks.isEmpty
        }
        if diff.hunks.isEmpty, oldData != newData, !diff.canPatchBlocks {
            // A new file, a deleted file, or one git would not compare: it is one block.
            diff.hunks = [DiffHunk(oldStart: 0, oldCount: diff.oldLines.count, newStart: 0, newCount: diff.newLines.count, patch: Data())]
        }
        diff.insertions = diff.hunks.reduce(0) { $0 + $1.newCount }
        diff.deletions = diff.hunks.reduce(0) { $0 + $1.oldCount }
        return .success(diff)
    }

    /// Takes one block of changes back out of the file on disk. The comparison is made again first and the block
    /// must still be there exactly, because a patch without context lands wherever its line numbers say.
    func undoBlock(_ wanted: Data, path: String, since checkpoint: Checkpoint) -> GitResult {
        guard case .success(let fresh) = loadDiff(path: path, since: checkpoint), fresh.canPatchBlocks,
              let index = fresh.hunks.firstIndex(where: { $0.patch == wanted }),
              let block = FileDiff.standalone(fresh.hunks[index].patch, reversed: true) else {
            return GitResult(status: -1, output: "", error: "The file has changed since this comparison was made. It has been refreshed; try again.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("feather-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: file) }
        do { try (fresh.header + block).write(to: file) } catch {
            return GitResult(status: -1, output: "", error: error.localizedDescription)
        }
        let applied = git(["apply", "--unidiff-zero", "--whitespace=nowarn", file.path])
        return GitResult(status: applied.status, output: applied.text, error: applied.error)
    }

    /// The new-side line ranges (zero-based, half-open) that differ from the checkpoint, for follow mode's flash.
    private func changedLines(of path: String, since checkpoint: Checkpoint) -> [Range<Int>] {
        guard case .success(let diff) = loadDiff(path: path, since: checkpoint) else { return [] }
        return diff.hunks.map { $0.newStart..<($0.newStart + max($0.newCount, 1)) }
    }

    // MARK: - The main thread's side

    private func finish<T>(_ value: T, _ completion: @escaping (T) -> Void, listChanged: Bool = false) {
        let list = listChanged ? readCheckpoints() : nil
        DispatchQueue.main.async {
            if let list {
                self.checkpoints = list
                NotificationCenter.default.post(name: CheckpointStore.didChangeCheckpoints, object: self)
            }
            completion(value)
        }
    }

    /// Work made of several steps (the diff tab's load), in line with everything else.
    func perform<T>(_ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        queue.async { self.finish(work(), completion) }
    }

    func loadCheckpoints(completion: @escaping ([Checkpoint]) -> Void) {
        queue.async {
            _ = self.prepare()
            let list = self.readCheckpoints()
            DispatchQueue.main.async {
                self.checkpoints = list
                completion(list)
            }
        }
    }

    func newCheckpoint(name: String?, kind: Checkpoint.Kind, completion: @escaping (Result<Checkpoint, CheckpointError>) -> Void) {
        queue.async {
            let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = self.takeCheckpoint(name: (name?.isEmpty ?? true) ? "Before " + CheckpointStore.clock(Date()) : name ?? "", kind: kind)
            self.finish(result, completion, listChanged: true)
        }
    }

    /// The checkpoint a folder gets when it is opened, unless it already has one from the last hour.
    func takeAutomaticCheckpointIfDue(completion: @escaping (Checkpoint?) -> Void) {
        queue.async {
            _ = self.prepare()
            if let latest = self.readCheckpoints().first, Date().timeIntervalSince(latest.date) < 3600 {
                return self.finish(nil, completion, listChanged: true)
            }
            let result = self.takeCheckpoint(name: "Opened at " + CheckpointStore.clock(Date()), kind: .automatic)
            self.finish(try? result.get(), completion, listChanged: true)
        }
    }

    func changes(since checkpoint: Checkpoint, completion: @escaping (ActivitySnapshot) -> Void) {
        queue.async { self.finish(self.snapshot(since: checkpoint), completion) }
    }

    func changedLines(of path: String, since checkpoint: Checkpoint, completion: @escaping ([Range<Int>]) -> Void) {
        queue.async { self.finish(self.changedLines(of: path, since: checkpoint), completion) }
    }

    func restore(to checkpoint: Checkpoint, only: Set<String>? = nil, skipping: Set<String> = [],
                 completion: @escaping (RestoreOutcome) -> Void) {
        queue.async {
            let outcome = self.restore(to: checkpoint, only: only, skipping: skipping)
            self.finish(outcome, { outcome in
                NotificationCenter.default.post(name: CheckpointStore.didRestoreFiles, object: self)
                completion(outcome)
            }, listChanged: true)
        }
    }

    /// How much disk this project's checkpoints take.
    func diskUse(completion: @escaping (Int) -> Void) {
        queue.async {
            var total = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            if let walker = FileManager.default.enumerator(at: self.directory, includingPropertiesForKeys: keys) {
                for case let url as URL in walker {
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    if values?.isRegularFile == true { total += values?.totalFileAllocatedSize ?? 0 }
                }
            }
            self.finish(total, completion)
        }
    }

    /// Forgets every checkpoint of this project. The project's files are not touched.
    func clear(completion: @escaping () -> Void) {
        queue.async {
            try? FileManager.default.removeItem(at: self.directory)
            self.isReady = false
            self.finish((), completion, listChanged: true)
        }
    }
}
