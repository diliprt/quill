import Cocoa

/// The corner surface. Always present, never takes focus.
///
/// Position is an anchor on the panel's bottom-right corner, stored and clamped
/// to the screen it lives on. It does not follow the mouse and it does not follow
/// the frontmost window — earlier it chased whichever screen the cursor was on,
/// which is what made it wander. Drag it anywhere; it stays put.
final class HUD {

    enum State {
        case idle
        case listening
        case thinking
        case delivered(String?)
        case notice(String)
    }

    private var panel: NSPanel?
    private let content = HUDView()
    private var collapseWork: DispatchWorkItem?
    private var state: State = .idle
    private var targetOverrideUntil: Date?

    private let compactSize = NSSize(width: 34, height: 22)
    private let expandedSize = NSSize(width: 430, height: 70)
    private let margin: CGFloat = 18

    private static let anchorKey = "hudAnchor"

    var onClick: () -> Void = {}

    /// When off, the pill is gone entirely while idle — the session bar still
    /// appears for the duration of a dictation, and the menu-bar item and trigger
    /// key are untouched.
    var showsIdlePill = true {
        didSet {
            guard oldValue != showsIdlePill else { return }
            if case .idle = state { apply(.idle, animated: false) }
        }
    }

    func install() {
        let panel = ensurePanel()
        content.onClick = { [weak self] in self?.onClick() }
        content.onMoved = { [weak self] in self?.storeAnchor() }
        apply(.idle, animated: false)
        panel.orderFrontRegardless()
    }

    func setCornerButton(visible: Bool) {
        showsIdlePill = visible
    }

    func apply(_ newState: State, animated: Bool = true) {
        collapseWork?.cancel()
        state = newState

        let panel = ensurePanel()
        content.apply(state: newState)

        let compact: Bool
        if case .idle = newState { compact = true } else { compact = false }

        // While anything other than the idle pill is showing, the panel must be
        // completely transparent to the mouse. Otherwise it eats the very click
        // that is meant to choose where the words go — and it sits in the corner,
        // right on top of most apps' input boxes.
        panel.ignoresMouseEvents = !compact

        // Position it either way, so it is already in the right place the moment a
        // session starts — but stay hidden if the idle pill is switched off.
        let target = frame(compact: compact)
        if compact && !showsIdlePill {
            panel.setFrame(target, display: false)
            panel.orderOut(nil)
            return
        }
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.19
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Amber pill = the keyboard trigger cannot work yet. Silent failure here is
    /// what makes a fresh install look broken.
    func setNeedsPermission(_ needed: Bool) {
        content.setNeedsPermission(needed)
        if case .idle = state { apply(.idle, animated: false) }
    }

    func update(text: String)      { content.setTranscript(text) }
    func update(level: Float)      { content.setLevel(level) }
    func update(elapsed: TimeInterval) { content.setElapsed(elapsed) }
    func update(target app: String?, icon: NSImage?) {
        guard Date() >= (targetOverrideUntil ?? .distantPast) else { return }
        content.setTarget(app, icon: icon)
    }

    /// Say something in the corner of the session bar for a moment, without
    /// leaving the listening state — the transcript keeps streaming underneath.
    func flashTarget(_ message: String, for seconds: TimeInterval = 2.5) {
        targetOverrideUntil = Date().addingTimeInterval(seconds)
        content.setTarget(message, icon: nil)
    }

    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        apply(state, animated: true)
    }

    func collapse(after delay: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply(.idle) }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Is this CoreGraphics-global point on the panel? Used to tell a click on the
    /// pill apart from a click on the thing you want the text to land in.
    func contains(globalPoint: CGPoint) -> Bool {
        guard let panel, panel.isVisible, !panel.ignoresMouseEvents,
              let primary = NSScreen.screens.first else { return false }
        let flipped = NSPoint(x: globalPoint.x, y: primary.frame.maxY - globalPoint.y)
        return panel.frame.insetBy(dx: -6, dy: -6).contains(flipped)
    }

    // MARK: Geometry

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: compactSize),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = content
        self.panel = panel
        return panel
    }

    /// Anchor = the bottom-right corner of the panel, in screen coordinates.
    private var anchor: NSPoint {
        if let stored = UserDefaults.standard.string(forKey: Self.anchorKey) {
            let point = NSPointFromString(stored)
            if point != .zero { return point }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        // Deliberately clear of the bottom edge: Grok Build and most chat apps put
        // their input box there, and the panel would sit on top of it.
        return NSPoint(x: visible.maxX - margin, y: visible.minY + 168)
    }

    private func storeAnchor() {
        guard let panel else { return }
        let point = NSPoint(x: panel.frame.maxX, y: panel.frame.minY)
        UserDefaults.standard.set(NSStringFromPoint(point), forKey: Self.anchorKey)
    }

    /// Keeps a frame wholly inside a single display.
    ///
    /// The display is chosen by where the frame's centre is, so a pill can still be
    /// dragged from one monitor to another — it just snaps fully onto whichever one
    /// it is mostly on, instead of being left cut in half across the seam.
    static func confine(_ rect: NSRect) -> NSRect {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.screens.min { a, b in
                distance(from: centre, to: a.frame) < distance(from: centre, to: b.frame)
            }
        guard let visible = screen?.visibleFrame else { return rect }

        var out = rect
        out.origin.x = min(max(out.origin.x, visible.minX + 6), visible.maxX - out.width - 6)
        out.origin.y = min(max(out.origin.y, visible.minY + 6), visible.maxY - out.height - 6)
        return out
    }

    private static func distance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private func frame(compact: Bool) -> NSRect {
        let size = compact ? compactSize : expandedSize
        let anchor = self.anchor

        // Whichever screen actually holds the anchor — never the mouse's screen.
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }

        _ = visible
        let rect = NSRect(x: anchor.x - size.width, y: anchor.y, width: size.width, height: size.height)
        return Self.confine(rect)
    }
}

// MARK: -

private final class HUDView: NSView {

    var onClick: () -> Void = {}
    var onMoved: () -> Void = {}

    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let compact = NSView()
    private let expanded = NSView()

    private let glyph = NSImageView()

    private let dot = NSView()
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let waveform = WaveformView()
    private let targetLabel = NSTextField(labelWithString: "")
    private let targetIcon = NSImageView()
    private let transcriptLabel = NSTextField(labelWithString: "")

    private var hovering = false
    private var isIdle = true
    private var needsPermission = false
    private var dragOrigin: NSPoint?
    private var didDrag = false

    private let fade = CAGradientLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Build

    private func build() {
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        pin(blur, to: self)

        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        tint.layer?.cornerCurve = .continuous
        tint.layer?.masksToBounds = true
        pin(tint, to: self)

        // — compact —
        var config = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        config = config.applying(.init(paletteColors: [.white]))
        glyph.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Quill")?
            .withSymbolConfiguration(config)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        compact.addSubview(glyph)
        pin(compact, to: self)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: compact.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: compact.centerYAnchor),
        ])

        // — expanded —
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        elapsedLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        elapsedLabel.translatesAutoresizingMaskIntoConstraints = false

        waveform.translatesAutoresizingMaskIntoConstraints = false

        targetLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        targetLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        targetLabel.alignment = .right
        targetLabel.lineBreakMode = .byTruncatingTail
        targetLabel.translatesAutoresizingMaskIntoConstraints = false

        targetIcon.imageScaling = .scaleProportionallyDown
        targetIcon.translatesAutoresizingMaskIntoConstraints = false

        transcriptLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        transcriptLabel.maximumNumberOfLines = 1
        transcriptLabel.lineBreakMode = .byTruncatingHead
        transcriptLabel.usesSingleLineMode = true
        transcriptLabel.wantsLayer = true
        transcriptLabel.translatesAutoresizingMaskIntoConstraints = false

        // Labels must yield, always. A long transcript that resists compression
        // makes AppKit widen the window itself, which walked the panel off-screen.
        for label in [transcriptLabel, targetLabel, elapsedLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }

        [dot, elapsedLabel, waveform, targetIcon, targetLabel, transcriptLabel].forEach(expanded.addSubview)
        pin(expanded, to: self)

        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),
            dot.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: 18),
            dot.topAnchor.constraint(equalTo: expanded.topAnchor, constant: 16),

            elapsedLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            elapsedLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            waveform.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 13),
            waveform.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 16),
            waveform.trailingAnchor.constraint(lessThanOrEqualTo: targetIcon.leadingAnchor, constant: -12),
            waveform.widthAnchor.constraint(equalToConstant: 156),

            targetLabel.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -18),
            targetLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            targetIcon.trailingAnchor.constraint(equalTo: targetLabel.leadingAnchor, constant: -6),
            targetIcon.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            targetIcon.widthAnchor.constraint(equalToConstant: 14),
            targetIcon.heightAnchor.constraint(equalToConstant: 14),

            transcriptLabel.leadingAnchor.constraint(equalTo: expanded.leadingAnchor, constant: 18),
            transcriptLabel.trailingAnchor.constraint(equalTo: expanded.trailingAnchor, constant: -18),
            transcriptLabel.bottomAnchor.constraint(equalTo: expanded.bottomAnchor, constant: -15),
            transcriptLabel.topAnchor.constraint(greaterThanOrEqualTo: dot.bottomAnchor, constant: 8),
        ])

        // Text scrolls in from the left under a soft fade rather than a hard cut.
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.07, 1]
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        transcriptLabel.layer?.mask = fade
    }

    private func pin(_ view: NSView, to parent: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ])
    }

    override func layout() {
        super.layout()
        let radius = isIdle ? bounds.height / 2 : 21
        blur.layer?.cornerRadius = radius
        tint.layer?.cornerRadius = radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = transcriptLabel.bounds
        transcriptLabel.preferredMaxLayoutWidth = transcriptLabel.bounds.width
        CATransaction.commit()
    }

    // MARK: State

    func apply(state: HUD.State) {
        switch state {
        case .idle:
            isIdle = true
            compact.isHidden = false
            expanded.isHidden = true
            stopPulse()
            waveform.reset()
            if needsPermission {
                glyph.contentTintColor = .systemOrange
                alphaValue = hovering ? 1.0 : 0.85
                toolTip = "Quill needs Accessibility to use the keyboard trigger — click to fix"
            } else {
                glyph.contentTintColor = NSColor.white.withAlphaComponent(0.85)
                // Deliberately faint at rest: it sits on screen all day and should
                // read as a dot you can ignore, not something asking for attention.
                alphaValue = hovering ? 0.92 : 0.22
                toolTip = "Tap the trigger key to dictate · drag to move"
            }

        case .listening:
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            startPulse()
            elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
            elapsedLabel.stringValue = "0:00"
            elapsedLabel.isHidden = false
            waveform.isHidden = false
            transcriptLabel.stringValue = "Listening… click where the text should go"
            transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.34)

        case .thinking:
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            elapsedLabel.stringValue = "Transcribing"
            elapsedLabel.isHidden = false

        case .delivered(let app):
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
            elapsedLabel.stringValue = "Inserted"
            elapsedLabel.isHidden = false
            targetLabel.stringValue = app ?? ""
            targetIcon.isHidden = (targetIcon.image == nil)

        case .notice(let message):
            enterExpanded()
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            stopPulse()
            waveform.isHidden = true
            elapsedLabel.isHidden = true
            targetLabel.stringValue = ""
            targetIcon.isHidden = true
            transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.78)
            transcriptLabel.stringValue = message
        }
        needsLayout = true
    }

    private func enterExpanded() {
        isIdle = false
        compact.isHidden = true
        expanded.isHidden = false
        alphaValue = 1
        toolTip = nil
    }

    func setNeedsPermission(_ needed: Bool) { needsPermission = needed }

    func setTranscript(_ text: String) {
        guard !isIdle else { return }
        transcriptLabel.textColor = NSColor.white.withAlphaComponent(0.94)
        transcriptLabel.stringValue = text
    }

    func setLevel(_ level: Float) { waveform.push(level) }

    func setElapsed(_ seconds: TimeInterval) {
        guard !isIdle else { return }
        let whole = Int(seconds)
        elapsedLabel.stringValue = String(format: "%d:%02d", whole / 60, whole % 60)
    }

    func setTarget(_ app: String?, icon: NSImage?) {
        guard !isIdle else { return }
        targetLabel.stringValue = app ?? ""
        targetIcon.image = icon
        targetIcon.isHidden = (icon == nil)
    }

    private func startPulse() {
        guard dot.layer?.animation(forKey: "pulse") == nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.2
        animation.duration = 0.72
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        dot.layer?.add(animation, forKey: "pulse")
    }

    private func stopPulse() {
        dot.layer?.removeAnimation(forKey: "pulse")
    }

    // MARK: Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if isIdle { animator().alphaValue = 0.92 }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if isIdle { animator().alphaValue = 0.22 }
    }

    override func mouseDown(with event: NSEvent) {
        didDrag = false
        dragOrigin = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - origin.x
        let dy = now.y - origin.y
        if !didDrag && (abs(dx) + abs(dy)) < 3 { return }
        didDrag = true

        var frame = window.frame
        frame.origin = NSPoint(x: frame.origin.x + dx, y: frame.origin.y + dy)
        window.setFrame(HUD.confine(frame), display: true)
        dragOrigin = now
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        if didDrag {
            onMoved()
        } else {
            onClick()
        }
        didDrag = false
    }
}

// MARK: -

/// A rolling, mirrored level meter. Smoothed so speech reads as a shape rather
/// than a flicker.
private final class WaveformView: NSView {

    private var samples = [CGFloat](repeating: 0, count: 46)
    private var smoothed: CGFloat = 0

    func push(_ level: Float) {
        let value = max(0, min(1, CGFloat(level)))
        smoothed = smoothed * 0.55 + value * 0.45
        samples.removeFirst()
        samples.append(smoothed)
        needsDisplay = true
    }

    func reset() {
        samples = [CGFloat](repeating: 0, count: samples.count)
        smoothed = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 2
        let spacing = (bounds.width - CGFloat(samples.count) * barWidth) / CGFloat(samples.count - 1)
        let midY = bounds.midY

        for (index, sample) in samples.enumerated() {
            // Newest sample on the right, and older samples fade back.
            let recency = CGFloat(index) / CGFloat(samples.count - 1)
            let alpha = 0.22 + 0.63 * recency
            NSColor.white.withAlphaComponent(alpha).setFill()

            let height = max(3, bounds.height * (0.19 + 0.81 * sample))
            let rect = NSRect(x: CGFloat(index) * (barWidth + spacing),
                              y: midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
