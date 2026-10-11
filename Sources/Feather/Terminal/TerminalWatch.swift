import AppKit
import UserNotifications

/// How busy one terminal has been. Fed on every chunk of output, so it holds numbers and nothing else: no text
/// is looked at until the terminal has gone quiet, and then only its last line.
struct TerminalActivity {
    /// True from the first output after a quiet spell until the quiet check has run.
    private(set) var isArmed = false
    private(set) var burstStart: CFAbsoluteTime = 0
    private(set) var lastOutput: CFAbsoluteTime = 0
    private(set) var bytes = 0

    /// How many different seconds of the clock had output in them. A program that was working printed in most
    /// of them; one line every few seconds (a server's log, a prompt redrawn after a resize) never adds up.
    private(set) var secondsWithOutput = 0
    private var lastSecond = 0
    /// Output in this many separate seconds, then silence, means "done" rather than "echoed a keystroke".
    static let minimumBusySeconds = 3

    /// Returns true when this output starts a new burst, which is when the caller schedules the quiet check.
    mutating func noteOutput(_ count: Int, at now: CFAbsoluteTime) -> Bool {
        lastOutput = now
        bytes += count
        let second = Int(now)
        if second != lastSecond { lastSecond = second; secondsWithOutput += 1 }
        if isArmed { return false }
        isArmed = true
        burstStart = now
        return true
    }

    /// The user typed. What follows is the answer to that, so the burst is measured from here: the echo of a
    /// long command line is not "activity".
    mutating func noteInput(at now: CFAbsoluteTime) {
        burstStart = now
        bytes = 0
        secondsWithOutput = 0
    }

    /// Busy for long enough, and for most of that time: not three lines spread over a minute.
    var wasBusy: Bool {
        secondsWithOutput >= TerminalActivity.minimumBusySeconds
            && Double(secondsWithOutput) >= (lastOutput - burstStart) * 0.5
    }

    mutating func disarm() {
        isArmed = false
        bytes = 0
        secondsWithOutput = 0
    }
}

/// Recognises a last line that is a question for the user.
enum TerminalPrompt {
    private static let endings = ["?", "(y/n)", "[y/n]", "(yes/no)", "[yes/no]", "(y/n):", "[y/n]:", "?:", "? ›", "(y)es/(n)o"]
    /// "❯ 1. Yes", "› 2) No", "● Yes, allow once", "> [ ] option": the row a selection menu has its marker on.
    private static let menu = try! NSRegularExpression(
        pattern: #"^[\s│|]*[❯›●▶➤>]\s*(?:\d+[.)]\s|\[[ xX]\]\s|\(\s?[ xX*]?\s?\)\s|(?:Yes|No|Allow|Deny|Accept|Reject)\b)"#)

    static func isQuestion(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return false }
        return endings.contains { trimmed.hasSuffix($0) }
    }

    static func isMenuRow(_ line: String) -> Bool {
        guard line.utf16.count < 400 else { return false }
        return menu.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) != nil
    }
}

/// Finds the address of a web server started in a terminal ("Local: http://localhost:5173/"). It sees every
/// chunk of output, so the chunk is only searched for two short byte strings (a vectorised `memmem`); text is
/// decoded for the rare completed line that contains one, and at most `linesPerSecond` of those.
struct LocalURLDetector {
    private var carry: [UInt8] = []
    private var seen = Set<String>()
    private var windowStart: CFAbsoluteTime = 0
    private var linesThisWindow = 0
    private var rateWindowStart: CFAbsoluteTime = 0
    private var rateWindowBytes = 0
    private static let floodBytes = 32 * 1024

    static let maxLineLength = 1024
    private static let maxCarry = 512
    private static let linesPerSecond = 40
    private static let needles: [[UInt8]] = [Array("http".utf8), Array("started on port".utf8)]

    private static let escapes = try! NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;:?<=>]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[()][0-9A-Za-z]")
    private static let address = try! NSRegularExpression(
        pattern: #"(https?)://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(:\d{1,5})?(/[^\s"'<>`\\│|]*)?"#, options: [.caseInsensitive])
    /// Spring Boot names the port but prints no address.
    private static let springBoot = try! NSRegularExpression(
        pattern: #"(?:Tomcat|Netty|Jetty|Undertow) started on port(?:\(s\))?:? (\d{2,5})(?: \((https?)\))?(?:.*?with context path '([^']*)')?"#)

    /// The new local addresses in the lines this chunk completed, each reported once per detector.
    mutating func scan(_ slice: ArraySlice<UInt8>, at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [URL] {
        guard !slice.isEmpty else { return [] }
        // A pty hands over a flood a few bytes at a time, a million times over, so during one even a `memmem`
        // per chunk adds up. A server announcing its address is never a flood: above `floodBytes` in a tenth
        // of a second nothing is searched at all, and what is left is this arithmetic.
        if now - rateWindowStart > 0.1 { rateWindowStart = now; rateWindowBytes = 0 }
        rateWindowBytes += slice.count
        if rateWindowBytes > LocalURLDetector.floodBytes {
            if !carry.isEmpty { carry = [] }
            return []
        }
        if carry.isEmpty {
            return slice.withUnsafeBytes { scan($0, at: now) }
        }
        var joined = carry
        joined.append(contentsOf: slice)
        carry = []
        return joined.withUnsafeBytes { scan($0, at: now) }
    }

    private mutating func scan(_ bytes: UnsafeRawBufferPointer, at now: CFAbsoluteTime) -> [URL] {
        guard let base = bytes.baseAddress else { return [] }
        let count = bytes.count
        // The unfinished last line waits for its newline. Only the last few hundred bytes are searched for one:
        // a longer line than that is not a "Local: http://…" line.
        var lineEnd = count
        let floor = max(0, count - LocalURLDetector.maxCarry)
        while lineEnd > floor, bytes[lineEnd - 1] != 10 { lineEnd -= 1 }
        if lineEnd > floor || lineEnd == 0 {
            if count - lineEnd > 0 { carry = Array(bytes[lineEnd..<count]) }
        } else {
            lineEnd = count           // no newline near the end: the tail is too long to be worth keeping
        }
        guard lineEnd > 0 else { return [] }

        var found: [URL] = []
        for needle in LocalURLDetector.needles {
            var offset = 0
            while offset < lineEnd, let hit = memmem(base + offset, lineEnd - offset, needle, needle.count) {
                let position = base.distance(to: UnsafeRawPointer(hit))
                var start = position
                let lowest = max(0, position - LocalURLDetector.maxLineLength / 2)
                while start > lowest, bytes[start - 1] != 10 { start -= 1 }
                var end = position
                let highest = min(lineEnd, position + LocalURLDetector.maxLineLength / 2)
                while end < highest, bytes[end] != 10 { end += 1 }
                offset = end + 1
                guard allowAnotherLine(at: now) else { return found }
                let line = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
                for url in LocalURLDetector.addresses(in: line) {
                    var key = url.absoluteString
                    if key.hasSuffix("/") { key.removeLast() }
                    if seen.insert(key).inserted { found.append(url) }
                }
            }
        }
        return found
    }

    private mutating func allowAnotherLine(at now: CFAbsoluteTime) -> Bool {
        if now - windowStart >= 1 { windowStart = now; linesThisWindow = 0 }
        linesThisWindow += 1
        return linesThisWindow <= LocalURLDetector.linesPerSecond
    }

    /// The local addresses in one line of output, colour codes and all. `0.0.0.0` and `[::]` mean "every
    /// interface", which a browser reaches as localhost.
    static func addresses(in rawLine: String) -> [URL] {
        var line = rawLine
        if line.contains("\u{1B}") {
            line = escapes.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: line.utf16.count), withTemplate: "")
        }
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var urls: [URL] = []
        func part(_ match: NSTextCheckingResult, _ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        for match in address.matches(in: line, range: whole) {
            var host = (part(match, 2) ?? "localhost").lowercased()
            if host == "0.0.0.0" || host == "[::]" { host = "localhost" }
            var path = part(match, 4) ?? ""
            while let last = path.last, ".,;:!?)]}'*".contains(last) { path.removeLast() }
            let text = (part(match, 1) ?? "http").lowercased() + "://" + host + (part(match, 3) ?? "") + path
            if let url = URL(string: text) { urls.append(url) }
        }
        if urls.isEmpty, let match = springBoot.firstMatch(in: line, range: whole), let port = part(match, 1) {
            let text = (part(match, 2) ?? "http") + "://localhost:" + port + (part(match, 3) ?? "")
            if let url = URL(string: text) { urls.append(url) }
        }
        return urls
    }
}

extension Notification.Name {
    /// A terminal printed the address of a local web server. `userInfo`: "url" (URL) and "window" (NSWindow).
    /// Posted once per distinct address per terminal.
    static let terminalDidDetectURL = Notification.Name("FeatherTerminalDidDetectURL")
}

// MARK: - Telling the user

/// Terminals that want the user: the Dock badge, the macOS notifications, and the way back from a click on one.
final class TerminalAttention: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalAttention()

    struct Note {
        /// Identifies the terminal; also the notification's identifier, so it can be withdrawn.
        let token: String
        let title: String
        let body: String
    }

    /// Whether the user is in Feather. A property so tests can say "they are elsewhere".
    var isAppActive: () -> Bool = { NSApp.isActive }
    /// Shows a note to the user. Tests replace it; the default posts a macOS notification.
    lazy var poster: (Note) -> Void = { [weak self] in self?.postToSystem($0) }

    private var reveal: [String: () -> Void] = [:]
    private var isDelegateInstalled = false

    /// `onClick` brings that terminal to the front. `window` is where a card goes when macOS notifications are
    /// off for Feather (or there is no bundle to ask): the user is still told, inside the window.
    func raise(_ note: Note, in window: NSWindow?, onClick: @escaping () -> Void) {
        reveal[note.token] = onClick
        updateBadge()
        playSound()
        fallbackWindows[note.token] = window
        poster(note)
    }

    /// The user is looking at the terminal, so no notification and no badge: a card in the corner of the window
    /// that goes away by itself, and the sound. "Done" is worth a glance even when the terminal is in view.
    func mention(_ note: Note, in window: NSWindow?, onClick: @escaping () -> Void) {
        playSound()
        showCard(note, in: window, onClick: onClick)
    }

    private var fallbackWindows: [String: NSWindow] = [:]

    private func playSound() {
        guard Settings.shared.terminalSound, CFAbsoluteTimeGetCurrent() - lastSound > 1 else { return }
        lastSound = CFAbsoluteTimeGetCurrent()
        NSSound(named: "Glass")?.play()
    }
    private var lastSound: CFAbsoluteTime = 0

    /// A card in the bottom-right corner of the window, gone after a few seconds or a click.
    private func showCard(_ note: Note, in window: NSWindow?, onClick: @escaping () -> Void) {
        guard let window else { return }
        let text = note.body.isEmpty ? note.title : note.title + "\n" + note.body
        let card = NoticeCard(kind: "terminal", symbol: "terminal", text: text,
                              actions: [.init(title: "Show", isProminent: true, run: onClick)], dismissTitle: "OK")
        WindowNotices.show(card, in: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak card] in card?.remove() }
    }

    /// The user has seen the terminal (or it is gone).
    func lower(token: String) {
        fallbackWindows.removeValue(forKey: token)
        guard reveal.removeValue(forKey: token) != nil else { return }
        updateBadge()
        if let center { center.removeDeliveredNotifications(withIdentifiers: [token]) }
    }

    var waitingCount: Int { reveal.count }

    private func updateBadge() {
        NSApp.dockTile.badgeLabel = reveal.isEmpty ? nil : String(reveal.count)
    }

    /// The notification centre needs an app bundle; a bare binary (a debug run) has none and must not ask for it.
    /// Tests turn this off too: the test runner has a bundle, but no notification centre to speak of.
    var hasNotificationCenter = Bundle.main.bundleIdentifier != nil
    private var center: UNUserNotificationCenter? { hasNotificationCenter ? UNUserNotificationCenter.current() : nil }

    /// Permission is asked for here, the first time there is something to say, not at launch. Refused (or no
    /// bundle to ask with), the note becomes a card in the window instead, so it is never simply lost.
    private func postToSystem(_ note: Note) {
        guard let center else { return inWindow(note) }
        if !isDelegateInstalled {
            isDelegateInstalled = true
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else { return DispatchQueue.main.async { self?.inWindow(note) } }
            let content = UNMutableNotificationContent()
            content.title = note.title
            content.body = note.body
            // The sound was played by `raise` already; a second one from the notification would double it.
            content.sound = Settings.shared.terminalSound ? nil : .default
            center.add(UNNotificationRequest(identifier: note.token, content: content, trigger: nil))
        }
    }

    private func inWindow(_ note: Note) {
        let window = fallbackWindows.removeValue(forKey: note.token)
        guard let onClick = reveal[note.token] else { return }
        showCard(note, in: window, onClick: onClick)
    }

    /// Feather may be in front with the terminal hidden; the note is still worth showing.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let token = response.notification.request.identifier
        DispatchQueue.main.async { [weak self] in
            self?.clicked(token: token)
            completionHandler()
        }
    }

    /// What a click on the notification does; also how tests click one.
    func clicked(token: String) {
        NSApp.activate(ignoringOtherApps: true)
        reveal[token]?()
    }
}
