import Cocoa
import AVFoundation
import IOKit.hid

// MARK: - Settings

enum Build {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

enum Defaults {
    static let language = "language"
    static let history = "history"
    static let cornerButton = "cornerButton"
    static let insertAtEnd = "insertAtEnd"
    static let clickToInsert = "clickToInsert"
    static let trigger = "trigger"
    static let singleTap = "singleTap"
    static let gestureMode = "gestureMode"
    static let didShowSetup = "didShowSetup"
    static let stopPhrase = "stopPhrase"
    static let pauseSeconds = "pauseSeconds"
    /// Master switch: enables the smart (Grok cleanup) trigger key.
    static let cleanupEnabled = "cleanupEnabled"
    /// Key used for smart dictation (must differ from `trigger`).
    static let cleanupTrigger = "cleanupTrigger"
    /// Learn unique personal terms into the local vocabulary file.
    static let vocabLearning = "vocabLearning"
    /// After paste, re-read the field and learn from hand edits.
    static let vocabLearnFromEdits = "vocabLearnFromEdits"
    /// Store recent transcripts in preferences (plaintext — optional).
    static let keepHistory = "keepHistory"

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "en",
            cornerButton: true,
            insertAtEnd: true,
            clickToInsert: true,
            // Right ⌥ by default — Control is reserved for Grok Build (⌃M, ⌃O, …).
            trigger: Trigger.rightOption.rawValue,
            singleTap: true,
            // Default stays single-tap; hold is opt-in via the Trigger menu.
            gestureMode: GestureMode.single.rawValue,
            stopPhrase: true,
            // Upstream 0.7: 5s default — 3s cut people off mid-thought.
            pauseSeconds: 5.0,
            cleanupEnabled: false,
            cleanupTrigger: Trigger.rightOption.rawValue,
            vocabLearning: true,
            vocabLearnFromEdits: true,
            keepHistory: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    /// Seconds of silence that end a dictation. 0 turns it off.
    static var pause: TimeInterval {
        UserDefaults.standard.double(forKey: pauseSeconds)
    }

    static var currentTrigger: Trigger {
        Trigger(rawValue: UserDefaults.standard.string(forKey: trigger) ?? "") ?? .rightCommand
    }

    static var smartTrigger: Trigger {
        let primary = currentTrigger
        let raw = UserDefaults.standard.string(forKey: cleanupTrigger) ?? ""
        let candidate = Trigger(rawValue: raw) ?? .rightOption
        // Never share a key with simple dictation.
        return candidate == primary ? primary.alternate(excluding: nil) : candidate
    }

    static var cleanupIsOn: Bool { bool(cleanupEnabled) }

    /// Prefer `gestureMode`; fall back to the older `singleTap` bool for installs
    /// that never wrote the new key.
    static var currentGesture: GestureMode {
        if let raw = UserDefaults.standard.string(forKey: gestureMode),
           let mode = GestureMode(rawValue: raw) {
            return mode
        }
        return bool(singleTap) ? .single : .double
    }

    static func setGesture(_ mode: GestureMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: gestureMode)
        // Keep the legacy flag in sync so older log lines / code paths stay honest.
        UserDefaults.standard.set(mode == .single, forKey: singleTap)
    }

    static func setPrimaryTrigger(_ option: Trigger) {
        UserDefaults.standard.set(option.rawValue, forKey: trigger)
        // If smart key collided, move it.
        if cleanupIsOn, smartTrigger == option {
            let alt = option.alternate(excluding: option)
            UserDefaults.standard.set(alt.rawValue, forKey: cleanupTrigger)
        }
    }

    static func setSmartTrigger(_ option: Trigger) {
        let primary = currentTrigger
        let chosen = option == primary ? option.alternate(excluding: primary) : option
        UserDefaults.standard.set(chosen.rawValue, forKey: cleanupTrigger)
    }

    static func flip(_ key: String) { UserDefaults.standard.set(!bool(key), forKey: key) }
}

// MARK: - App

final class QuillApp: NSObject, NSApplicationDelegate {

    private enum StopReason {
        case hotkey     // trigger key or the pill — focus has not moved
        case click      // you clicked into the target — give focus a beat to settle
        case voice      // you said "that's it" — focus has not moved either
        case hold       // push-to-talk release — focus has not moved
    }

    private let hotkey = DoubleTapRightCommand()
    private let recorder = Recorder()
    private let hud = HUD()
    private var stt: STTClient?

    private var statusItem: NSStatusItem!
    private var isRecording = false
    /// True when this recording was started by hold-to-talk (release will stop it).
    private var sessionFromHold = false
    /// Hold delay elapsed — release will insert. False while only primed (P0).
    private var holdCommitted = false
    /// This session should run Grok cleanup after STT (smart key).
    private var sessionUsesCleanup = false
    private var pendingPCM: [Data] = []
    private var socketReady = false
    private var sawAnyText = false
    private var stopReason: StopReason = .hotkey
    private var didRunVoiceCommand = false
    private var finaliseStartedAt: Date?
    private var pendingVoiceStop: DispatchWorkItem?
    private var lastStopCandidate: String?
    /// Mic-based pause-to-finish (upstream 0.7 — not transcript silence).
    private var pauseTimer: Timer?
    private var lastVoiceAt = Date()
    private var lastActivityText: String?
    private var noiseFloor: Float = 0.02
    private var capturedSelection: Inserter.Selection?
    private var startedAt: Date?

    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var tickTimer: Timer?
    private var trustTimer: Timer?
    private var isTrusted = false

    /// Watches the focused field after paste so hand-edits teach the dictionary.
    private let editWatch = PostInsertEditWatch()

    /// QUILL_SELFTEST=<file.pcm> replaces the microphone with a 16 kHz mono PCM16
    /// file, so the socket → transcript → insert path can be verified headlessly.
    private let selfTestPath = ProcessInfo.processInfo.environment["QUILL_SELFTEST"]
    private var selfTestTimer: Timer?
    private let setup = SetupWindow()

    /// Grok STT's own list, plus Chinese.
    ///
    /// Chinese is absent from the language table inside the grok CLI, but the
    /// service transcribes it correctly — verified against the live endpoint with
    /// `language=zh`, with the parameter omitted, and even with `language=en`.
    /// The underlying model is evidently multilingual and that table is a UI
    /// subset, so leaving Chinese out would have been an artificial limit.
    private let languages: [(String, String)] = [
        ("Auto-detect", "auto"),
        ("English", "en"),
        ("Arabic", "ar"), ("Chinese", "zh"), ("Czech", "cs"), ("Danish", "da"),
        ("Dutch", "nl"), ("Filipino", "fil"), ("French", "fr"), ("German", "de"),
        ("Hindi", "hi"), ("Indonesian", "id"), ("Italian", "it"), ("Japanese", "ja"),
        ("Korean", "ko"), ("Macedonian", "mk"), ("Malay", "ms"), ("Persian", "fa"),
        ("Polish", "pl"), ("Portuguese", "pt"), ("Romanian", "ro"), ("Russian", "ru"),
        ("Spanish", "es"), ("Swedish", "sv"), ("Thai", "th"), ("Turkish", "tr"),
        ("Vietnamese", "vi"),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Defaults.register()
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()

        hud.onClick = { [weak self] in
            guard let self else { return }
            // Without Accessibility the keyboard trigger is dead and only this pill
            // works — which reads as "the shortcut is broken". Make the pill the
            // route to fixing it rather than a dead end.
            guard Inserter.isTrusted else {
                self.setup.show()
                return
            }
            self.toggle(lane: .raw)
        }
        hud.showsIdlePill = Defaults.bool(Defaults.cornerButton)
        hud.install()

        applyTriggersAndGesture()
        // Hold mode only fires onHold*; onTrigger is for tap modes / pill / menu.
        hotkey.onTrigger = { [weak self] lane in
            guard let self else { return }
            // Never toggle from a "tap" while hold-to-talk is the active gesture.
            guard Defaults.currentGesture != .hold else {
                Log.write("ignore tap trigger — hold-only mode")
                return
            }
            self.toggle(lane: lane)
        }
        // P0: prime mic/HUD on key-down; commit only after hold delay.
        hotkey.onHoldArm = { [weak self] lane in self?.armHoldSession(lane: lane) }
        hotkey.onHoldStart = { [weak self] lane in self?.commitHoldSession(lane: lane) }
        hotkey.onHoldEnd = { [weak self] lane in self?.endHoldSession(lane: lane) }
        hotkey.onHoldCancel = { [weak self] _ in
            // Chord, short press, or release before commit — discard, don't insert.
            self?.cancelSession(announce: false)
        }
        hotkey.onClickAnywhere = { [weak self] point in self?.handleClickAnywhere(at: point) }
        hotkey.onCancel = { [weak self] in self?.cancelSession(announce: true) }

        isTrusted = Inserter.isTrusted
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let smartNote = Defaults.cleanupIsOn
            ? " smart=\(Defaults.smartTrigger.gesture(mode: Defaults.currentGesture))"
            : ""
        Log.write("launch — Quill \(Build.version) — AXIsProcessTrusted=\(isTrusted) inputMonitoring=\(inputMonitoring.rawValue) "
            + "trigger=\(Defaults.currentTrigger.gesture(mode: Defaults.currentGesture))"
            + smartNote
            + " bundle=\(Bundle.main.bundlePath)")

        hotkey.onFirstEvent = { Log.write("event tap is LIVE — first event delivered") }
        hotkey.start()

        hud.setNeedsPermission(!isTrusted)

        if !isTrusted {
            // macOS happily creates a keyboard tap without Accessibility and then
            // never delivers an event to it — so tap creation succeeding proves
            // nothing. Ask, then watch for the grant and re-arm.
            Inserter.requestTrust()
            hud.apply(.notice("Turn on Quill in Privacy & Security ▸ Accessibility"))
            hud.collapse(after: 6)
        }

        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.applyTriggersAndGesture()
            let now = Inserter.isTrusted
            guard now != self.isTrusted else { return }
            self.isTrusted = now
            self.hud.setNeedsPermission(!now)
            Log.write("Accessibility trust changed → \(now); re-arming event tap")
            self.hotkey.stop()
            self.hotkey.start()
            if now {
                self.hud.apply(.notice("Accessibility granted — \(Defaults.currentTrigger.gesture(mode: Defaults.currentGesture)) is live"))
                self.hud.collapse(after: 2.5)
            }
        }
        refreshIcon()

        // Built-in AI/coding-harness spellings (Grok, Claude, MCP, GGUF, …).
        // Merges once per seed version; never overwrites pinned user terms.
        _ = Vocabulary.ensureStandardSeed()

        if selfTestPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.toggle(lane: .raw) }
        } else {
            let firstRun = !Defaults.bool(Defaults.didShowSetup)
            let missingSomething = !Inserter.isTrusted || Auth.load() == nil
                || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
            if firstRun || missingSomething {
                UserDefaults.standard.set(true, forKey: Defaults.didShowSetup)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.setup.show()
                }
            }
        }
    }

    private var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private var loggedGestureMode: GestureMode?
    private var loggedSmartKey: String?

    private func applyTriggersAndGesture() {
        let mode = Defaults.currentGesture
        // Hold-only: never enable single/double tap paths that fire on key release.
        hotkey.holdToTalk = (mode == .hold)
        hotkey.singleTap = (mode == .single)
        if mode == .hold {
            hotkey.singleTap = false
        }
        hotkey.trigger = Defaults.currentTrigger
        hotkey.smartTrigger = Defaults.cleanupIsOn ? Defaults.smartTrigger : nil

        let smartKey = Defaults.cleanupIsOn ? Defaults.smartTrigger.rawValue : "off"
        let changed = loggedGestureMode != mode || loggedSmartKey != smartKey
        guard changed else { return }
        loggedGestureMode = mode
        loggedSmartKey = smartKey
        var line = "gesture mode: \(mode.rawValue) — raw \(Defaults.currentTrigger.gesture(mode: mode))"
        if Defaults.cleanupIsOn {
            line += " · smart \(Defaults.smartTrigger.gesture(mode: mode))"
        }
        Log.write(line)
    }

    private func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // MARK: Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        var tip = "Quill — \(Defaults.currentTrigger.gesture(mode: Defaults.currentGesture)) for simple dictation"
        if Defaults.cleanupIsOn {
            tip += " · \(Defaults.smartTrigger.gesture(mode: Defaults.currentGesture)) for cleaned"
        }
        button.toolTip = tip
    }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        rightClick ? showMenu() : toggle(lane: .raw)
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let name = isRecording ? "waveform.circle.fill" : "waveform"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Quill")
        button.image?.isTemplate = !isRecording
        button.contentTintColor = isRecording ? .systemRed : nil
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let versionItem = NSMenuItem(title: "Quill \(Build.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let account = Auth.load()
        let header = NSMenuItem(title: account.map { "Grok Build · \($0.email ?? "signed in")" }
                                    ?? "Grok Build · not signed in",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: isRecording ? "Stop dictation" : "Start dictation",
                                    action: #selector(menuToggleRaw), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let hint = NSMenuItem(title: "Simple: \(Defaults.currentTrigger.gesture(mode: Defaults.currentGesture))",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if Defaults.cleanupIsOn {
            let smartHint = NSMenuItem(
                title: "Cleaned: \(Defaults.smartTrigger.gesture(mode: Defaults.currentGesture))",
                action: nil, keyEquivalent: "")
            smartHint.isEnabled = false
            menu.addItem(smartHint)
        }
        menu.addItem(.separator())

        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        do {
            let recent = NSMenu()
            recent.autoenablesItems = false
            for (index, entry) in history.prefix(8).enumerated() {
                let title = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                recent.addItem(item)
            }
            recent.addItem(.separator())
            let clear = NSMenuItem(title: "Clear recent", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            recent.addItem(clear)
            let keep = NSMenuItem(title: "Keep recent transcripts",
                                  action: #selector(toggleKeepHistory), keyEquivalent: "")
            keep.target = self
            keep.state = Defaults.bool(Defaults.keepHistory) ? .on : .off
            keep.toolTip = "Stored in preferences as plain text. Turn off if you dictate anything private."
            recent.addItem(keep)

            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            menu.addItem(recentItem)
            menu.setSubmenu(recent, for: recentItem)
            menu.addItem(.separator())
        }

        addToggle(to: menu, title: "Click anywhere to insert", key: Defaults.clickToInsert,
                  action: #selector(toggleClickToInsert))
        addToggle(to: menu, title: "Insert at end of field", key: Defaults.insertAtEnd,
                  action: #selector(toggleInsertAtEnd))
        addToggle(to: menu, title: "Stop when I say \u{201C}that\u{2019}s it\u{201D} or \u{201C}that\u{2019}s all\u{201D}", key: Defaults.stopPhrase,
                  action: #selector(toggleStopPhrase))

        // Grok cleanup — separate key from simple dictation.
        let cleanupMenu = NSMenu()
        cleanupMenu.autoenablesItems = false
        addToggle(to: cleanupMenu, title: "Enable cleaned dictation key",
                  key: Defaults.cleanupEnabled, action: #selector(toggleCleanup))
        cleanupMenu.addItem(.separator())
        let smartKeyHeader = NSMenuItem(title: "Smart key (Grok cleanup)", action: nil, keyEquivalent: "")
        smartKeyHeader.isEnabled = false
        cleanupMenu.addItem(smartKeyHeader)
        let activeSmart = Defaults.smartTrigger
        let primary = Defaults.currentTrigger
        for option in Trigger.allCases {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(setSmartTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (option == activeSmart) ? .on : .off
            item.isEnabled = Defaults.cleanupIsOn && option != primary
            if option == primary {
                item.toolTip = "Already used for simple dictation — pick another key."
            } else {
                item.toolTip = "Hold/tap this key for STT + Grok cleanup."
            }
            cleanupMenu.addItem(item)
        }
        let cleanupItem = NSMenuItem(title: "Clean up with Grok", action: nil, keyEquivalent: "")
        menu.addItem(cleanupItem)
        menu.setSubmenu(cleanupMenu, for: cleanupItem)

        // Personal dictionary — unique terms only, local JSON on this Mac.
        let vocabMenu = NSMenu()
        vocabMenu.autoenablesItems = false
        let learnItem = NSMenuItem(title: "Learn unique terms while I dictate",
                                   action: #selector(toggleVocabLearning), keyEquivalent: "")
        learnItem.target = self
        learnItem.state = Vocabulary.learningEnabled ? .on : .off
        learnItem.toolTip = "Stores names, products, and jargon you use — not everyday English. "
            + "Cleanup uses this list to keep spellings consistent."
        vocabMenu.addItem(learnItem)

        let editItem = NSMenuItem(title: "Learn from my edits after paste",
                                  action: #selector(toggleVocabLearnFromEdits), keyEquivalent: "")
        editItem.target = self
        editItem.state = Vocabulary.learnFromEditsEnabled ? .on : .off
        editItem.toolTip = "After Quill inserts text, if you fix a word in an Accessibility-readable "
            + "field, that correction is added to the personal dictionary."
        vocabMenu.addItem(editItem)

        let seedItem = NSMenuItem(title: "Install standard AI / harness vocabulary",
                                  action: #selector(installStandardVocab), keyEquivalent: "")
        seedItem.target = self
        seedItem.toolTip = "Merge built-in spellings for Grok, Claude, MCP, GGUF, agents, etc. "
            + "Does not overwrite your pinned terms."
        vocabMenu.addItem(seedItem)

        let addItem = NSMenuItem(title: "Add term…", action: #selector(addVocabTerm), keyEquivalent: "")
        addItem.target = self
        vocabMenu.addItem(addItem)

        let entries = Vocabulary.listed(limit: 24)
        if !entries.isEmpty {
            vocabMenu.addItem(.separator())
            let header = NSMenuItem(
                title: "\(Vocabulary.count()) term\(Vocabulary.count() == 1 ? "" : "s") — click to remove",
                action: nil, keyEquivalent: "")
            header.isEnabled = false
            vocabMenu.addItem(header)
            for entry in entries {
                var title = entry.term
                if entry.pinned { title = "★ " + title }
                if entry.count > 1 { title += "  (\(entry.count))" }
                if !entry.aliases.isEmpty {
                    title += "  ← \(entry.aliases[0])"
                }
                let item = NSMenuItem(title: title, action: #selector(removeVocabTerm(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.term
                item.toolTip = "Remove “\(entry.term)” from your personal dictionary"
                vocabMenu.addItem(item)
            }
        }

        vocabMenu.addItem(.separator())
        let revealItem = NSMenuItem(title: "Show dictionary file in Finder",
                                    action: #selector(revealVocabFile), keyEquivalent: "")
        revealItem.target = self
        vocabMenu.addItem(revealItem)

        if Vocabulary.count() > 0 {
            let clearItem = NSMenuItem(title: "Clear personal dictionary…",
                                       action: #selector(clearVocab), keyEquivalent: "")
            clearItem.target = self
            vocabMenu.addItem(clearItem)
        }

        let vocabItem = NSMenuItem(
            title: Vocabulary.count() > 0
                ? "Personal dictionary (\(Vocabulary.count()))"
                : "Personal dictionary",
            action: nil, keyEquivalent: "")
        menu.addItem(vocabItem)
        menu.setSubmenu(vocabMenu, for: vocabItem)

        let appearanceMenu = NSMenu()
        appearanceMenu.autoenablesItems = false
        addToggle(to: appearanceMenu, title: "Show idle pill", key: Defaults.cornerButton,
                  action: #selector(toggleCornerButton))
        let resetItem = NSMenuItem(title: "Reset panel position",
                                   action: #selector(resetPanelPosition), keyEquivalent: "")
        resetItem.target = self
        appearanceMenu.addItem(resetItem)
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        menu.addItem(appearanceItem)
        menu.setSubmenu(appearanceMenu, for: appearanceItem)

        let pauseMenu = NSMenu()
        pauseMenu.autoenablesItems = false
        let pauseOptions: [(String, Double)] = [
            ("Off", 0), ("After 2 seconds", 2.0), ("After 3 seconds", 3.0),
            ("After 5 seconds", 5.0), ("After 8 seconds", 8.0),
        ]
        let currentPause = Defaults.pause
        for (label, seconds) in pauseOptions {
            let item = NSMenuItem(title: label, action: #selector(setPause(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            item.state = (abs(seconds - currentPause) < 0.01) ? .on : .off
            pauseMenu.addItem(item)
        }
        let pauseItem = NSMenuItem(title: "Finish when I stop talking", action: nil, keyEquivalent: "")
        menu.addItem(pauseItem)
        menu.setSubmenu(pauseMenu, for: pauseItem)

        let triggerMenu = NSMenu()
        let activeTrigger = Defaults.currentTrigger
        let keyHeader = NSMenuItem(title: "Simple dictation key", action: nil, keyEquivalent: "")
        keyHeader.isEnabled = false
        triggerMenu.addItem(keyHeader)
        for option in Trigger.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (option == activeTrigger) ? .on : .off
            if option == .f5 {
                item.toolTip = "F5 is the system Dictation key. It only reaches Quill if "
                    + "\"Use F1, F2 as standard function keys\" is on in Keyboard settings."
            }
            triggerMenu.addItem(item)
        }
        triggerMenu.addItem(.separator())
        let gestureHeader = NSMenuItem(title: "Gesture (both keys)", action: nil, keyEquivalent: "")
        gestureHeader.isEnabled = false
        triggerMenu.addItem(gestureHeader)
        let activeGesture = Defaults.currentGesture
        for mode in GestureMode.allCases {
            let item = NSMenuItem(title: mode.menuTitle,
                                  action: #selector(setGestureMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (mode == activeGesture) ? .on : .off
            item.toolTip = mode.toolTip
            triggerMenu.addItem(item)
        }

        let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        menu.addItem(triggerItem)
        menu.setSubmenu(triggerMenu, for: triggerItem)

        let languageMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: Defaults.language) ?? "en"
        for (index, entry) in languages.enumerated() {
            let item = NSMenuItem(title: entry.0, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.1
            item.state = (entry.1 == current) ? .on : .off
            languageMenu.addItem(item)
            if index == 1 { languageMenu.addItem(.separator()) }
        }
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        menu.addItem(languageItem)
        menu.setSubmenu(languageMenu, for: languageItem)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let setupItem = NSMenuItem(title: Inserter.isTrusted ? "Setup…" : "Finish setup…",
                                   action: #selector(openSetup), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let quit = NSMenuItem(title: "Quit Quill", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func addToggle(to menu: NSMenu, title: String, key: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = Defaults.bool(key) ? .on : .off
        menu.addItem(item)
    }

    // MARK: Menu actions

    @objc private func toggleInsertAtEnd()   { Defaults.flip(Defaults.insertAtEnd) }
    @objc private func toggleStopPhrase()    { Defaults.flip(Defaults.stopPhrase) }

    @objc private func setPause(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        UserDefaults.standard.set(seconds, forKey: Defaults.pauseSeconds)
        Log.write("pause-to-finish set to \(seconds)s")
        hud.apply(.notice(seconds == 0
            ? "Won't finish on its own — stop it yourself"
            : "Finishes after \(seconds == 1.5 ? "1.5" : String(Int(seconds))) seconds of silence"))
        hud.collapse(after: 2.5)
    }
    @objc private func toggleClickToInsert() { Defaults.flip(Defaults.clickToInsert) }
    @objc private func toggleLoginItem()     { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func setTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Trigger(rawValue: raw) else { return }
        Defaults.setPrimaryTrigger(option)
        applyTriggersAndGesture()
        Log.write("simple trigger set to \(option.rawValue)")

        if option == .fnGlobe {
            // A bare 🌐 press normally shows emoji or switches input source; that
            // would fire twice on a double-tap. Point it at nothing.
            UserDefaults.standard.set(0, forKey: "AppleFnUsageType")
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
            try? task.run()
        }

        hud.apply(.notice("Simple: \(option.gesture(mode: Defaults.currentGesture))"))
        hud.collapse(after: 2.5)
    }

    @objc private func setSmartTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Trigger(rawValue: raw) else { return }
        Defaults.setSmartTrigger(option)
        applyTriggersAndGesture()
        Log.write("smart trigger set to \(Defaults.smartTrigger.rawValue)")
        hud.apply(.notice("Cleaned: \(Defaults.smartTrigger.gesture(mode: Defaults.currentGesture))"))
        hud.collapse(after: 2.5)
    }

    @objc private func toggleCleanup() {
        Defaults.flip(Defaults.cleanupEnabled)
        // Ensure smart key differs from simple after enabling.
        if Defaults.cleanupIsOn {
            Defaults.setSmartTrigger(Defaults.smartTrigger)
        }
        applyTriggersAndGesture()
        let on = Defaults.cleanupIsOn
        Log.write("cleanup enabled = \(on)")
        if on {
            hud.apply(.notice("Cleaned dictation: \(Defaults.smartTrigger.gesture(mode: Defaults.currentGesture))"))
        } else {
            hud.apply(.notice("Cleaned dictation off — only simple key active"))
        }
        hud.collapse(after: 2.8)
    }

    @objc private func setGestureMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = GestureMode(rawValue: raw) else { return }
        Defaults.setGesture(mode)
        applyTriggersAndGesture()
        Log.write("gesture mode set to \(mode.rawValue)")

        hud.apply(.notice(Defaults.currentTrigger.gesture(mode: mode)))
        hud.collapse(after: 2.5)
    }

    @objc private func menuToggleRaw() { toggle(lane: .raw) }

    @objc private func toggleVocabLearning() {
        Vocabulary.learningEnabled.toggle()
        let on = Vocabulary.learningEnabled
        Log.write("vocab learning = \(on)")
        hud.apply(.notice(on
            ? "Learning unique terms into your local dictionary"
            : "Stopped learning new terms (existing library kept)"))
        hud.collapse(after: 2.5)
    }

    @objc private func toggleVocabLearnFromEdits() {
        Vocabulary.learnFromEditsEnabled.toggle()
        let on = Vocabulary.learnFromEditsEnabled
        Log.write("vocab learn-from-edits = \(on)")
        if !on { editWatch.cancel() }
        hud.apply(.notice(on
            ? "Will learn dictionary terms from your post-paste edits"
            : "Won't watch fields for edits"))
        hud.collapse(after: 2.6)
    }

    @objc private func installStandardVocab() {
        let n = Vocabulary.ensureStandardSeed(force: true)
        hud.apply(.notice(n == 0
            ? "Standard AI vocabulary already up to date (\(Vocabulary.count()) terms)"
            : "Merged \(n) standard AI/harness terms (\(Vocabulary.count()) total)"))
        hud.collapse(after: 3)
    }

    @objc private func addVocabTerm() {
        let alert = NSAlert()
        alert.messageText = "Add personal term"
        alert.informativeText = "Unique name, product, or jargon — not everyday English. "
            + "Optional: how speech-to-text often mishears it."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let termField = NSTextField(string: "")
        termField.placeholderString = "Preferred spelling (e.g. Signara)"
        termField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let aliasField = NSTextField(string: "")
        aliasField.placeholderString = "Optional mishearing (e.g. Signa)"
        aliasField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        stack.addArrangedSubview(termField)
        stack.addArrangedSubview(aliasField)
        stack.setFrameSize(NSSize(width: 280, height: 54))
        alert.accessoryView = stack

        // Menu was modal; activate briefly so the alert can take focus.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let term = termField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let alias = aliasField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        if Vocabulary.addManual(term, alias: alias.isEmpty ? nil : alias) {
            hud.apply(.notice("Saved “\(term)” to personal dictionary"))
        } else {
            hud.apply(.notice("Couldn’t add that term"))
        }
        hud.collapse(after: 2.2)
    }

    @objc private func removeVocabTerm(_ sender: NSMenuItem) {
        guard let term = sender.representedObject as? String else { return }
        Vocabulary.remove(term: term)
        hud.apply(.notice("Removed “\(term)”"))
        hud.collapse(after: 1.6)
    }

    @objc private func revealVocabFile() {
        Vocabulary.revealInFinder()
    }

    @objc private func clearVocab() {
        let alert = NSAlert()
        alert.messageText = "Clear personal dictionary?"
        alert.informativeText = "Removes all \(Vocabulary.count()) learned terms from this Mac. "
            + "Cleanup will no longer have your name/product spellings."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Vocabulary.clearAll()
        hud.apply(.notice("Personal dictionary cleared"))
        hud.collapse(after: 2)
    }

    @objc private func resetPanelPosition() {
        hud.resetPosition()
    }

    @objc private func toggleCornerButton() {
        Defaults.flip(Defaults.cornerButton)
        let showing = Defaults.bool(Defaults.cornerButton)
        hud.showsIdlePill = showing
        Log.write("idle pill \(showing ? "shown" : "hidden")")

        if !showing {
            // With the pill gone there may be no visible affordance left — this
            // Mac's menu bar is often too full to show another item — so say how
            // to get it back before it disappears.
            hud.apply(.notice("Idle pill hidden. \(Defaults.currentTrigger.gesture(mode: Defaults.currentGesture)) still works; the menu-bar icon brings it back."))
            hud.collapse(after: 6)
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        UserDefaults.standard.set(code, forKey: Defaults.language)
    }

    @objc private func copyHistory(_ sender: NSMenuItem) {
        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        guard sender.tag < history.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(history[sender.tag], forType: .string)
        hud.apply(.notice("Copied to clipboard"))
        hud.collapse(after: 1.2)
    }

    @objc private func clearHistory() {
        UserDefaults.standard.removeObject(forKey: Defaults.history)
        Log.write("recent transcripts cleared")
        hud.apply(.notice("Recent transcripts cleared"))
        hud.collapse(after: 2)
    }

    @objc private func toggleKeepHistory() {
        Defaults.flip(Defaults.keepHistory)
        let on = Defaults.bool(Defaults.keepHistory)
        if !on { UserDefaults.standard.removeObject(forKey: Defaults.history) }
        Log.write("keep recent transcripts = \(on)")
        hud.apply(.notice(on ? "Keeping recent transcripts"
                             : "Not keeping transcripts — existing ones cleared"))
        hud.collapse(after: 2.5)
    }

    @objc private func openSetup() { setup.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    private func toggle(lane: DictationLane) {
        if isRecording {
            stopSession(reason: .hotkey)
        } else {
            startSession(fromHold: false, cleanup: lane == .smart)
        }
    }

    /// Push-to-talk: key down — start mic/STT immediately so first words aren't lost (P0).
    private func armHoldSession(lane: DictationLane) {
        if isRecording {
            // Already in a session (e.g. tap mode) — don't nest.
            Log.write("hold arm ignored — already recording")
            return
        }
        Log.write("hold arm lane=\(lane.rawValue) — priming mic/HUD")
        holdCommitted = false
        startSession(fromHold: true, cleanup: lane == .smart)
    }

    /// Push-to-talk: hold delay elapsed while still bare — commit primed session.
    private func commitHoldSession(lane: DictationLane) {
        guard sessionFromHold else {
            // Arm never started a session (auth denied, etc.) — try a fresh start.
            Log.write("hold commit without prime — starting lane=\(lane.rawValue)")
            holdCommitted = true
            startSession(fromHold: true, cleanup: lane == .smart)
            return
        }
        holdCommitted = true
        Log.write("hold committed lane=\(lane.rawValue) recording=\(isRecording)")
        if isRecording, sessionUsesCleanup {
            hud.flashTarget("cleaned dictation", for: 1.6)
        }
    }

    /// Push-to-talk: key released — stop and insert only if committed.
    private func endHoldSession(lane: DictationLane) {
        if !isRecording {
            // Released during mic permission / auth / setup — drop the pending start.
            if sessionFromHold {
                Log.write("hold end before recording started — discarded (lane=\(lane.rawValue))")
                sessionFromHold = false
                sessionUsesCleanup = false
                holdCommitted = false
            }
            hotkey.resetHoldState()
            return
        }
        guard sessionFromHold else {
            hotkey.resetHoldState()
            return
        }
        // Primed but never committed (shouldn't happen if cancel path is wired) —
        // still refuse to insert accidental short holds.
        if !holdCommitted {
            Log.write("hold end without commit — cancelling (lane=\(lane.rawValue))")
            cancelSession()
            return
        }
        Log.write("hold end — stopping (lane=\(lane.rawValue))")
        stopSession(reason: .hold)
    }

    private func handleClickAnywhere(at point: CGPoint) {
        let onPill = hud.contains(globalPoint: point)
        Log.write("click seen at \(Int(point.x)),\(Int(point.y)) — recording=\(isRecording) onPill=\(onPill)")
        guard isRecording, Defaults.bool(Defaults.clickToInsert) else { return }
        // During hold-to-talk the release is the stop; clicks stay out of the way.
        guard !sessionFromHold else { return }
        // A click on the pill is the pill's own business.
        guard !onPill else { return }
        stopSession(reason: .click)
    }

    private func startSession(fromHold: Bool = false, cleanup: Bool = false) {
        guard !isRecording else { return }
        sessionFromHold = fromHold
        sessionUsesCleanup = cleanup
        // Tap / menu starts are always "committed"; hold primes until delay fires.
        if !fromHold { holdCommitted = true }
        // A new dictation supersedes any pending post-paste edit watch.
        editWatch.cancel()

        // Grab the highlighted text now — clicking a destination later would
        // destroy it, and this is the only moment it is reliably present.
        capturedSelection = Inserter.captureSelection()

        if selfTestPath != nil {
            beginCapture()
            return
        }

        Recorder.micAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.sessionFromHold = false
                self.sessionUsesCleanup = false
                self.holdCommitted = false
                self.hotkey.resetHoldState()
                self.hud.apply(.notice("Microphone access denied — enable Quill in Privacy & Security ▸ Microphone"))
                self.hud.collapse(after: 4)
                Inserter.openPrivacyPane("Privacy_Microphone")
                return
            }
            // Hold may have been cancelled (chord / short release) while auth ran.
            if fromHold {
                guard self.sessionFromHold else {
                    Log.write("hold cancelled during mic auth — skip capture")
                    return
                }
                if !self.hotkey.isHolding, Defaults.currentGesture == .hold {
                    Log.write("hold released before mic auth finished — aborting start")
                    self.sessionFromHold = false
                    self.sessionUsesCleanup = false
                    self.holdCommitted = false
                    return
                }
            }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard let creds = Auth.load() else {
            sessionFromHold = false
            sessionUsesCleanup = false
            holdCommitted = false
            hotkey.resetHoldState()
            hud.apply(.notice("No Grok Build session found — run `grok` once to sign in"))
            hud.collapse(after: 4)
            return
        }

        // If this was a hold and the key is already up, don't start a ghost session.
        // isHolding includes the arm phase so early-prime survives the delay window.
        if sessionFromHold, !hotkey.isHolding, Defaults.currentGesture == .hold {
            Log.write("hold released before capture ready — aborting start")
            sessionFromHold = false
            sessionUsesCleanup = false
            holdCommitted = false
            return
        }

        let client = STTClient()
        stt = client
        pendingPCM = []
        socketReady = false
        sawAnyText = false
        stopReason = sessionFromHold ? .hold : .hotkey
        didRunVoiceCommand = false
        lastStopCandidate = nil

        client.onReady = { [weak self] in
            guard let self else { return }
            self.socketReady = true
            for chunk in self.pendingPCM { client.send(pcm: chunk) }
            self.pendingPCM = []
        }
        client.onText = { [weak self] text in
            guard let self, !text.isEmpty else { return }
            self.sawAnyText = true

            if !self.didRunVoiceCommand, VoiceCommands.containsOpenGrok(text) {
                self.didRunVoiceCommand = true
                self.runOpenGrok()
            }

            self.considerVoiceStop(after: text)
            // Hold-to-talk: release is the stop — skip auto-finish pause watch signals.
            // Only NEW words count as activity (unchanged partials re-fire constantly).
            if !self.sessionFromHold, text != self.lastActivityText {
                self.lastActivityText = text
                self.noteVoiceActivity()
            }

            // Show what will actually be inserted, command phrases already removed.
            let preview = VoiceCommands.stripAll(text)
            self.hud.update(text: self.sessionUsesCleanup ? "✦ \(preview)" : preview)
        }
        client.onComplete = { [weak self] text in self?.finishSession(with: text) }
        client.onFailure = { [weak self] failure in self?.abortSession(message: failure.message) }

        client.connect(token: creds.token,
                       language: UserDefaults.standard.string(forKey: Defaults.language) ?? "en")

        recorder.onPCM = { [weak self] data in
            guard let self else { return }
            if self.socketReady { client.send(pcm: data) }
            else if self.pendingPCM.count < 200 { self.pendingPCM.append(data) }
        }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.sessionFromHold { self.observe(level: level) }
                self.hud.update(level: level)
            }
        }

        if let selfTestPath {
            startSelfTest(path: selfTestPath, client: client)
            return
        }

        do {
            try recorder.start()
        } catch {
            stt?.cancel()
            stt = nil
            sessionFromHold = false
            sessionUsesCleanup = false
            holdCommitted = false
            hotkey.resetHoldState()
            hud.apply(.notice(error.localizedDescription))
            hud.collapse(after: 3.5)
            return
        }

        enterRecordingState()
    }

    private func enterRecordingState() {
        isRecording = true
        startedAt = Date()
        refreshIcon()
        hud.apply(.listening)
        // For hold: flash "cleaned" only once committed (delay elapsed), not on arm.
        if sessionUsesCleanup, !sessionFromHold || holdCommitted {
            hud.flashTarget("cleaned dictation", for: 1.6)
        }
        if let selection = capturedSelection {
            hud.flashTarget("replacing \(selection.range.length) selected characters", for: 3)
        }
        let front = Inserter.frontmostApp()
        hud.update(target: front.name, icon: front.icon)
        // Hold-to-talk stops on release; click-to-insert is only for tap modes.
        hotkey.watchClicks = !sessionFromHold && Defaults.bool(Defaults.clickToInsert)
        hotkey.watchForCancel(true)
        lastVoiceAt = Date()
        lastActivityText = nil
        noiseFloor = 0.02
        if !sessionFromHold { startPauseWatch() }
        Log.write("recording started — watchClicks=\(hotkey.watchClicks) fromHold=\(sessionFromHold) committed=\(holdCommitted) cleanup=\(sessionUsesCleanup)")

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            self.hud.update(elapsed: Date().timeIntervalSince(startedAt))
            let front = Inserter.frontmostApp()
            self.hud.update(target: front.name, icon: front.icon)
        }
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isRecording, !self.sawAnyText else { return }
            self.logAudioState()
            self.abortSession(message: self.diagnosis())
        }
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.stopSession(reason: .hotkey)
        }
    }

    private func startSelfTest(path: String, client: STTClient) {
        guard let pcm = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("SELFTEST: cannot read \(path)\n".utf8))
            NSApp.terminate(nil)
            return
        }

        enterRecordingState()
        FileHandle.standardError.write(Data("SELFTEST: streaming \(pcm.count / 32000)s of audio\n".utf8))

        var offset = 0
        let chunk = 3200
        selfTestTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard offset < pcm.count else {
                timer.invalidate()
                self.stopSession(reason: .hotkey)
                return
            }
            let end = min(offset + chunk, pcm.count)
            let slice = pcm.subdata(in: offset..<end)
            if self.socketReady { client.send(pcm: slice) } else { self.pendingPCM.append(slice) }
            offset = end
        }
    }

    /// Why did nothing come back? "No speech detected" was covering four
    /// completely different failures, which made a broken microphone and a broken
    /// network indistinguishable.
    private func diagnosis() -> String {
        if recorder.framesCaptured == 0 {
            return "No audio from the microphone — check Sound ▸ Input"
        }
        if recorder.peakLevel < 0.004 {
            return "Microphone is silent — wrong input device, or muted"
        }
        if !socketReady {
            return "Couldn't reach speech-to-text — check your connection"
        }
        return "Heard you, but no transcript came back"
    }

    private func logAudioState() {
        Log.write("  audio: input=\(recorder.inputDescription) "
            + "frames=\(recorder.framesCaptured) peak=\(String(format: "%.4f", recorder.peakLevel)) "
            + "socketReady=\(socketReady) sawText=\(sawAnyText)")
    }

    /// Opens Grok Build without interrupting the recording — the mic keeps running
    /// so the rest of the sentence still becomes the prompt.
    private func runOpenGrok() {
        Log.write("voice command: open Grok")
        hud.flashTarget("opening Grok Build…", for: 8)
        GrokLauncher.open { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .opened(let terminal):
                self.hud.flashTarget("Grok Build opened in \(terminal)", for: 2)
            case .failed(let message):
                Log.write("  open Grok failed — \(message)")
                self.hud.flashTarget("couldn't open Grok Build", for: 4)
            }
        }
    }

    /// Stop when "that's it" is the last thing said — but only after a beat of
    /// silence, so a mid-sentence "that's it exactly" cannot cut someone off. Any
    /// further speech cancels the pending stop.
    private func considerVoiceStop(after text: String) {
        if ProcessInfo.processInfo.environment["QUILL_TRACE_STOP"] != nil {
            Log.write("  tail? \"…\(String(text.suffix(20)))\" ends=\(VoiceCommands.endsWithStopPhrase(text)) "
                + "pending=\(pendingVoiceStop != nil)")
        }

        guard Defaults.bool(Defaults.stopPhrase), isRecording,
              VoiceCommands.endsWithStopPhrase(text)
        else {
            // Speech continued past the phrase, or the feature is off — stand down.
            pendingVoiceStop?.cancel()
            pendingVoiceStop = nil
            lastStopCandidate = nil
            return
        }

        // Only a CHANGE in what was said restarts the countdown. The server
        // re-sends an unchanged partial every couple of hundred milliseconds while
        // it works through the audio, and treating those as new speech pushed the
        // deadline back forever, so the stop never fired at all.
        if text == lastStopCandidate, pendingVoiceStop != nil { return }
        lastStopCandidate = text

        pendingVoiceStop?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            Log.write("voice stop: heard the finish phrase")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
        pendingVoiceStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    /// Chord, short hold, release-before-commit, or Escape — throw it away, insert nothing.
    private func cancelSession(announce: Bool = false) {
        // Pending arm (mic auth not finished yet): clear flags so the auth
        // callback will not start a ghost capture.
        if !isRecording {
            if sessionFromHold || holdCommitted {
                Log.write("hold cancelled before recording started")
                sessionFromHold = false
                sessionUsesCleanup = false
                holdCommitted = false
                hotkey.resetHoldState()
            }
            return
        }
        Log.write(announce ? "cancelled by Escape" : "cancelled (discard session)")
        isRecording = false
        sessionFromHold = false
        sessionUsesCleanup = false
        holdCommitted = false
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        hotkey.resetHoldState()
        invalidateTimers()
        recorder.stop()
        stt?.cancel()
        stt = nil
        refreshIcon()
        if announce {
            hud.apply(.notice("Cancelled"))
            hud.collapse(after: 0.9)
        } else {
            // Silent collapse for accidental short holds / chords.
            hud.apply(.idle)
            hud.collapse(after: 0.05)
        }
    }

    /// Finish once the microphone actually goes quiet (upstream 0.7).
    ///
    /// Transcript silence was the wrong signal — updates lag speech and gap
    /// between segments, so sessions ended mid-sentence. Silence now means both
    /// the mic is below the adaptive noise floor and no new words arrived.
    private func noteVoiceActivity() {
        lastVoiceAt = Date()
    }

    private func observe(level: Float) {
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.90 + level * 0.10
        } else {
            noiseFloor = noiseFloor * 0.995 + level * 0.005
        }
        if level > max(0.07, noiseFloor * 2.5) { noteVoiceActivity() }
    }

    private func startPauseWatch() {
        pauseTimer?.invalidate()
        guard Defaults.pause > 0 else { return }
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            let quiet = Date().timeIntervalSince(self.lastVoiceAt)
            let window = Defaults.pause
            guard self.isRecording, self.sawAnyText, window > 0, quiet >= window else { return }
            Log.write("pause stop: \(String(format: "%.1f", quiet))s of silence")
            self.hud.flashTarget("finishing…", for: 2)
            self.stopSession(reason: .voice)
        }
    }

    private func stopSession(reason: StopReason) {
        guard isRecording else { return }
        isRecording = false
        sessionFromHold = false
        holdCommitted = false
        // Keep sessionUsesCleanup until finishSession so the cleanup pass can run.
        stopReason = reason
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        if reason != .hold {
            // Hold path already cleared active state on key-up; other stops need it.
            hotkey.resetHoldState()
        }
        invalidateTimers()
        recorder.stop()
        refreshIcon()

        // Never discard the session just because no partial has arrived yet — on
        // the first recording the socket is often still connecting. Let it finish
        // and decide on the actual transcript instead.
        let reasonLabel: String = {
            switch reason {
            case .click:  return "click"
            case .voice:  return "voice"
            case .hold:   return "hold-release"
            case .hotkey: return "hotkey/pill"
            }
        }()
        Log.write("stop (\(reasonLabel)) — finalising, sawText=\(sawAnyText) cleanup=\(sessionUsesCleanup)")
        finaliseStartedAt = Date()
        logAudioState()
        hud.apply(.thinking)
        stt?.finish()
    }

    private func finishSession(with text: String) {
        stt = nil
        // The command phrase must never reach the target app.
        let trimmed = VoiceCommands.stripAll(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let wantsCleanup = sessionUsesCleanup
        sessionUsesCleanup = false

        guard !trimmed.isEmpty else {
            if didRunVoiceCommand {
                hud.apply(.notice("Opened Grok Build"))
                hud.collapse(after: 1.6)
            } else {
                hud.apply(.notice(diagnosis()))
                hud.collapse(after: 4)
            }
            return
        }

        if wantsCleanup, let creds = Auth.load() {
            let vocabN = Vocabulary.count()
            // Length-scaled budget (short phrases stay snappy; long rants get up to ~8s).
            let cleanupBudget = Cleaner.budgetSeconds(for: trimmed)
            let budgetLabel = String(format: "%.1f", cleanupBudget)
            hud.flashTarget(vocabN > 0
                ? "cleaning with Grok… (\(vocabN) terms, ≤\(budgetLabel)s)"
                : "cleaning with Grok… (≤\(budgetLabel)s)", for: cleanupBudget + 0.5)
            hud.update(text: trimmed)
            var finished = false
            let apply: (Cleaner.Outcome) -> Void = { [weak self] outcome in
                guard let self, !finished else { return }
                finished = true
                switch outcome {
                case .cleaned(let polished):
                    Vocabulary.learnFromCleanup(raw: trimmed, cleaned: polished)
                    self.deliverInsert(polished, notedCleanup: true)
                case .failed(let message):
                    Log.write("cleanup failed — using raw: \(message)")
                    let note = message.contains("timed out")
                        ? "cleanup slow — pasting raw"
                        : "cleanup failed — pasting raw"
                    self.hud.flashTarget(note, for: 2)
                    self.deliverInsert(trimmed, notedCleanup: false)
                }
            }
            let budgetWork = DispatchWorkItem {
                apply(.failed("cleanup timed out (\(budgetLabel)s budget)"))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + cleanupBudget, execute: budgetWork)
            Cleaner.clean(trimmed, token: creds.token) { outcome in
                budgetWork.cancel()
                apply(outcome)
            }
            return
        }

        deliverInsert(trimmed, notedCleanup: false)
    }

    /// Remember + insert into the focused field.
    private func deliverInsert(_ text: String, notedCleanup: Bool) {
        // Grow the local unique-term library from what was actually inserted.
        Vocabulary.learnFromFinalText(text)
        remember(text)
        hud.update(text: text)

        if selfTestPath != nil {
            FileHandle.standardError.write(Data("SELFTEST RESULT: \(text)\n".utf8))
            // Lets a test wait for background work (e.g. launching Grok) to finish.
            let hold = Double(ProcessInfo.processInfo.environment["QUILL_SELFTEST_HOLD"] ?? "") ?? 0
            guard ProcessInfo.processInfo.environment["QUILL_SELFTEST_INSERT"] != nil else {
                hud.apply(.delivered(nil))
                hud.collapse(after: 0.7)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + hold) { NSApp.terminate(nil) }
                return
            }
            FileHandle.standardError.write(Data("SELFTEST FOCUS: \(Inserter.describeFocus())\n".utf8))
            let testSelection = self.capturedSelection
            self.capturedSelection = nil
            Inserter.insert(text,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: testSelection) { outcome in
                let method: String
                switch outcome.method {
                case .accessibility: method = "accessibility"
                case .clipboard:     method = "clipboard-fallback"
                case .blocked:       method = "BLOCKED (no Accessibility)"
                }
                self.hud.apply(.delivered(outcome.app))
                self.hud.update(text: text)
                // Success is reported as soon as ⌘V is posted, so give the target
                // app a moment to actually apply it before reading back.
                Thread.sleep(forTimeInterval: 0.6)
                self.hud.collapse(after: 0.7)
                let readback = Inserter.focusedFieldValue() ?? "<field not readable>"
                FileHandle.standardError.write(Data("""
                SELFTEST METHOD: \(method) → \(outcome.app ?? "unknown app")
                SELFTEST FIELD NOW: \(readback)

                """.utf8))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { NSApp.terminate(nil) }
            }
            return
        }

        // After a click we wait a beat: the click still has to land, focus has to
        // settle, and the app has to place its caret before we write into it.
        let settle: TimeInterval = (stopReason == .click) ? 0.22 : 0.16

        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            guard let self else { return }
            let selection = self.capturedSelection
            self.capturedSelection = nil
            Inserter.insert(text,
                            atEndOfField: Defaults.bool(Defaults.insertAtEnd),
                            replacing: selection) { outcome in
                switch outcome.method {
                case .accessibility, .clipboard:
                    if let started = self.finaliseStartedAt {
                        Log.write("  tail: stop → inserted in "
                            + String(format: "%.2fs", Date().timeIntervalSince(started))
                            + (notedCleanup ? " (cleaned)" : ""))
                    }
                    self.hud.apply(.delivered(outcome.app))
                    self.hud.update(text: text)
                    self.hud.collapse(after: 0.7)
                    // Watch for hand-edits in AX-readable fields → personal dictionary.
                    self.armEditWatch(afterInserting: text)
                case .blocked:
                    self.hud.apply(.notice("Grant Accessibility to Quill so it can write into apps"))
                    self.hud.collapse(after: 4)
                    Inserter.requestTrust()
                }
            }
        }
    }

    private func abortSession(message: String) {
        Log.write("aborted — \(message)")
        isRecording = false
        sessionFromHold = false
        sessionUsesCleanup = false
        holdCommitted = false
        pendingVoiceStop?.cancel()
        pendingVoiceStop = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        hotkey.watchClicks = false
        hotkey.watchForCancel(false)
        hotkey.resetHoldState()
        invalidateTimers()
        recorder.stop()
        stt?.cancel()
        stt = nil
        refreshIcon()
        hud.apply(.notice(message))
        hud.collapse(after: 4)
    }

    private func invalidateTimers() {
        [silenceTimer, maxDurationTimer, tickTimer, selfTestTimer, pauseTimer].forEach { $0?.invalidate() }
        silenceTimer = nil
        maxDurationTimer = nil
        tickTimer = nil
        selfTestTimer = nil
        pauseTimer = nil
    }

    /// Recent dictations for re-copy. Preferences are plaintext — optional.
    private func remember(_ text: String) {
        guard Defaults.bool(Defaults.keepHistory) else { return }
        var history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        history.insert(text, at: 0)
        UserDefaults.standard.set(Array(history.prefix(20)), forKey: Defaults.history)
    }

    /// After a successful paste, watch the field for hand-edits and grow the dictionary.
    /// Learning is silent in the HUD — see `vocab: user edit taught…` in Quill.log.
    private func armEditWatch(afterInserting text: String) {
        guard Vocabulary.learningEnabled, Vocabulary.learnFromEditsEnabled else { return }
        editWatch.start(original: text) { _ in
            // Terms are already logged in Vocabulary.learnFromUserEdit.
        }
    }
}

// MARK: - Post-insert edit → vocabulary

/// Re-reads the focused field for a short window after paste. When the user
/// changes the text and then pauses, diffs it against the original insert and
/// teaches the personal dictionary (preferred spellings + aliases).
///
/// Only works in Accessibility-readable fields (native text views, many apps).
/// Web/terminal clipboard fallbacks often can't be re-read — those are skipped.
final class PostInsertEditWatch {
    private var timer: Timer?
    private var original = ""
    private var fieldBefore = ""
    private var lastSeen = ""
    private var stableTicks = 0
    private var ticks = 0
    private var sawChange = false
    private var onLearned: ((Int) -> Void)?

    private let maxTicks = 30          // ~30s at 1s interval
    private let settleTicks = 2        // unchanged reads after a change
    private let settleDelay: TimeInterval = 0.55

    func cancel() {
        timer?.invalidate()
        timer = nil
        original = ""
        fieldBefore = ""
        lastSeen = ""
        stableTicks = 0
        ticks = 0
        sawChange = false
        onLearned = nil
    }

    func start(original: String, onLearned: @escaping (Int) -> Void) {
        cancel()
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty else { return }
        self.original = o
        self.onLearned = onLearned

        // Let paste settle, then snapshot the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            guard let self, !self.original.isEmpty else { return }
            guard let snapshot = Inserter.focusedFieldValue(), !snapshot.isEmpty else {
                Log.write("vocab: edit-watch skipped — field not readable via Accessibility")
                self.cancel()
                return
            }
            self.fieldBefore = snapshot
            self.lastSeen = snapshot
            self.ticks = 0
            self.stableTicks = 0
            self.sawChange = false
            self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            Log.write("vocab: edit-watch armed for \(o.count) chars")
        }
    }

    private func tick() {
        ticks += 1
        if ticks > maxTicks {
            // Timed out — if they changed and then left it, still try once.
            if sawChange, lastSeen != fieldBefore {
                finish(with: lastSeen)
            } else {
                cancel()
            }
            return
        }

        guard let now = Inserter.focusedFieldValue() else {
            // Focus left a readable field — learn from last seen if it changed.
            if sawChange, lastSeen != fieldBefore {
                finish(with: lastSeen)
            } else {
                cancel()
            }
            return
        }

        if now == lastSeen {
            if sawChange {
                stableTicks += 1
                if stableTicks >= settleTicks {
                    finish(with: now)
                }
            }
            return
        }

        // Field content changed.
        lastSeen = now
        if now != fieldBefore {
            sawChange = true
            stableTicks = 0
        }
    }

    private func finish(with fieldAfter: String) {
        let o = original
        let before = fieldBefore
        let callback = onLearned
        cancel()
        guard fieldAfter != before else { return }
        let learned = Vocabulary.learnFromUserEdit(original: o,
                                                   fieldBefore: before,
                                                   fieldAfter: fieldAfter)
        if learned > 0 {
            callback?(learned)
        }
    }
}

// MARK: - Login item

enum LoginItem {
    static let label = "com.freeze.quill"
    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    static func setEnabled(_ enabled: Bool) {
        let fm = FileManager.default
        if enabled {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try? data?.write(to: URL(fileURLWithPath: plistPath))
        } else {
            try? fm.removeItem(atPath: plistPath)
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = QuillApp()
app.delegate = delegate
app.run()
