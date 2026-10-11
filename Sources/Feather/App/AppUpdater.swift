import AppKit
import Sparkle

/// In-app updates through Sparkle. Only a release build has a feed URL in its Info.plist (see build.sh), so a
/// development build, or the bare binary run from .build, never looks for updates or offers to replace itself.
///
/// An update marked critical in the feed (`release.sh --critical`, for a bad bug) is a *required* update: Sparkle
/// shows it at once, without Skip, every window carries an "Update required" card until it is installed, and the
/// download starts by itself so Install needs no wait. A `minimumAutoupdateVersion` in the feed makes a
/// *major* update: shown with its notes rather than installed quietly.
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?
    /// The required update the feed offered, when there is one; windows show a card for it.
    private(set) var requiredUpdate: SUAppcastItem?
    /// Posted on the main queue when a required update is found; the object is the updater.
    static let requiredUpdateFound = Notification.Name("FeatherRequiredUpdateFound")
    /// `defaults write com.aagicorp.feather updateFeedOverride http://localhost:8765/appcast.xml`: the update lab
    /// (tools/update-lab.sh) points a build at a feed on this Mac. Only a local address is honoured; every update
    /// is still checked against the public key inside the app, so nothing unsigned can ever be installed.
    static let feedOverrideKey = "updateFeedOverride"

    var isAvailable: Bool { controller != nil }

    func start() {
        let info = Bundle.main.infoDictionary ?? [:]
        guard controller == nil, Bundle.main.bundleIdentifier != nil,
              let feed = info["SUFeedURL"] as? String, AppUpdater.isAcceptableFeed(feed),
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty else { return }
        // Sparkle checks once a day in the background, verifies the download against the public key above, and
        // asks before installing anything.
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        if CommandLine.arguments.contains("--check-updates-now") { controller?.updater.checkForUpdates() }
    }

    /// The feed baked into a release is https; the update lab's build points at this Mac.
    static func isAcceptableFeed(_ feed: String) -> Bool {
        feed.hasPrefix("https://") || feed.hasPrefix("http://localhost") || feed.hasPrefix("http://127.0.0.1")
    }

    /// An override is taken only from this Mac, never from somewhere on the internet.
    static func acceptedOverride(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.hasPrefix("http://localhost") || value.hasPrefix("http://127.0.0.1") else { return nil }
        return value
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = "This is a development build"
            alert.informativeText = "Updates are delivered to the released version of Feather only."
            alert.runModal()
            return
        }
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? true
    }

    // MARK: - What kind of update it is

    enum Policy: Equatable { case required, major, normal }

    /// Required outranks major: a critical fix is installed even when it is also a big version jump.
    static func policy(isCritical: Bool, isMajor: Bool) -> Policy {
        if isCritical { return .required }
        return isMajor ? .major : .normal
    }

    /// The card every window shows for a required update.
    static func requiredUpdateText(version: String) -> String {
        "Feather \(version) fixes a serious problem and needs to be installed. It takes a moment and your windows come back as they are."
    }

    // MARK: - SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        AppUpdater.acceptedOverride(UserDefaults.standard.string(forKey: AppUpdater.feedOverrideKey))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        guard AppUpdater.policy(isCritical: item.isCriticalUpdate, isMajor: item.isMajorUpgrade) == .required else { return }
        requiredUpdate = item
        // A required update is downloaded as soon as it is seen, so Install needs no wait.
        updater.automaticallyDownloadsUpdates = true
        NotificationCenter.default.post(name: AppUpdater.requiredUpdateFound, object: self)
    }

    // A required update is downloaded in the background and installs at the next quit, or at once when the person
    // presses Install Now; Feather never quits itself to install, since that would interrupt unsaved work.

}

/// Feather's bundle identifier changed when it got a real one for distribution. Settings, the recent folders and
/// the saved session are copied over once, so nobody who used an earlier build starts from nothing.
enum DefaultsMigration {
    private static let oldDomain = "local.feather.editor"
    private static let doneKey = "migratedFromLocalDomain"

    static func run() {
        let defaults = UserDefaults.standard
        guard let current = Bundle.main.bundleIdentifier, current != oldDomain, !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)
        guard let old = defaults.persistentDomain(forName: oldDomain), !old.isEmpty else { return }
        // Anything already chosen in the new build wins.
        let existing = defaults.persistentDomain(forName: current) ?? [:]
        for (key, value) in old where existing[key] == nil && !key.hasPrefix("NS") && !key.hasPrefix("SU") {
            defaults.set(value, forKey: key)
        }
    }
}
