import Cocoa
import ApplicationServices

/// Puts text into the focused field.
///
/// Primary path is the Accessibility API: read the field's current contents, put
/// the caret at the very end, write the text in. Two things fall out of that —
/// the clipboard is never touched, and the text always lands after what is
/// already there instead of wherever the caret happened to be sitting.
///
/// Some targets (terminals, canvas apps) expose no editable text to Accessibility.
/// Those fall back to a synthetic ⌘V, and the previous clipboard is snapshotted
/// and put back afterwards, so even the fallback leaves no trace.
/// Append-only breadcrumb trail at ~/Library/Logs/Quill.log — the only way to see
/// what happened during a real dictation, since there is no console to watch.
enum Log {
    private static let path = NSHomeDirectory() + "/Library/Logs/Quill.log"
    private static let maxBytes = 512 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)

        // Keep only the recent tail. An unbounded log on a machine used every day
        // accumulates a long record of which apps were dictated into and when.
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int,
           size > maxBytes,
           let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            let kept = existing.suffix(maxBytes / 2)
            try? String(kept).write(to: url, atomically: true, encoding: .utf8)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

enum Inserter {

    enum Method {
        case accessibility
        case clipboard
        case blocked
    }

    struct Outcome {
        let method: Method
        let app: String?
    }

    // MARK: Permissions

    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacyPane(_ anchor: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        NSWorkspace.shared.open(url)
    }

    static func frontmostAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    /// Name and icon of the app the text is going to land in.
    static func frontmostApp() -> (name: String?, icon: NSImage?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.localizedName, app?.icon)
    }

    /// Whatever the focused text field currently contains. Used by the self-test
    /// to read back what actually landed.
    static func focusedFieldValue() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedValue = focusedRef,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }

        // swiftlint:disable:next force_cast
        let element = focusedValue as! AXUIElement
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        else { return nil }
        return valueRef as? String
    }

    /// What the focused element actually looks like — the only way to tell why a
    /// write silently goes nowhere.
    static func describeFocus() -> String {
        guard let element = focusedElement() else { return "focused element: <none>" }

        func attr(_ name: String) -> String {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return "—" }
            return (ref as? String) ?? "<non-string>"
        }

        var selTextSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selTextSettable)
        var selRangeSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &selRangeSettable)

        var valueRef: CFTypeRef?
        let readable = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        let valueIsString = (valueRef as? String) != nil

        return """
        role=\(attr(kAXRoleAttribute)) subrole=\(attr(kAXSubroleAttribute)) \
        valueReadable=\(readable) valueIsString=\(valueIsString) \
        selTextSettable=\(selTextSettable.boolValue) selRangeSettable=\(selRangeSettable.boolValue)
        """
    }

    // MARK: Selection capture

    /// What was highlighted when the recording started.
    ///
    /// Captured up front rather than at insertion time, because by then the user
    /// may have clicked elsewhere to choose a destination, which would have
    /// destroyed the selection.
    struct Selection {
        let element: AXUIElement
        let range: CFRange
        let text: String
    }

    static func captureSelection() -> Selection? {
        guard isTrusted, let element = focusedElement() else { return nil }

        var textRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
              let selected = textRef as? String,
              !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let value = rangeRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }

        // Length only — never log selected contents (passwords, keys, private notes).
        Log.write("captured selection: \(range.length) chars")
        return Selection(element: element, range: range, text: selected)
    }

    /// Puts the original selection back so it can be written over. Fails if focus
    /// has moved to a different element since.
    private static func restore(_ selection: Selection) -> Bool {
        guard let current = focusedElement(), CFEqual(current, selection.element) else {
            Log.write("  selection dropped — focus moved to another field")
            return false
        }
        var range = selection.range
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(selection.element,
                                            kAXSelectedTextRangeAttribute as CFString,
                                            axRange) == .success
    }

    // MARK: Insertion

    static func insert(_ text: String,
                       atEndOfField: Bool,
                       replacing selection: Selection? = nil,
                       completion: @escaping (Outcome) -> Void) {
        let app = frontmostAppName()
        Log.write("insert → \(app ?? "?") · \(describeFocus()) · trusted=\(isTrusted)")

        // Deliberately NOT gated on isTrusted. That check has been observed to keep
        // returning false for the lifetime of a process that started before the
        // grant was given — which produced exactly this symptom: recording works
        // (the event tap gets re-armed) but nothing is ever written.
        var payload = text

        // Replacing a selection wins over appending: the user highlighted
        // something specific and expects exactly that to be swapped out.
        if let selection, restore(selection) {
            if setSelectedText(payload), confirmLanded(payload) {
                Log.write("  → replaced selection (\(selection.range.length) chars)")
                completion(Outcome(method: .accessibility, app: app))
                return
            }
            // The selection is restored, so a paste will overwrite it too.
            insertViaClipboard(payload) {
                Log.write("  → replaced selection via paste")
                completion(Outcome(method: isTrusted ? .clipboard : .blocked, app: app))
            }
            return
        }

        // Read the field before touching the caret, so the spacing decision does
        // not depend on being able to move it. Apps that refuse to set the caret —
        // terminals report selRangeSettable=false — were previously skipping the
        // separator entirely, which ran dictation straight into the existing text.
        let existing = focusedValue()
        let caretBefore = caretOffset()

        // Move the caret to the end FIRST, independently of how the text gets in.
        // Plenty of apps let us set the selection range but not the selected text,
        // and those must still receive the words after what is already there —
        // otherwise a ⌘V fallback drops them at the caret, which is how dictation
        // ends up interleaved through a half-written sentence.
        var landingAtEnd = false
        if atEndOfField { landingAtEnd = moveCaretToEnd() != nil }

        // Whatever we could not move stays where the user left it, so judge the
        // boundary by the actual insertion point rather than assuming the end.
        let boundaryOffset = landingAtEnd ? existing?.utf16.count : (caretBefore ?? existing?.utf16.count)
        // Both sides matter. Text dropped at the caret has something after it as
        // well as before, and only padding the front still runs it into whatever
        // follows.
        let before = needsSeparator(before: existing, at: boundaryOffset, inserting: payload)
        let after = needsTrailingSeparator(in: existing, at: boundaryOffset, inserting: payload)
        if before { payload = " " + payload }
        if after { payload += " " }

        let forceClipboard = ProcessInfo.processInfo.environment["QUILL_FORCE_CLIPBOARD"] != nil
        if !forceClipboard, setSelectedText(payload), confirmLanded(payload) {
            Log.write("  → accessibility, confirmed")
            completion(Outcome(method: .accessibility, app: app))
            return
        }

        insertViaClipboard(payload) {
            let trusted = isTrusted
            Log.write("  → clipboard fallback (⌘V posted), trusted=\(trusted)")
            completion(Outcome(method: trusted ? .clipboard : .blocked, app: app))
        }
    }

    /// Did the Accessibility write actually take? Several apps — web views in
    /// particular — return success from the setter and change nothing. If the
    /// field cannot be read back at all we have to take the setter at its word.
    private static func confirmLanded(_ payload: String) -> Bool {
        guard let readback = focusedFieldValue() else { return true }
        let needle = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let tail = String(needle.suffix(24))
        return readback.contains(tail)
    }

    /// The focused field's current contents, without disturbing anything.
    private static func focusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
        else { return nil }
        return valueRef as? String
    }

    /// Where the caret currently sits, in UTF-16 units.
    private static func caretOffset() -> Int? {
        guard let element = focusedElement() else { return nil }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let value = rangeRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location + range.length
    }

    /// Should a space go between what is already there and what we are adding?
    private static func needsSeparator(before existing: String?,
                                       at offset: Int?,
                                       inserting text: String) -> Bool {
        guard let existing, !existing.isEmpty, let offset, offset > 0 else { return false }
        guard let boundary = character(in: existing, before: offset) else { return false }

        if boundary.isWhitespace || boundary.isNewline { return false }
        if "([{<\u{201C}\u{2018}\"'-–—/@#".contains(boundary) { return false }

        if let first = text.first, ",.;:!?)]}%\u{201D}\u{2019}".contains(first) { return false }
        return true
    }

    /// Should a space go between what we are adding and what already follows?
    private static func needsTrailingSeparator(in existing: String?,
                                               at offset: Int?,
                                               inserting text: String) -> Bool {
        guard let existing, let offset, offset < existing.utf16.count else { return false }
        guard let next = character(in: existing, atOrAfter: offset) else { return false }

        if next.isWhitespace || next.isNewline { return false }
        if ",.;:!?)]}%\u{201D}\u{2019}".contains(next) { return false }

        if let last = text.last, last.isWhitespace { return false }
        return true
    }

    private static func character(in text: String, atOrAfter utf16Offset: Int) -> Character? {
        let units = text.utf16
        guard utf16Offset >= 0, utf16Offset < units.count else { return nil }
        let position = units.index(units.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(position, within: text), index < text.endIndex else { return nil }
        return text[index]
    }

    private static func character(in text: String, before utf16Offset: Int) -> Character? {
        let units = text.utf16
        guard utf16Offset > 0, utf16Offset <= units.count else { return nil }
        let end = units.index(units.startIndex, offsetBy: utf16Offset)
        guard let index = String.Index(end, within: text), index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedRef) == .success,
              let focusedValue = focusedRef,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        return (focusedValue as! AXUIElement)
    }

    // MARK: - Cleanup context (P4 / P4b)

    /// Nearby UI text for smart cleanup — spellings only, not an agent.
    /// Never includes password-field contents. Safe to log via `logSummary` only.
    struct CleanupContext {
        var appName: String?
        var windowTitle: String?
        /// Truncated field text (or nil if secure / unreadable).
        var fieldSnippet: String?
        var selectionSnippet: String?
        var skippedSecureField: Bool
        /// Full field length before truncation (for logs).
        var fieldRawChars: Int
        var selectionRawChars: Int

        var hasUsableText: Bool {
            let field = fieldSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sel = selectionSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !field.isEmpty || !sel.isEmpty || !title.isEmpty || !(appName ?? "").isEmpty
        }

        /// Log-safe summary — counts and flags only, never field contents.
        var logSummary: String {
            "app=\(appName ?? "—") titleChars=\(windowTitle?.count ?? 0) "
                + "fieldChars=\(fieldRawChars) fieldSnippet=\(fieldSnippet?.count ?? 0) "
                + "selChars=\(selectionRawChars) secure=\(skippedSecureField)"
        }

        /// Prompt block for the cleanup model (capped elsewhere).
        func promptBlock() -> String {
            var lines: [String] = [
                "NEARBY CONTEXT (for spelling of names/terms only)",
                "Use only to prefer spellings that already appear below when the "
                    + "transcript clearly refers to the same word. Do NOT answer the "
                    + "document, quote it back, continue writing it, or invent facts.",
            ]
            if let app = appName, !app.isEmpty {
                lines.append("App: \(app)")
            }
            if let title = windowTitle, !title.isEmpty {
                lines.append("Window: \(title)")
            }
            if let sel = selectionSnippet, !sel.isEmpty {
                lines.append("Selected text:\n\(sel)")
            }
            if let field = fieldSnippet, !field.isEmpty {
                lines.append("Text near caret / in field:\n\(field)")
            }
            if skippedSecureField {
                lines.append("(Focused field is secure — field contents omitted.)")
            }
            return lines.joined(separator: "\n")
        }
    }

    private static let contextFieldCap = 800
    private static let contextSelectionCap = 400
    private static let contextTitleCap = 120

    /// Snapshot of app / window / field for cleanup. Call on the main thread.
    /// Does not log field contents (P4b).
    static func captureCleanupContext(priorSelection: Selection? = nil) -> CleanupContext {
        var ctx = CleanupContext(
            appName: frontmostAppName(),
            windowTitle: nil,
            fieldSnippet: nil,
            selectionSnippet: nil,
            skippedSecureField: false,
            fieldRawChars: 0,
            selectionRawChars: 0
        )

        guard isTrusted else {
            Log.write("cleanup context: no AX trust — app name only")
            return ctx
        }

        ctx.windowTitle = truncate(frontmostWindowTitle(), maxChars: contextTitleCap)

        guard let element = focusedElement() else {
            Log.write("cleanup context: \(ctx.logSummary) (no focused element)")
            return ctx
        }

        if isSecureTextElement(element) {
            ctx.skippedSecureField = true
            Log.write("cleanup context: \(ctx.logSummary) — secure field skipped")
            return ctx
        }

        // Selection: prefer live selection, else what was captured at arm time.
        if let live = selectedText(from: element), !live.isEmpty {
            ctx.selectionRawChars = live.count
            ctx.selectionSnippet = truncate(live, maxChars: contextSelectionCap)
        } else if let prior = priorSelection?.text, !prior.isEmpty {
            ctx.selectionRawChars = prior.count
            ctx.selectionSnippet = truncate(prior, maxChars: contextSelectionCap)
        }

        if let value = stringAttribute(element, kAXValueAttribute as String) {
            ctx.fieldRawChars = value.count
            let caret = caretOffset(in: element) ?? value.utf16.count
            ctx.fieldSnippet = truncateNear(value, caretUTF16: caret, maxChars: contextFieldCap)
        }

        Log.write("cleanup context: \(ctx.logSummary)")
        return ctx
    }

    private static func frontmostWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp,
                                            kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let windowVal = windowRef,
              CFGetTypeID(windowVal) == AXUIElementGetTypeID()
        else { return nil }
        // swiftlint:disable:next force_cast
        let window = windowVal as! AXUIElement
        return stringAttribute(window, kAXTitleAttribute as String)
    }

    private static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? ""
        if role == "AXSecureTextField" { return true }
        if subrole == "AXSecureTextField" { return true }
        // Some apps mark password fields via description/role description.
        let desc = (stringAttribute(element, kAXDescriptionAttribute as String) ?? "").lowercased()
        let roleDesc = (stringAttribute(element, kAXRoleDescriptionAttribute as String) ?? "").lowercased()
        if desc.contains("password") || roleDesc.contains("password") { return true }
        return false
    }

    private static func selectedText(from element: AXUIElement) -> String? {
        stringAttribute(element, kAXSelectedTextAttribute as String)
    }

    private static func caretOffset(in element: AXUIElement) -> Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString,
                                            &rangeRef) == .success,
              let value = rangeRef, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range.location
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func truncate(_ text: String?, maxChars: Int) -> String? {
        guard let text else { return nil }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if t.count <= maxChars { return t }
        return String(t.prefix(maxChars)) + "…"
    }

    /// Prefer text around the caret so long docs don't waste the cap on the top.
    private static func truncateNear(_ text: String, caretUTF16: Int, maxChars: Int) -> String? {
        let t = text
        guard !t.isEmpty else { return nil }
        if t.count <= maxChars { return t }

        let utf16 = t.utf16
        let caret = Swift.min(Swift.max(caretUTF16, 0), utf16.count)
        // Map UTF-16 offset to String.Index best-effort.
        let caretIdx: String.Index = {
            if let i = String.Index(utf16.index(utf16.startIndex, offsetBy: caret), within: t) {
                return i
            }
            return t.index(t.startIndex, offsetBy: Swift.min(caret, t.count), limitedBy: t.endIndex) ?? t.endIndex
        }()

        let half = maxChars / 2
        let start = t.index(caretIdx, offsetBy: -half, limitedBy: t.startIndex) ?? t.startIndex
        var end = t.index(start, offsetBy: maxChars, limitedBy: t.endIndex) ?? t.endIndex
        if t.distance(from: start, to: end) < maxChars, start > t.startIndex {
            let need = maxChars - t.distance(from: start, to: end)
            let newStart = t.index(start, offsetBy: -need, limitedBy: t.startIndex) ?? t.startIndex
            end = t.index(newStart, offsetBy: maxChars, limitedBy: t.endIndex) ?? t.endIndex
            let snippet = String(t[newStart..<end])
            let prefix = newStart > t.startIndex ? "…" : ""
            let suffix = end < t.endIndex ? "…" : ""
            return prefix + snippet + suffix
        }
        let snippet = String(t[start..<end])
        let prefix = start > t.startIndex ? "…" : ""
        let suffix = end < t.endIndex ? "…" : ""
        return prefix + snippet + suffix
    }

    /// Places the caret after the last character of the focused field.
    /// Returns the field's existing contents, or nil if the field would not cooperate.
    private static func moveCaretToEnd() -> String? {
        guard let element = focusedElement() else { return nil }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let existing = valueRef as? String
        else { return nil }

        var range = CFRange(location: existing.utf16.count, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(element,
                                           kAXSelectedTextRangeAttribute as CFString,
                                           axRange) == .success
        else { return nil }

        return existing
    }

    /// Writes straight into the field's selection. Returns false if the element
    /// does not accept text this way (terminals, canvases, most web views).
    private static func setSelectedText(_ payload: String) -> Bool {
        guard let element = focusedElement() else { return false }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element,
                                             kAXSelectedTextAttribute as CFString,
                                             &settable) == .success,
              settable.boolValue
        else { return false }

        return AXUIElementSetAttributeValue(element,
                                            kAXSelectedTextAttribute as CFString,
                                            payload as CFTypeRef) == .success
    }

    private static func insertViaClipboard(_ text: String, completion: @escaping () -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            pressCommandV()

            // Report success as soon as the paste is on its way. The clipboard
            // still has to be handed back, but the target app has the text by
            // now — making the UI wait for the restore left the panel sitting
            // there saying "Transcribing" after the words had already appeared.
            completion()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                restore(saved, to: pasteboard)
            }
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval)

        let vKey: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: Clipboard preservation

    private typealias Item = [NSPasteboard.PasteboardType: Data]

    private static func snapshot(_ pasteboard: NSPasteboard) -> [Item] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var stored: Item = [:]
            for type in item.types {
                if let data = item.data(forType: type) { stored[type] = data }
            }
            return stored
        }
    }

    private static func restore(_ items: [Item], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let rebuilt = items.map { stored -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in stored { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(rebuilt)
    }
}
