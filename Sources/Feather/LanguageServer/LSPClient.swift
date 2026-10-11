import Foundation

/// Resolves the PATH the user's login shell would have; GUI apps only inherit a minimal one.
final class ShellEnvironment {
    static let shared = ShellEnvironment()
    private(set) var pathDirectories: [String] = []
    private var isReady = false
    private var waiters: [() -> Void] = []

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathDirectories.joined(separator: ":")
        return env
    }

    func whenReady(_ body: @escaping () -> Void) {
        if isReady { body() } else { waiters.append(body) }
    }

    private static let cacheKey = "shellPathDirectories"

    /// Starting a login shell to read PATH takes a second or two with nvm or oh-my-zsh. The last answer is used
    /// straight away, so language servers can start immediately, and refreshed quietly a little after launch.
    func resolve() {
        if let cached = UserDefaults.standard.stringArray(forKey: ShellEnvironment.cacheKey), !cached.isEmpty {
            pathDirectories = cached
            isReady = true
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + (isReady ? 3 : 0)) {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            var directories = ShellEnvironment.loginShellPath()
            directories += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                            "\(home)/flutter/bin", "\(home)/.pub-cache/bin", "\(home)/.local/bin",
                            "\(home)/.cargo/bin", "\(home)/go/bin"]
            var seen = Set<String>()
            let unique = directories.filter { !$0.isEmpty && seen.insert($0).inserted }
            DispatchQueue.main.async {
                self.pathDirectories = unique
                UserDefaults.standard.set(unique, forKey: ShellEnvironment.cacheKey)
                self.isReady = true
                self.waiters.forEach { $0() }
                self.waiters = []
                Git.recheck()       // a Homebrew git on the login shell's PATH is only findable now
            }
        }
    }

    private static func loginShellPath() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "echo __FEATHER__${PATH}__FEATHER__"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        timeout.cancel()
        let parts = (String(data: data, encoding: .utf8) ?? "").components(separatedBy: "__FEATHER__")
        return parts.count >= 3 ? parts[1].split(separator: ":").map(String.init) : []
    }

    func find(_ executable: String) -> String? {
        if executable.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: executable) ? executable : nil
        }
        return pathDirectories.lazy.map { $0 + "/" + executable }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A JSON-RPC connection to one language server over stdio. Callbacks are delivered on the main queue.
final class LSPClient {
    var onNotification: ((String, [String: Any]) -> Void)?
    var onExit: (() -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writeQueue = DispatchQueue(label: "feather.lsp.write")
    private let readQueue = DispatchQueue(label: "feather.lsp.read")
    private var buffer = Data()
    private var nextID = 1
    private var callbacks: [Int: (Any?) -> Void] = [:]
    /// Work to do on a response before it reaches the main queue, by request id. Registered on the main queue and
    /// taken on the read queue, hence the lock.
    private var transforms: [Int: (Any?) -> Any?] = [:]
    private let transformLock = NSLock()

    init(executable: String, arguments: [String], environment: [String: String], directory: URL) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.readQueue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.callbacks.values.forEach { $0(nil) }
                self.callbacks = [:]
                self.transformLock.lock()
                self.transforms = [:]
                self.transformLock.unlock()
                self.onExit?()
            }
        }
        try process.run()
    }

    func stop() {
        onExit = nil
        if process.isRunning { process.terminate() }
    }

    /// `transform` runs on the read queue, so turning a large answer (a few thousand completion items) into model
    /// values does not hold up typing; `completion` then receives whatever it returned. The id is for `cancel`.
    @discardableResult
    func request(_ method: String, _ params: Any, transform: ((Any?) -> Any?)? = nil,
                 completion: @escaping (Any?) -> Void) -> Int {
        let id = nextID
        nextID += 1
        callbacks[id] = completion
        if let transform {
            transformLock.lock()
            transforms[id] = transform
            transformLock.unlock()
        }
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        return id
    }

    /// Tells the server to stop working on a request nobody is waiting for any more. Its callback is never called.
    func cancel(_ id: Int) {
        guard callbacks.removeValue(forKey: id) != nil else { return }
        transformLock.lock()
        transforms[id] = nil
        transformLock.unlock()
        notify("$/cancelRequest", ["id": id])
    }

    func notify(_ method: String, _ params: Any) {
        send(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// Opening a document (and every change, for a server without incremental sync) carries the whole text, so
    /// turning it into JSON is real work; it happens on the write queue, which is serial, so messages still go
    /// out in order.
    private func send(_ message: [String: Any]) {
        guard process.isRunning else { return }
        let handle = input.fileHandleForWriting
        writeQueue.async {
            guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
            var packet = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
            packet.append(body)
            try? handle.write(contentsOf: packet)
        }
    }

    // MARK: - Reading (readQueue)

    /// Internal rather than private so the framing can be tested without a server process.
    func consume(_ data: Data) {
        buffer.append(data)
        let separator = Data("\r\n\r\n".utf8)
        while let headerEnd = buffer.range(of: separator) {
            let header = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .ascii) ?? ""
            var length = 0
            for line in header.components(separatedBy: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].lowercased() == "content-length" {
                    length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let bodyStart = headerEnd.upperBound
            guard buffer.endIndex - bodyStart >= length else { return }
            let body = buffer.subdata(in: bodyStart..<bodyStart + length)
            buffer = buffer.subdata(in: bodyStart + length..<buffer.endIndex)
            if var message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
                if message["method"] == nil, let id = message["id"] as? Int {
                    transformLock.lock()
                    let transform = transforms.removeValue(forKey: id)
                    transformLock.unlock()
                    if let transform, message["error"] == nil { message["result"] = transform(message["result"]) }
                }
                DispatchQueue.main.async { self.dispatch(message) }
            }
        }
    }

    private func dispatch(_ message: [String: Any]) {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                // Server-to-client request: answer so the server never blocks waiting on us.
                var result: Any = NSNull()
                if method == "workspace/configuration",
                   let items = (message["params"] as? [String: Any])?["items"] as? [Any] {
                    result = items.map { _ in NSNull() }
                }
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } else {
                onNotification?(method, message["params"] as? [String: Any] ?? [:])
            }
        } else if let id = message["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
            callback(message["error"] == nil ? message["result"] : nil)
        }
    }
}
