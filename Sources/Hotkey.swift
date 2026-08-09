import Cocoa
import QuartzCore

/// Which dictation path a trigger starts.
///
/// - `raw`: speech-to-text only, insert as spoken
/// - `smart`: speech-to-text then Grok cleanup, then insert
enum DictationLane: String {
    case raw
    case smart
}

/// The global trigger. Bare modifier taps are used deliberately: a modifier
/// pressed on its own means nothing to macOS or to any app, so a double-tap can
/// never shadow a shortcut in whatever you are typing into — including Grok
/// Build's own Ctrl+Space.
enum Trigger: String, CaseIterable {
    case rightCommand
    case rightOption
    case control
    case fnGlobe
    case f5

    var title: String {
        switch self {
        case .rightCommand: return "Right ⌘"
        case .rightOption:  return "Right ⌥"
        case .control:      return "Control ⌃"
        case .fnGlobe:      return "🌐 (fn)"
        case .f5:           return "F5"
        }
    }

    /// How to describe the gesture, given the single/double/hold setting.
    func gesture(mode: GestureMode) -> String {
        switch mode {
        case .hold:
            return self == .f5 ? "Hold F5" : "Hold " + title
        case .single:
            return self == .f5 ? "Press F5" : "Tap " + title
        case .double:
            return self == .f5 ? "Press F5" : "Double-tap " + title
        }
    }

    /// Back-compat wrapper for call sites that still pass the old bool.
    func gesture(singleTap: Bool) -> String {
        gesture(mode: singleTap ? .single : .double)
    }

    var shortTitle: String {
        switch self {
        case .rightCommand: return "⌘⌘"
        case .rightOption:  return "⌥⌥"
        case .control:      return "⌃"
        case .fnGlobe:      return "🌐"
        case .f5:           return "F5"
        }
    }

    /// Accepted keyCodes + the flag that means "this key is down".
    /// Control matches BOTH controls: MacBook keyboards have no right Control at
    /// all, so a right-only match would simply never fire on this machine.
    var modifier: (keyCodes: Set<Int64>, flag: CGEventFlags)? {
        switch self {
        case .rightCommand: return ([54], .maskCommand)
        case .rightOption:  return ([61], .maskAlternate)
        case .control:      return ([59, 62], .maskControl)
        case .fnGlobe:      return ([63], .maskSecondaryFn)
        case .f5:           return nil
        }
    }

    /// A different key suitable when this one is already claimed.
    func alternate(excluding other: Trigger?) -> Trigger {
        for candidate in Trigger.allCases where candidate != self && candidate != other {
            return candidate
        }
        return self == .control ? .rightOption : .control
    }
}

/// How the trigger key is used: tap to toggle, double-tap to toggle, or hold
/// (push-to-talk) — press starts, release stops and inserts.
enum GestureMode: String, CaseIterable {
    case single
    case double
    case hold

    var menuTitle: String {
        switch self {
        case .single: return "Single tap (toggle)"
        case .double: return "Double tap (toggle)"
        case .hold:   return "Hold to talk"
        }
    }

    var toolTip: String {
        switch self {
        case .single:
            return "A tap only counts if nothing else is pressed while the key is held, "
                + "so ⌃C and friends never trigger it."
        case .double:
            return "Two quick taps of the trigger key start or stop dictation."
        case .hold:
            return "Press and hold to talk; release to stop and insert the text. "
                + "Chords like ⌃C never start a session."
        }
    }
}

/// Per-key gesture state (primary raw key and optional smart-cleanup key).
private final class TriggerBinding {
    let lane: DictationLane
    var trigger: Trigger

    var lastTapAt: CFTimeInterval = 0
    var sawKeyDownSinceTap = false
    var pressedAt: CFTimeInterval = 0
    var activityAtPress: UInt64 = 0
    var holdArmed = false
    var holdActive = false
    var holdStartWork: DispatchWorkItem?
    var holdStartedAt: CFTimeInterval = 0
    var chordPoll: Timer?
    var f5HoldDown = false

    init(lane: DictationLane, trigger: Trigger) {
        self.lane = lane
        self.trigger = trigger
    }

    func resetHold() {
        holdStartWork?.cancel()
        holdStartWork = nil
        chordPoll?.invalidate()
        chordPoll = nil
        holdArmed = false
        holdActive = false
        holdStartedAt = 0
        f5HoldDown = false
        pressedAt = 0
    }

    func cancelHoldArm() {
        holdStartWork?.cancel()
        holdStartWork = nil
        chordPoll?.invalidate()
        chordPoll = nil
        holdArmed = false
        // keep holdActive — arm cancel alone doesn't end a live hold
        pressedAt = 0
    }
}

/// Watches the whole system for the trigger(s), and for the click that ends a
/// recording.
///
/// This is an ACTIVE tap that returns events untouched, not a listen-only one.
/// Behaviourally identical, but the permission differs: listen-only taps require
/// Input Monitoring, active taps run on the Accessibility grant. Listen-only made
/// macOS prompt for a permission that does not even appear in the Accessibility
/// list, and until it was granted the tap silently received nothing.
final class DoubleTapRightCommand {

    private let window: CFTimeInterval = 0.42
    private static let f5KeyCode: Int64 = 96
    private static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
    /// How long the bare trigger must be held before dictation starts.
    /// Control is shared with Grok Build (⌃M, ⌃O, ⌃P, …) and terminal chords,
    /// so it uses a longer delay than other triggers.
    private var holdStartDelay: CFTimeInterval {
        switch trigger {
        case .control, .fnGlobe: return 0.45
        default: return 0.32
        }
    }
    /// After hold starts, release sooner than this is treated as accidental (cancel).
    private let minHoldAfterStart: CFTimeInterval = 0.20
    private let tapMaxHold: CFTimeInterval = 0.35

    private var tap: CFMachPort?
    private var loggedFirstEvent = false

    private let raw = TriggerBinding(lane: .raw, trigger: .control)
    private var smart: TriggerBinding?

    /// Primary (simple dictation) key.
    var trigger: Trigger {
        get { raw.trigger }
        set { raw.trigger = newValue }
    }

    /// Optional second key for smart (Grok-cleaned) dictation. Nil disables it.
    var smartTrigger: Trigger? {
        get { smart?.trigger }
        set {
            if let value = newValue {
                if smart == nil {
                    smart = TriggerBinding(lane: .smart, trigger: value)
                } else {
                    smart?.trigger = value
                }
            } else {
                smart?.resetHold()
                smart = nil
            }
        }
    }

    /// Fire on a single quick tap rather than a double-tap.
    var singleTap = false

    /// Push-to-talk: key down starts recording, key up stops and inserts.
    var holdToTalk = false

    private static let watchedActivity: [CGEventType] = [
        .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
    ]

    private static func activityCounter() -> UInt64 {
        var total: UInt64 = 0
        for type in watchedActivity {
            total &+= UInt64(CGEventSource.counterForEventType(.combinedSessionState, eventType: type))
            total &+= UInt64(CGEventSource.counterForEventType(.hidSystemState, eventType: type))
        }
        return total
    }

    private let debugKeys = ProcessInfo.processInfo.environment["QUILL_DEBUG_KEYS"] != nil
        || UserDefaults.standard.bool(forKey: "debugKeys")

    var onTrigger: (DictationLane) -> Void = { _ in }
    var onHoldStart: (DictationLane) -> Void = { _ in }
    var onHoldEnd: (DictationLane) -> Void = { _ in }
    /// Hold was aborted (chord / accidental short press) — discard, don't insert.
    var onHoldCancel: (DictationLane) -> Void = { _ in }
    var onFirstEvent: () -> Void = {}

    var onClickAnywhere: (CGPoint) -> Void = { _ in }
    var watchClicks = false
    var onCancel: () -> Void = {}

    private static let escapeKeyCode: Int64 = 53
    private var cancelTimer: Timer?
    private var escapeWasDown = false

    /// True while any hold-to-talk session is live.
    var isHolding: Bool {
        raw.holdActive || (smart?.holdActive == true)
    }

    /// Which lane is currently holding, if any.
    var activeHoldLane: DictationLane? {
        if raw.holdActive { return .raw }
        if smart?.holdActive == true { return .smart }
        return nil
    }

    private var bindings: [TriggerBinding] {
        if let smart { return [raw, smart] }
        return [raw]
    }

    func watchForCancel(_ on: Bool) {
        cancelTimer?.invalidate()
        cancelTimer = nil
        escapeWasDown = false
        guard on else { return }

        cancelTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.escapeKeyCode))
            if down, !self.escapeWasDown {
                self.escapeWasDown = true
                DispatchQueue.main.async { self.onCancel() }
            } else if !down {
                self.escapeWasDown = false
            }
        }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
                 | CGEventMask(1 << CGEventType.keyDown.rawValue)
                 | CGEventMask(1 << CGEventType.keyUp.rawValue)
                 | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                var swallow = false
                if let refcon {
                    swallow = Unmanaged<DoubleTapRightCommand>.fromOpaque(refcon)
                        .takeUnretainedValue()
                        .handle(type, event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        loggedFirstEvent = false
        for b in bindings { b.resetHold() }
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        tap = nil
    }

    func resetHoldState() {
        for b in bindings { b.resetHold() }
    }

    private func binding(matching code: Int64, flagCheck flags: CGEventFlags? = nil) -> TriggerBinding? {
        for b in bindings {
            if b.trigger == .f5, code == Self.f5KeyCode { return b }
            if let spec = b.trigger.modifier, spec.keyCodes.contains(code) {
                if let flags, !flags.contains(spec.flag), flags.intersection(spec.flag).isEmpty {
                    // On release, flag may already be gone — still match by keycode.
                }
                return b
            }
        }
        return nil
    }

    private func bindingForF5() -> TriggerBinding? {
        bindings.first { $0.trigger == .f5 }
    }

    private func triggerKeyIsDown(_ binding: TriggerBinding) -> Bool {
        if binding.trigger == .f5 {
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Self.f5KeyCode))
        }
        guard let spec = binding.trigger.modifier else { return false }
        if CGEventSource.flagsState(.combinedSessionState).contains(spec.flag) {
            return true
        }
        for code in spec.keyCodes {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) {
                return true
            }
        }
        return false
    }

    private func armHoldStart(_ binding: TriggerBinding) {
        binding.cancelHoldArm()
        binding.holdArmed = true
        binding.holdActive = false
        binding.holdStartedAt = 0
        binding.pressedAt = CACurrentMediaTime()
        binding.activityAtPress = Self.activityCounter()
        binding.sawKeyDownSinceTap = false

        // Poll for chords while waiting: keyDown may not reach us without Input
        // Monitoring, but activity counters still move when ⌃C is pressed.
        binding.chordPoll?.invalidate()
        binding.chordPoll = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self, weak binding] _ in
            guard let self, let binding else { return }
            self.pollHoldChord(binding)
        }

        let work = DispatchWorkItem { [weak self, weak binding] in
            guard let self, let binding, binding.holdArmed, self.holdToTalk else { return }
            if self.holdIsChorded(binding) {
                if self.debugKeys {
                    Log.write("    [keys] hold arm aborted (\(binding.lane.rawValue)) — chord/activity")
                }
                binding.cancelHoldArm()
                return
            }
            guard self.triggerKeyIsDown(binding) else {
                binding.cancelHoldArm()
                return
            }
            // Still bare? No other modifiers joining the chord.
            guard !self.extraModifiersDown(beyond: binding) else {
                binding.cancelHoldArm()
                return
            }
            binding.holdArmed = false
            binding.holdActive = true
            binding.holdStartedAt = CACurrentMediaTime()
            binding.chordPoll?.invalidate()
            // Keep polling while active so a late chord cancels the session.
            binding.chordPoll = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self, weak binding] _ in
                guard let self, let binding, binding.holdActive else { return }
                self.pollHoldChord(binding)
            }
            if self.debugKeys { Log.write("    [keys] hold START \(binding.lane.rawValue)") }
            Log.write("hold armed → start after \(String(format: "%.2f", self.holdStartDelay))s (\(binding.lane.rawValue))")
            self.onHoldStart(binding.lane)
        }
        binding.holdStartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdStartDelay, execute: work)
    }

    private func holdIsChorded(_ binding: TriggerBinding) -> Bool {
        if binding.sawKeyDownSinceTap { return true }
        if Self.activityCounter() != binding.activityAtPress { return true }
        if extraModifiersDown(beyond: binding) { return true }
        // ⌃M / ⌃C: second key may not deliver keyDown to our tap without Input
        // Monitoring — HID keyState still sees it.
        if nonModifierKeyDown() { return true }
        return false
    }

    /// Any modifier flag that isn't part of this trigger's bare press.
    /// Critical for Grok: ⌃⌘… and ⌃⇧… must never start Control hold-to-talk.
    private func extraModifiersDown(beyond binding: TriggerBinding) -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let allowed: CGEventFlags
        if let spec = binding.trigger.modifier {
            allowed = spec.flag
        } else {
            allowed = []
        }
        let interesting: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        let extra = flags.intersection(interesting).subtracting(allowed)
        return !extra.isEmpty
    }

    /// True if any non-modifier key appears to be down (chord like ⌃C / ⌃M).
    /// Best-effort via HID key state for common keys; activity counters cover the rest.
    private func nonModifierKeyDown() -> Bool {
        // Letters A–Z (0–25), digits, common punctuation — enough for shortcut chords.
        for code: CGKeyCode in 0...50 {
            if code == 55 || code == 54 || code == 56 || code == 57 || code == 58
                || code == 59 || code == 60 || code == 61 || code == 62 || code == 63 {
                continue // modifiers
            }
            if CGEventSource.keyState(.combinedSessionState, key: code) {
                return true
            }
        }
        return false
    }

    private func pollHoldChord(_ binding: TriggerBinding) {
        guard holdToTalk else { return }
        if binding.holdArmed {
            if holdIsChorded(binding) || !triggerKeyIsDown(binding) {
                if debugKeys { Log.write("    [keys] hold arm cancelled mid-wait (\(binding.lane.rawValue))") }
                binding.cancelHoldArm()
            }
            return
        }
        if binding.holdActive, holdIsChorded(binding) {
            // Late chord after hold started (e.g. hold ⌃ then press C) — abort.
            Log.write("hold cancelled — chord while active (\(binding.lane.rawValue))")
            let lane = binding.lane
            binding.resetHold()
            DispatchQueue.main.async { [weak self] in self?.onHoldCancel(lane) }
        }
    }

    private func finishHoldIfActive(_ binding: TriggerBinding) {
        let wasActive = binding.holdActive
        let startedAt = binding.holdStartedAt
        let pressedAt = binding.pressedAt
        binding.chordPoll?.invalidate()
        binding.chordPoll = nil
        binding.holdStartWork?.cancel()
        binding.holdStartWork = nil
        binding.holdArmed = false

        guard wasActive else {
            // Released before hold delay — treat as tap / nothing; do not start.
            binding.holdActive = false
            binding.pressedAt = 0
            return
        }

        binding.holdActive = false
        let now = CACurrentMediaTime()
        let heldAfterStart = startedAt > 0 ? now - startedAt : 0
        let totalPress = pressedAt > 0 ? now - pressedAt : heldAfterStart
        // Accidental blip: started then released almost immediately.
        if heldAfterStart < minHoldAfterStart {
            Log.write("hold cancelled — too short (\(String(format: "%.2f", totalPress))s press, \(String(format: "%.2f", heldAfterStart))s active)")
            binding.holdStartedAt = 0
            binding.pressedAt = 0
            let lane = binding.lane
            DispatchQueue.main.async { [weak self] in self?.onHoldCancel(lane) }
            return
        }

        if debugKeys { Log.write("    [keys] hold END \(binding.lane.rawValue)") }
        binding.holdStartedAt = 0
        binding.pressedAt = 0
        let lane = binding.lane
        DispatchQueue.main.async { [weak self] in self?.onHoldEnd(lane) }
    }

    /// Returns true to swallow the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if !loggedFirstEvent {
            loggedFirstEvent = true
            DispatchQueue.main.async { [weak self] in self?.onFirstEvent() }
        }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }

        if type == .leftMouseDown {
            for b in bindings where b.holdArmed { b.cancelHoldArm() }
            guard watchClicks else { return false }
            let location = event.location
            DispatchQueue.main.async { [weak self] in self?.onClickAnywhere(location) }
            return false
        }

        if type == .keyUp {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if holdToTalk, let b = bindingForF5(), code == Self.f5KeyCode, b.f5HoldDown {
                b.f5HoldDown = false
                finishHoldIfActive(b)
                return true
            }
            return false
        }

        if type == .keyDown {
            let code = event.getIntegerValueField(.keyboardEventKeycode)

            if code == Self.escapeKeyCode, cancelTimer != nil, !escapeWasDown {
                escapeWasDown = true
                DispatchQueue.main.async { [weak self] in self?.onCancel() }
                return false
            }
            let bareKey = event.flags
                .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
                .isEmpty

            if let b = bindingForF5(), code == Self.f5KeyCode, bareKey {
                if holdToTalk {
                    if b.f5HoldDown || b.holdActive || b.holdArmed { return true }
                    b.f5HoldDown = true
                    armHoldStart(b)
                    return true
                }
                let lane = b.lane
                DispatchQueue.main.async { [weak self] in self?.onTrigger(lane) }
                return true
            }

            if debugKeys { Log.write("    [keys] keyDown code=\(code) → invalidating taps/holds") }
            for b in bindings {
                b.sawKeyDownSinceTap = true
                b.lastTapAt = 0
                if b.holdArmed {
                    b.cancelHoldArm()
                } else if b.holdActive, holdToTalk {
                    // Chord while holding the trigger (⌃ then C): cancel dictation.
                    Log.write("hold cancelled — keyDown while active (\(b.lane.rawValue))")
                    let lane = b.lane
                    b.resetHold()
                    DispatchQueue.main.async { [weak self] in self?.onHoldCancel(lane) }
                }
            }
            return false
        }

        guard type == .flagsChanged else { return false }

        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Find a binding that owns this keycode.
        guard let binding = bindings.first(where: { b in
            guard let spec = b.trigger.modifier else { return false }
            return spec.keyCodes.contains(code)
        }) else {
            // Foreign modifier — chord for any armed/active hold.
            if Self.modifierKeyCodes.contains(code), !flags.isEmpty {
                for b in bindings {
                    b.lastTapAt = 0
                    if b.holdArmed {
                        b.cancelHoldArm()
                    } else if b.holdActive, holdToTalk {
                        Log.write("hold cancelled — other modifier (\(b.lane.rawValue))")
                        let lane = b.lane
                        b.resetHold()
                        DispatchQueue.main.async { [weak self] in self?.onHoldCancel(lane) }
                    } else {
                        b.pressedAt = 0
                    }
                }
            }
            return false
        }

        guard let spec = binding.trigger.modifier else { return false }
        let now = CACurrentMediaTime()
        let isDown = flags.contains(spec.flag)

        if debugKeys {
            Log.write("    [keys] \(binding.lane.rawValue) \(isDown ? "DOWN" : "UP") "
                + "code=\(code) hold=\(holdToTalk)")
        }

        if isDown {
            if holdToTalk {
                if binding.holdActive || binding.holdArmed { return false }
                armHoldStart(binding)
                return false
            }
            if singleTap {
                binding.pressedAt = now
                binding.activityAtPress = Self.activityCounter()
                binding.sawKeyDownSinceTap = false
            } else if now - binding.lastTapAt < window && !binding.sawKeyDownSinceTap {
                binding.lastTapAt = 0
                binding.sawKeyDownSinceTap = false
                let lane = binding.lane
                DispatchQueue.main.async { [weak self] in self?.onTrigger(lane) }
            } else {
                binding.lastTapAt = now
                binding.sawKeyDownSinceTap = false
            }
            return false
        }

        // Release.
        if holdToTalk {
            finishHoldIfActive(binding)
            binding.cancelHoldArm()
            return false
        }

        let activityNow = Self.activityCounter()
        let didSomethingElse = activityNow != binding.activityAtPress

        if singleTap, binding.pressedAt > 0, !binding.sawKeyDownSinceTap,
           !didSomethingElse, now - binding.pressedAt < tapMaxHold {
            binding.pressedAt = 0
            let lane = binding.lane
            DispatchQueue.main.async { [weak self] in self?.onTrigger(lane) }
        }
        return false
    }
}
