import Cocoa
import AVFoundation
import IOKit.hid

// MARK: - Settings

enum Defaults {
    static let language = "language"
    static let history = "history"
    static let cornerButton = "cornerButton"
    static let insertAtEnd = "insertAtEnd"
    static let clickToInsert = "clickToInsert"
    static let trigger = "trigger"
    static let singleTap = "singleTap"
    static let didShowSetup = "didShowSetup"

    static func register() {
        UserDefaults.standard.register(defaults: [
            language: "en",
            cornerButton: true,
            insertAtEnd: true,
            clickToInsert: true,
            trigger: Trigger.control.rawValue,
            singleTap: true,
        ])
    }

    static func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static var currentTrigger: Trigger {
        Trigger(rawValue: UserDefaults.standard.string(forKey: trigger) ?? "") ?? .rightCommand
    }
    static func flip(_ key: String) { UserDefaults.standard.set(!bool(key), forKey: key) }
}

// MARK: - App

final class QuillApp: NSObject, NSApplicationDelegate {

    private enum StopReason {
        case hotkey     // ⌘⌘ or the pill — focus has not moved
        case click      // you clicked into the target — give focus a beat to settle
    }

    private let hotkey = DoubleTapRightCommand()
    private let recorder = Recorder()
    private let hud = HUD()
    private var stt: STTClient?

    private var statusItem: NSStatusItem!
    private var isRecording = false
    private var pendingPCM: [Data] = []
    private var socketReady = false
    private var sawAnyText = false
    private var stopReason: StopReason = .hotkey
    private var didRunVoiceCommand = false
    private var finaliseStartedAt: Date?
    private var startedAt: Date?

    private var silenceTimer: Timer?
    private var maxDurationTimer: Timer?
    private var tickTimer: Timer?
    private var trustTimer: Timer?
    private var isTrusted = false

    /// QUILL_SELFTEST=<file.pcm> replaces the microphone with a 16 kHz mono PCM16
    /// file, so the socket → transcript → insert path can be verified headlessly.
    private let selfTestPath = ProcessInfo.processInfo.environment["QUILL_SELFTEST"]
    private var selfTestTimer: Timer?
    private let setup = SetupWindow()

    private let languages: [(String, String)] = [
        ("English", "en"), ("Auto-detect", "auto"), ("Hindi", "hi"),
        ("Spanish", "es"), ("French", "fr"), ("German", "de"), ("Japanese", "ja"),
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
            self.toggle()
        }
        hud.showsIdlePill = Defaults.bool(Defaults.cornerButton)
        hud.install()

        hotkey.trigger = Defaults.currentTrigger
        applyTapMode()
        hotkey.onTrigger = { [weak self] in self?.toggle() }
        hotkey.onClickAnywhere = { [weak self] point in self?.handleClickAnywhere(at: point) }

        isTrusted = Inserter.isTrusted
        let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        Log.write("launch — AXIsProcessTrusted=\(isTrusted) inputMonitoring=\(inputMonitoring.rawValue) "
            + "trigger=\(Defaults.currentTrigger.gesture(singleTap: Defaults.bool(Defaults.singleTap))) "
            + "bundle=\(Bundle.main.bundlePath)")

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
            self.applyTapMode()
            let now = Inserter.isTrusted
            guard now != self.isTrusted else { return }
            self.isTrusted = now
            self.hud.setNeedsPermission(!now)
            Log.write("Accessibility trust changed → \(now); re-arming event tap")
            self.hotkey.stop()
            self.hotkey.start()
            if now {
                self.hud.apply(.notice("Accessibility granted — \(Defaults.currentTrigger.gesture(singleTap: self.hotkey.singleTap)) is live"))
                self.hud.collapse(after: 2.5)
            }
        }
        refreshIcon()

        if selfTestPath != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.toggle() }
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

    /// Single-tap needs Input Monitoring, and it is not optional.
    ///
    /// Without it the event tap receives modifier changes but NOT key presses, so
    /// there is no way to tell a bare ⌃ tap from ⌃C — and dictation would fire on
    /// every shortcut you press in a terminal. Measured, not assumed. Until it is
    /// granted, single-tap silently degrades to double-tap rather than misfiring.
    private var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private var loggedTapMode: Bool?

    private func applyTapMode() {
        let wanted = Defaults.bool(Defaults.singleTap)
        // Chords are now detected from the system's key-press counters, which are
        // not permission-gated, so single tap no longer depends on Input Monitoring.
        let safe = wanted
        hotkey.singleTap = safe
        guard loggedTapMode != safe else { return }      // only on change, not every tick
        loggedTapMode = safe
        if wanted && !safe {
            Log.write("single-tap requested but Input Monitoring denied — using double-tap")
        } else if safe {
            Log.write("single tap is live")
        }
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
        button.toolTip = "Quill — double-tap right ⌘ to dictate"
    }

    @objc private func statusItemClicked() {
        let rightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        rightClick ? showMenu() : toggle()
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

        let account = Auth.load()
        let header = NSMenuItem(title: account.map { "Grok Build · \($0.email ?? "signed in")" }
                                    ?? "Grok Build · not signed in",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: isRecording ? "Stop dictation" : "Start dictation",
                                    action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let hint = NSMenuItem(title: "\(Defaults.currentTrigger.gesture(singleTap: Defaults.bool(Defaults.singleTap))) anywhere",
                              action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        if !history.isEmpty {
            let recent = NSMenu()
            for (index, entry) in history.prefix(8).enumerated() {
                let title = entry.count > 60 ? String(entry.prefix(60)) + "…" : entry
                let item = NSMenuItem(title: title, action: #selector(copyHistory(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                recent.addItem(item)
            }
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            menu.addItem(recentItem)
            menu.setSubmenu(recent, for: recentItem)
            menu.addItem(.separator())
        }

        addToggle(to: menu, title: "Click anywhere to insert", key: Defaults.clickToInsert,
                  action: #selector(toggleClickToInsert))
        addToggle(to: menu, title: "Insert at end of field", key: Defaults.insertAtEnd,
                  action: #selector(toggleInsertAtEnd))

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

        let triggerMenu = NSMenu()
        let activeTrigger = Defaults.currentTrigger
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
        let single = NSMenuItem(title: "Single tap (instead of double)",
                                action: #selector(toggleSingleTap), keyEquivalent: "")
        single.target = self
        single.state = Defaults.bool(Defaults.singleTap) ? .on : .off
        single.toolTip = "A tap only counts if nothing else is pressed while the key is held, "
            + "so ⌃C and friends never trigger it."
        triggerMenu.addItem(single)

        let triggerItem = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        menu.addItem(triggerItem)
        menu.setSubmenu(triggerMenu, for: triggerItem)

        let languageMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: Defaults.language) ?? "en"
        for (label, code) in languages {
            let item = NSMenuItem(title: label, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            item.state = (code == current) ? .on : .off
            languageMenu.addItem(item)
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
    @objc private func toggleClickToInsert() { Defaults.flip(Defaults.clickToInsert) }
    @objc private func toggleLoginItem()     { LoginItem.setEnabled(!LoginItem.isEnabled) }

    @objc private func setTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let option = Trigger(rawValue: raw) else { return }
        UserDefaults.standard.set(raw, forKey: Defaults.trigger)
        hotkey.trigger = option
        Log.write("trigger set to \(option.rawValue)")

        if option == .fnGlobe {
            // A bare 🌐 press normally shows emoji or switches input source; that
            // would fire twice on a double-tap. Point it at nothing.
            UserDefaults.standard.set(0, forKey: "AppleFnUsageType")
            let task = Process()
            task.launchPath = "/usr/bin/defaults"
            task.arguments = ["write", "com.apple.HIToolbox", "AppleFnUsageType", "-int", "0"]
            try? task.run()
        }

        hud.apply(.notice("Trigger: \(option.gesture(singleTap: Defaults.bool(Defaults.singleTap)))"))
        hud.collapse(after: 2.5)
    }

    @objc private func toggleSingleTap() {
        Defaults.flip(Defaults.singleTap)
        let on = Defaults.bool(Defaults.singleTap)
        applyTapMode()
        Log.write("singleTap requested = \(on), effective = \(hotkey.singleTap)")

        hud.apply(.notice(Defaults.currentTrigger.gesture(singleTap: hotkey.singleTap)))
        hud.collapse(after: 2.5)
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
            hud.apply(.notice("Idle pill hidden. \(Defaults.currentTrigger.gesture(singleTap: hotkey.singleTap)) still works; the menu-bar icon brings it back."))
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

    @objc private func openSetup() { setup.show() }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Session

    @objc private func toggle() {
        isRecording ? stopSession(reason: .hotkey) : startSession()
    }

    private func handleClickAnywhere(at point: CGPoint) {
        let onPill = hud.contains(globalPoint: point)
        Log.write("click seen at \(Int(point.x)),\(Int(point.y)) — recording=\(isRecording) onPill=\(onPill)")
        guard isRecording, Defaults.bool(Defaults.clickToInsert) else { return }
        // A click on the pill is the pill's own business.
        guard !onPill else { return }
        stopSession(reason: .click)
    }

    private func startSession() {
        guard !isRecording else { return }

        if selfTestPath != nil {
            beginCapture()
            return
        }

        Recorder.micAuthorization { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.hud.apply(.notice("Microphone access denied — enable Quill in Privacy & Security ▸ Microphone"))
                self.hud.collapse(after: 4)
                Inserter.openPrivacyPane("Privacy_Microphone")
                return
            }
            self.beginCapture()
        }
    }

    private func beginCapture() {
        guard let creds = Auth.load() else {
            hud.apply(.notice("No Grok Build session found — run `grok` once to sign in"))
            hud.collapse(after: 4)
            return
        }

        let client = STTClient()
        stt = client
        pendingPCM = []
        socketReady = false
        sawAnyText = false
        stopReason = .hotkey
        didRunVoiceCommand = false

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

            // Show what will actually be inserted, command phrase already removed.
            self.hud.update(text: VoiceCommands.strip(text))
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
            DispatchQueue.main.async { self?.hud.update(level: level) }
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
        let front = Inserter.frontmostApp()
        hud.update(target: front.name, icon: front.icon)
        hotkey.watchClicks = Defaults.bool(Defaults.clickToInsert)
        Log.write("recording started — watchClicks=\(hotkey.watchClicks)")

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

    private func stopSession(reason: StopReason) {
        guard isRecording else { return }
        isRecording = false
        stopReason = reason
        hotkey.watchClicks = false
        invalidateTimers()
        recorder.stop()
        refreshIcon()

        // Never discard the session just because no partial has arrived yet — on
        // the first recording the socket is often still connecting. Let it finish
        // and decide on the actual transcript instead.
        Log.write("stop (\(reason == .click ? "click" : "hotkey/pill")) — finalising, sawText=\(sawAnyText)")
        finaliseStartedAt = Date()
        logAudioState()
        hud.apply(.thinking)
        stt?.finish()
    }

    private func finishSession(with text: String) {
        stt = nil
        // The command phrase must never reach the target app.
        let trimmed = VoiceCommands.strip(text).trimmingCharacters(in: .whitespacesAndNewlines)
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

        remember(trimmed)
        hud.update(text: trimmed)

        if selfTestPath != nil {
            FileHandle.standardError.write(Data("SELFTEST RESULT: \(trimmed)\n".utf8))
            // Lets a test wait for background work (e.g. launching Grok) to finish.
            let hold = Double(ProcessInfo.processInfo.environment["QUILL_SELFTEST_HOLD"] ?? "") ?? 0
            guard ProcessInfo.processInfo.environment["QUILL_SELFTEST_INSERT"] != nil else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + hold) { NSApp.terminate(nil) }
                return
            }
            FileHandle.standardError.write(Data("SELFTEST FOCUS: \(Inserter.describeFocus())\n".utf8))
            Inserter.insert(trimmed, atEndOfField: Defaults.bool(Defaults.insertAtEnd)) { outcome in
                let method: String
                switch outcome.method {
                case .accessibility: method = "accessibility"
                case .clipboard:     method = "clipboard-fallback"
                case .blocked:       method = "BLOCKED (no Accessibility)"
                }
                self.hud.apply(.delivered(outcome.app))
                self.hud.update(text: trimmed)
                // Success is reported as soon as ⌘V is posted, so give the target
                // app a moment to actually apply it before reading back.
                Thread.sleep(forTimeInterval: 0.6)
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
            Inserter.insert(trimmed, atEndOfField: Defaults.bool(Defaults.insertAtEnd)) { outcome in
                switch outcome.method {
                case .accessibility, .clipboard:
                    if let started = self.finaliseStartedAt {
                        Log.write("  tail: stop → inserted in "
                            + String(format: "%.2fs", Date().timeIntervalSince(started)))
                    }
                    self.hud.apply(.delivered(outcome.app))
                    self.hud.update(text: trimmed)
                    self.hud.collapse(after: 0.7)
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
        hotkey.watchClicks = false
        invalidateTimers()
        recorder.stop()
        stt?.cancel()
        stt = nil
        refreshIcon()
        hud.apply(.notice(message))
        hud.collapse(after: 4)
    }

    private func invalidateTimers() {
        [silenceTimer, maxDurationTimer, tickTimer, selfTestTimer].forEach { $0?.invalidate() }
        silenceTimer = nil
        maxDurationTimer = nil
        tickTimer = nil
        selfTestTimer = nil
    }

    private func remember(_ text: String) {
        var history = UserDefaults.standard.stringArray(forKey: Defaults.history) ?? []
        history.insert(text, at: 0)
        UserDefaults.standard.set(Array(history.prefix(20)), forKey: Defaults.history)
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
