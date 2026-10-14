import Cocoa
import Carbon
import IOKit.hid

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    @Published var currentLang: TISInputSource? = InputSourceUtils.getCurrentInputSource()
    @Published var isSecurityInput = false
    @Published var securityApp: String?
    @Published var hasAccessibility = AXIsProcessTrusted()
    @Published var globeKeyAvailable = false

    var isWaitingForSwitch = false
    var didFinishAppSetup = false
    var activeAppId: String?
    var activeAppInputSourceId: String?
    let clipboardHistory = ClipboardHistory()
    var permissionCheckTimer: Timer?
    // Safety net: if the input-source-changed notification never arrives, this fires
    // so isWaitingForSwitch can never latch on and permanently disable event handling.
    var switchWatchdog: Timer?

    // Keycodes of the current word; resets on word break (space → new char) or cancel.
    var wordRecord: [RecordedKey] = []
    // Keycodes since the last hard cancel (escape, enter, arrow, click, app change); spans multiple words.
    var lineRecord: [RecordedKey] = []
    // Snapshot of whichever record the current action fired on; consumed by onKeyboardInputSourceChanged.
    var pendingRecord: [RecordedKey] = []

    var text: String = ""

    // Learns which words the user does not want corrected. Holds all the state
    // and window logic; AppDelegate only forwards events to it.
    var autoSwitchSettleTimer: Timer?
    // The layout in use when the last correction fired, so a change back to it
    // can be recognised as a manual revert.
    var layoutBeforeAutoSwitch: Layout?
    // Layout changes we trigger without a user gesture (app activation restoring a
    // remembered language) must not be read by learning as the user reverting a correction.
    var programmaticLayoutChangeUntil = Date.distantPast

    // Word-delimited buffers used only by auto switch. wordRecord cannot serve
    // here: it resets on a space-then-character transition, so it happily
    // accumulates "it" + "." into "it." — which is exactly how "it." came to be
    // rewritten as "шею". These reset cleanly on every word terminator.
    struct TypedWord {
        // The word's keystrokes plus the terminator that ended it, so the run
        // can be replayed verbatim.
        var record: [RecordedKey]
        // The word itself, without the terminator.
        var text: String
    }
    var autoSwitchWord: [RecordedKey] = []
    var autoSwitchText: String = ""
    var autoSwitchTail: [TypedWord] = []
    let autoSwitchMaxPhraseWords = 4
    let autoSwitchMaxPhraseKeys = 28

    func showError(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(self)
    }

    func startPermissionPolling() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionCheckTimer = nil
                self.hasAccessibility = true
                self.requestInputMonitoringIfNeeded()
                self.globeKeyAvailable = KeyboardUtils.addGlobalEventListener(self.handleGlobalSystemEvent)
            }
        }
    }

    // Input Monitoring is a separate grant from Accessibility: without it the global monitor
    // delivers only modifier events, so typed words are never recorded. Asked for only once
    // Accessibility is granted, and through the system prompt alone, so there is never a second dialog.
    func requestInputMonitoringIfNeeded() {
        if !KeyboardUtils.hasInputMonitoringPermission {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    func requestAccessibilityPermissions() {
        // The system prompt (re)adds Babbler to the Accessibility list, switched off, and its
        // "Open System Settings" button goes straight there — so the user only flips the switch.
        // No dialog of our own: every call shows the system one, two at once is noise
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        startPermissionPolling()
    }

    func finishApplicationSetup() {
        if didFinishAppSetup { return }
        didFinishAppSetup = true

        KeyboardUtils.loadActionKeyFromPreferences()
        let error = InputSourceUtils.initInputSources()

        if error != nil {
            showError(error!, "")
            return
        }

        if preferenceStore.getAutoSwitchEnabled() {
            LayoutDictionary.shared.preload()
        }

        InputSourceUtils.onKeyboardInputSourceChanged {
            let wasOurs = self.isWaitingForSwitch
            self.currentLang = InputSourceUtils.getCurrentInputSource()
            // Notifications may arrive after focus moved. Attribute a layout only
            // when the tracked app is still in front.
            if let appId = self.activeAppId,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == appId,
               let source = self.currentLang {
              self.activeAppInputSourceId = source.id
              preferenceStore.rememberInputSource(source.id, for: appId)
            }

            replaceLog("lang changed → \(self.currentLang?.id ?? "nil") waiting=\(self.isWaitingForSwitch) pending=\(self.pendingRecord.map { $0.code })")
            self.completePendingSwitch()
            // Anything not driven by completePendingSwitch or an app activation was the user.
            if !wasOurs && Date() >= self.programmaticLayoutChangeUntil { self.noteLayoutChangedByUser() }
        }

        WorkspaceUtils.onActiveAppChanged { [weak self] app in
          guard let self else { return }
          self.refreshSecureInput()
          guard let appId = app.bundleIdentifier else { return }
          // Use the cached outgoing layout: macOS may already have selected the
          // incoming app's layout by the time the activation notification arrives.
          if let previousAppId = self.activeAppId, let sourceId = self.activeAppInputSourceId {
            preferenceStore.rememberInputSource(sourceId, for: previousAppId)
          }
          self.activeAppId = appId
          let availableIds = Set(InputSourceUtils.inputSources?.map { $0.id } ?? [])
          // Restoring a remembered language is not the user undoing a correction:
          // drop any open suspicion and ignore the layout notifications this causes.
          self.resetAutoSwitchLearningContext()
          if let sourceId = preferenceStore.inputSourceForActivation(appId, availableSourceIds: availableIds) {
            InputSourceUtils.switchLang(sourceId)
          }
          self.currentLang = InputSourceUtils.getCurrentInputSource()
          self.activeAppInputSourceId = self.currentLang?.id
          self.wordRecord = []
          self.lineRecord = []
          self.text = ""
          self.resetAutoSwitchBuffers()
        }

        currentLang = InputSourceUtils.getCurrentInputSource()
        // Everything above works without Accessibility (menu switcher, per-app sources);
        // key monitoring and text replacement need it
        if hasAccessibility {
            requestInputMonitoringIfNeeded()
            globeKeyAvailable = KeyboardUtils.addGlobalEventListener(handleGlobalSystemEvent)
        } else {
            requestAccessibilityPermissions()
        }
        if UserDefaults.standard.object(forKey: clipboardHistoryEnabledKey) == nil || UserDefaults.standard.bool(forKey: clipboardHistoryEnabledKey) {
            clipboardHistory.start()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    func refreshSecureInput() {
        let (isEnabled, appName) = SecurityInputUtils.checkSecureInput()
        if isSecurityInput != isEnabled { isSecurityInput = isEnabled }
        if securityApp != appName { securityApp = appName }
    }

    // Performs the pending text replacement exactly once. isWaitingForSwitch stays set
    // while synthetic keystrokes are posted so they are not recorded back into wordRecord,
    // and a watchdog guarantees it is always released even if something fails.
    func completePendingSwitch() {
        switchWatchdog?.invalidate()
        switchWatchdog = nil

        if !isWaitingForSwitch { return }

        let record = pendingRecord
        pendingRecord = []

        armWatchdog(2.0) { [weak self] in self?.finishSwitch() }

        if record.count > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: keyboardDelay)
                await KeyboardUtils.replaceTypedText(record)
                self.finishSwitch()
            }
        } else {
            KeyboardUtils.fetchSelectedText { text in
                if text.count > 0 { KeyboardUtils.typeText(text) }
                self.finishSwitch()
            }
        }
    }

    func finishSwitch() {
        switchWatchdog?.invalidate()
        switchWatchdog = nil
        isWaitingForSwitch = false
    }

    private func armWatchdog(_ interval: TimeInterval, _ action: @escaping () -> Void) {
        switchWatchdog?.invalidate()
        switchWatchdog = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in action() }
    }

    func beginSwitch(_ record: [RecordedKey]) {
        if preferenceStore.getIsTextReplaceEnabled() && !isSecurityInput {
            pendingRecord = record
            isWaitingForSwitch = true
            // If the input-source-changed notification never arrives, replace anyway.
            armWatchdog(0.5) { [weak self] in self?.completePendingSwitch() }
        }
        InputSourceUtils.swapLang()
    }

    // MARK: - Automatic layout switch

    private var currentLayout: Layout? {
        guard let source = InputSourceUtils.getCurrentInputSource() else { return nil }
        if InputSourceUtils.isRussian(source) { return .russian }
        if InputSourceUtils.isEnglish(source) { return .english }
        return nil
    }

    private func isAutoSwitchAllowedInCurrentApp() -> Bool {
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return !preferenceStore.getAutoSwitchExcludedApps().contains(bundleId)
    }

    /// A key that ends a word, so the word before it can now be judged.
    ///
    /// Only layout-independent keys qualify. Sentence punctuation must NOT be
    /// treated as a terminator: on the English layout `,` is б, `.` is ю, `;` is
    /// ж and `:` is Ж, so "бизнес" is typed as ",bpytc" and "работает" as
    /// "hf,jnftn". Splitting on those characters cuts a quarter of the Russian
    /// language in half and leaves fragments that match nothing.
    ///
    /// Waiting for the space costs nothing. A word followed by real punctuation
    /// is judged when the space arrives, and AutoSwitchEngine's
    /// trailing-punctuation rule is what tells "it." (a word plus a full stop)
    /// from "ndj." (твою) at that point.
    private func wordTerminator(for event: NSEvent) -> Bool {
        event.keyCode == Key.space
            || event.keyCode == Key.enter
            || event.keyCode == Key.returnKey
            || event.keyCode == Key.tab
    }

    /// Called on the keystroke that ends a word. Returns true if it triggered a
    /// correction, in which case the caller must stop processing the event.
    private func handleAutoSwitch(_ event: NSEvent) -> Bool {
        guard wordTerminator(for: event) else { return false }

        let word = autoSwitchText
        let record = autoSwitchWord + [RecordedKey(code: event.keyCode, flags: [])]
        // Whatever happens below, this word is finished.
        autoSwitchWord = []
        autoSwitchText = ""

        guard preferenceStore.getAutoSwitchEnabled(),
              preferenceStore.getIsTextReplaceEnabled(),
              !word.isEmpty,
              let layout = currentLayout,
              isAutoSwitchAllowedInCurrentApp() else {
            rememberTypedWord(record, word)
            return false
        }

        let normalized = AutoSwitchEngine.normalize(word)
        guard !autoSwitchMemory.shouldSkip(word: normalized),
              AutoSwitchEngine.evaluate(word: word, currentLayout: layout) == .switchLayout else {
            rememberTypedWord(record, word)
            return false
        }

        // Sweep up the short words just before this one. They were skipped on
        // their own because one and two letter words are ambiguous, but this
        // correction is the context that resolves them.
        //
        // Only an exact dictionary hit may anchor a sweep. A typo or language-model
        // match is a weaker signal, and letting it drag neighbouring words in would
        // multiply the error rather than contain it.
        let anchorIsExact = AutoSwitchEngine.isExactMatch(word: word, currentLayout: layout)
        let full = (anchorIsExact ? phrasePrefix(for: layout) : []) + record
        autoSwitchTail = []

        autoSwitchMemory.noteCorrection(word: normalized)
        layoutBeforeAutoSwitch = layout
        scheduleAutoSwitchSettle()

        // Leave the corrected run in wordRecord so pressing the action key right
        // after undoes it. The next typed character clears it as usual, because
        // the record now ends with the terminator.
        wordRecord = full
        text = ""

        beginSwitch(full)
        return true
    }

    private func rememberTypedWord(_ record: [RecordedKey], _ word: String) {
        guard !word.isEmpty else { return }
        autoSwitchTail.append(TypedWord(record: record, text: word))
        if autoSwitchTail.count > autoSwitchMaxPhraseWords {
            autoSwitchTail.removeFirst(autoSwitchTail.count - autoSwitchMaxPhraseWords)
        }
    }

    /// Keystrokes of the immediately preceding words that should be corrected
    /// along with the current one. Walks backwards and stops at the first word
    /// that does not clearly belong to the other layout.
    private func phrasePrefix(for layout: Layout) -> [RecordedKey] {
        var chosen: [[RecordedKey]] = []
        var keys = 0

        for unit in autoSwitchTail.reversed() {
            guard chosen.count < autoSwitchMaxPhraseWords,
                  keys + unit.record.count <= autoSwitchMaxPhraseKeys,
                  AutoSwitchEngine.qualifiesForPhraseExtension(word: unit.text, currentLayout: layout) else {
                break
            }
            chosen.append(unit.record)
            keys += unit.record.count
        }

        return chosen.reversed().flatMap { $0 }
    }

    func resetAutoSwitchBuffers() {
        autoSwitchWord = []
        autoSwitchText = ""
        autoSwitchTail = []
    }

    /// The app changed, so any open correction belongs to another context. The
    /// per-app language restore (and macOS's own switching) that follows must not
    /// look like the user reverting it.
    func resetAutoSwitchLearningContext() {
        programmaticLayoutChangeUntil = Date().addingTimeInterval(1.0)
        layoutBeforeAutoSwitch = nil
        autoSwitchSettleTimer?.invalidate()
        autoSwitchSettleTimer = nil
        autoSwitchMemory.noteContextChanged()
    }

    /// The action key pressed just after an automatic correction means the user
    /// disagreed. Counted immediately: it is an unambiguous undo.
    private func noteManualActionForUndo() {
        autoSwitchMemory.noteActionKey()
    }

    /// The input source changed while no correction of ours was in flight, so
    /// the user changed it. If it went back to the layout the last correction
    /// moved away from, that is a possible rejection — but only a possible one,
    /// because an edit may still follow and show the user was fixing their own
    /// text. AutoSwitchMemory holds it open until the suspicion window passes.
    private func noteLayoutChangedByUser() {
        guard let before = layoutBeforeAutoSwitch, currentLayout == before else { return }
        autoSwitchMemory.noteLayoutReverted()
        scheduleAutoSwitchSettle()
    }

    /// Runs the memory's window logic once the relevant deadline has passed.
    /// A pending rejection only commits from here, never from the event itself.
    private func scheduleAutoSwitchSettle() {
        autoSwitchSettleTimer?.invalidate()
        let delay = AutoSwitchMemory.suspicionWindow + 0.25
        autoSwitchSettleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            autoSwitchMemory.settlePending()
        }
    }

    func handleGlobalSystemEvent(_ event: NSEvent) {
        replaceLog("event \(event.type == .flagsChanged ? "flags" : event.type == .keyDown ? "down" : event.type == .keyUp ? "up" : "mouse") code=\(event.type == .leftMouseDown ? 0 : event.keyCode) chars=\(event.type == .keyDown ? event.characters ?? "" : "") flags=\(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) waiting=\(isWaitingForSwitch) synthetic=\(KeyboardUtils.isSynthetic(event))")
        // Our own replacement keystrokes leave the records unchanged: same keycodes deleted and retyped
        if isWaitingForSwitch || KeyboardUtils.isSynthetic(event) { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isLeftMouseDown = event.type == .leftMouseDown
        let code = isLeftMouseDown ? 0 : event.keyCode

        let withOption = flags.contains(.option)
        let withCommand = flags.contains(.command)
        let withActionModifier = flags.contains(KeyboardUtils.actionKeyFlag)
        let withGlobe = flags.contains(.function) || KeyboardUtils.isGlobeKeyHeld
        let isArrow = code == Key.leftArrow || code == Key.rightArrow || code == Key.upArrow || code == Key.downArrow
        let isEnter = code == Key.enter || code == Key.returnKey
        // Count Backspace once per keypress, including repeats.
        let isDelete = code == Key.delete && event.type == .keyDown
        let isRecordCanceled = code == Key.escape || code == Key.tab || isArrow || isEnter || isLeftMouseDown

        // checkActionKeyPress is stateful — call once only
        let actionResult = KeyboardUtils.checkActionKeyPress(code, flags)

        // Cached value is polled every 10 s, so refresh live: on action key (never block a swap),
        // on click (focus may move into or out of a secure field) and while secure
        // (first keystroke after secure input ends must be recorded, not dropped)
        if actionResult != .none || isLeftMouseDown || isSecurityInput {
            refreshSecureInput()
        }

        if actionResult != .none {
            replaceLog("ACTION \(actionResult) word='\(text)' wordCodes=\(wordRecord.map { $0.code }) lineCodes=\(lineRecord.map { $0.code }) lang=\(currentLang?.id ?? "nil")")
        }

        switch actionResult {
        case .action, .lineAction:
            // Text replacement is optional. Every action switches the input language,
            // including when no text has been typed or selected.
            noteManualActionForUndo()
            resetAutoSwitchBuffers()
            beginSwitch(actionResult == .lineAction ? lineRecord : wordRecord)
            return
        case .none:
            break
        }

        if isSecurityInput { return }

        // flagsChanged events (modifier key presses/releases) are fully handled by
        // checkActionKeyPress above. If we let them fall through, releasing Shift while
        // Option is still held would look like "Option + non-Option key" and wipe the records.
        if event.type == .flagsChanged { return }

        // A word just ended: judge it before the cancel/record bookkeeping below,
        // so terminators that reset the records (enter) are still covered.
        let endsWord = event.type == .keyDown && !event.isARepeat && wordTerminator(for: event)
        if endsWord, handleAutoSwitch(event) { return }

        // Erase both records on cancel or when a shortcut modifier is active
        if isRecordCanceled || (withOption && code != Key.option) || withCommand
            || (withActionModifier && code != KeyboardUtils.actionKeyCode)
            || (withGlobe && code != Key.function) {
            wordRecord = []
            lineRecord = []
            text = ""
            resetAutoSwitchBuffers()
            return
        }

        // Delete last symbol from both records
        if isDelete && wordRecord.count > 0 {
            wordRecord.removeLast()
            text = String(text.dropLast())
        }
        if isDelete && lineRecord.count > 0 {
            lineRecord.removeLast()
        }
        if isDelete && event.type == .keyDown {
            // Deleting after a correction means the user is reworking the text
            // themselves, so a layout revert around it is them fixing their own
            // mistake rather than rejecting ours. Text cannot be retyped without
            // deleting first, which is what makes this a reliable marker.
            autoSwitchMemory.noteTextEdited()
        }
        if isDelete {
            if autoSwitchWord.isEmpty {
                // Backspacing past the start of the current word: the phrase we
                // remembered no longer matches what is on screen.
                autoSwitchTail = []
            } else {
                autoSwitchWord.removeLast()
                autoSwitchText = String(autoSwitchText.dropLast())
            }
        }

        if code == Key.delete || event.type != .keyDown || event.isARepeat {
            return
        }

        let isWordBreak = wordRecord.last?.code == Key.space && event.keyCode != Key.space
        let appDidChange = WorkspaceUtils.checkCurrentApp()
        if isWordBreak || appDidChange {
            wordRecord = []
            text = ""
            if appDidChange {
                lineRecord = []
                resetAutoSwitchBuffers()
            }
        }

        // Save pressed key to both records
        let entry = RecordedKey(code: event.keyCode, flags: flags)
        wordRecord.append(entry)
        lineRecord.append(entry)
        text += event.characters ?? ""

        // The auto-switch buffer is word-delimited, so a terminator has already
        // been folded into the phrase tail by handleAutoSwitch and must not be
        // recorded again as the start of the next word.
        if !endsWord {
            autoSwitchWord.append(entry)
            autoSwitchText += event.characters ?? ""
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        CrashLogger.install()
        currentLang = InputSourceUtils.getCurrentInputSource()

        let bundleID = Bundle.main.bundleIdentifier!
        let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
        if running.count > 1 {
            NSApplication.shared.terminate(self)
            return
        }

        SecurityInputUtils.listenForSecurityInput { [weak self] _, _ in
            self?.refreshSecureInput()
        }

        finishApplicationSetup()
    }
}
