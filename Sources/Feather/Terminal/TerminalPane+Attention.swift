import AppKit

/// What the pane tells the user: a terminal that finished or asked something, the header's status line,
/// and the "Copied" note.
extension TerminalPaneController {
    // MARK: - Finished, or asking something (TerminalWatch.swift)

    /// True when the user can see `session` right now: Feather is in front, its window is on screen, the pane is
    /// open and this is the terminal showing.
    private func isSeen(_ session: TerminalSession) -> Bool {
        guard TerminalAttention.shared.isAppActive(), visibleSessions.contains(where: { $0 === session }), isViewLoaded,
              let window = view.window else { return false }
        return window.isVisible && !window.isMiniaturized && !view.isHiddenOrHasHiddenAncestor
    }

    /// A terminal went quiet after working, asked something, rang the bell, or its command finished.
    func sessionIsWaiting(_ session: TerminalSession, reason: TerminalSession.WaitReason) {
        guard Settings.shared.notifyWhenTerminalWaits, !session.needsAttention else { return }
        session.refreshProcessInfo()
        // An assistant that stopped may have changed files; the Activity side shows which (AssistantChanges.swift).
        if session.isAssistant || session.aiToolName != nil, let window = view.window {
            switch reason {
            case .quiet, .finished:
                NotificationCenter.default.post(name: .assistantDidStop, object: self, userInfo: [
                    "window": window, "name": session.speakerName, "since": Date(timeIntervalSinceReferenceDate: session.busySince)])
            default:
                break
            }
        }
        let place = projectRoot?.lastPathComponent ?? session.detail
        let inPlace = place.isEmpty ? "" : " in \(place)"
        let note: TerminalAttention.Note
        switch reason {
        case .quiet:
            note = .init(token: session.token, title: "\(session.speakerName) is done\(inPlace)",
                         body: "It has stopped: it is finished, or it needs you.")
        case .question(let line):
            note = .init(token: session.token, title: "\(session.speakerName) is asking something\(inPlace)",
                         body: String(line.prefix(160)))
        case .bell:
            note = .init(token: session.token, title: "\(session.speakerName) wants your attention\(inPlace)", body: "")
        case .finished(let code):
            let outcome = code.map { $0 == 0 ? "finished" : "failed (exit code \($0))" } ?? "finished"
            note = .init(token: session.token, title: "Command \(outcome)\(inPlace)",
                         body: session.customName.map { "In the terminal “\($0)”." } ?? "")
        }
        tell(session, note)
    }

    /// A Run task's program ended. Told the same way as an assistant that stopped: it may have taken a while.
    func taskEnded(_ session: TerminalSession, outcome: String, failed: Bool) {
        guard Settings.shared.notifyWhenTerminalWaits else { return }
        let place = projectRoot?.lastPathComponent ?? session.detail
        let note = TerminalAttention.Note(token: session.token, title: "\(session.name) \(outcome)" + (place.isEmpty ? "" : " in \(place)"),
                                          body: failed ? "The output is in the terminal." : "")
        tell(session, note)
    }

    /// In view: a card in the corner and a sound, nothing more. Out of view (Feather behind another app, the
    /// window minimised, the panel hidden, another terminal showing): a notification, the Dock badge and the
    /// dot on the row, cleared when the user comes back to it.
    private func tell(_ session: TerminalSession, _ note: TerminalAttention.Note) {
        let reveal = { [weak self, weak session] in
            guard let self, let session, let index = self.sessions.firstIndex(where: { $0 === session }) else { return }
            self.select(index)
            self.onRevealRequested?()
            self.focus()
        }
        if isSeen(session) {
            TerminalAttention.shared.mention(note, in: view.window, onClick: reveal)
            return
        }
        session.needsAttention = true
        refreshListRows()
        TerminalAttention.shared.raise(note, in: view.window, onClick: reveal)
    }

    /// Called whenever the user may have come back: a terminal selected or focused, the pane shown, the window
    /// or the app brought to the front.
    func clearAttentionIfSeen() {
        strip.refresh()
        let seen = visibleSessions.filter { $0.needsAttention && isSeen($0) }
        guard !seen.isEmpty else { return }
        for session in seen {
            session.needsAttention = false
            TerminalAttention.shared.lower(token: session.token)
        }
        refreshListRows()
    }

    // MARK: - The header's line (TerminalStatus.swift)

    /// What the terminal in front is doing, for the strip; nil when nothing worth a word.
    func statusInput() -> TerminalStatusInput? {
        guard let session = current, session.isRunning else { return nil }
        let now = CFAbsoluteTimeGetCurrent()
        var input = TerminalStatusInput()
        if session.isAssistant {
            input.assistantName = session.aiToolName ?? AITools.toolName(processName: session.processName, title: session.programTitle) ?? session.name
            input.isBusy = session.isBusy
            input.secondsWithOutput = session.secondsWithOutput
            input.busySeconds = now - session.busySince
            if let reason = session.waitingReason {
                input.isWaiting = true
                if case .quiet = reason { input.workedSeconds = session.workedSeconds }
            }
            return input
        }
        if session.commandStartedAt > 0 {
            // The line as typed; failing that, the program the poll sees in the foreground.
            if let command = session.commandText ?? (session.isAtShellPrompt ? nil : session.processName) {
                input.command = command
                input.commandSeconds = now - session.commandStartedAt
                return input
            }
        }
        if let ending = session.lastEnding {
            input.ending = .init(exitCode: ending.exitCode, seconds: ending.seconds, age: now - ending.at)
        }
        return input
    }

    // MARK: - "Copied"

    /// "Copied 3 lines (240 characters)" in the corner of the terminal for a moment, as a sign the copy happened.
    func showCopied(_ text: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        let characters = text.count
        let what = lines > 1 ? "\(lines) lines (\(characters) characters)" : "\(characters) character\(characters == 1 ? "" : "s")"
        let toast = copiedToast ?? {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.cornerRadius = 6
            label.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(label)
            NSLayoutConstraint.activate([
                label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
                label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                label.heightAnchor.constraint(equalToConstant: 24),
            ])
            copiedToast = label
            return label
        }()
        let theme = Settings.shared.theme
        toast.attributedStringValue = NSAttributedString(string: "  Copied \(what)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium), .foregroundColor: theme.isDark ? NSColor.white : NSColor.black])
        toast.layer?.backgroundColor = Settings.shared.terminalListIcon.withAlphaComponent(0.85).cgColor
        toast.alphaValue = 1
        toast.isHidden = false
        content.addSubview(toast, positioned: .above, relativeTo: nil)          // over the terminal that was just selected
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak toast] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; toast?.animator().alphaValue = 0 }) { toast?.isHidden = true }
        }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }
}
