import AppKit

// A language server that dies mid-write must not take the editor down with it.
signal(SIGPIPE, SIG_IGN)
// `Feather --reset` from a terminal: the way back to a first install when the app itself will not come up.
if CommandLine.arguments.contains("--reset") {
    FeatherReset.perform()
    print("Feather's settings, saved session and caches were reset. Open Feather again to start fresh.")
    exit(0)
}
DefaultsMigration.run()            // before anything reads a setting
ShellEnvironment.shared.resolve()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
    AppUpdater.shared.start()
}
app.run()
