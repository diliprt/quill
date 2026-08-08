import Foundation
import AppKit

/// Local personal dictionary of *unique* terms — names, products, jargon —
/// not everyday English. Stored only on this Mac and fed into Grok cleanup
/// so spellings stay consistent (e.g. Signara, Quill, M5 Max).
///
/// Learning sources:
///  1. Final inserted text (unique-looking tokens)
///  2. Raw STT → cleaned pairs (aliases for how speech-to-text mishears you)
///  3. Manual add / pin from the menu
enum Vocabulary {

    struct Entry: Codable, Equatable {
        var term: String
        /// How STT often writes it (mishearings), lowercased for matching.
        var aliases: [String]
        var count: Int
        var lastSeen: TimeInterval
        /// User-added or confirmed — never auto-pruned.
        var pinned: Bool

        init(term: String, aliases: [String] = [], count: Int = 1,
             lastSeen: TimeInterval = Date().timeIntervalSince1970, pinned: Bool = false) {
            self.term = term
            self.aliases = aliases
            self.count = count
            self.lastSeen = lastSeen
            self.pinned = pinned
        }
    }

    private static let fileName = "vocabulary.json"
    private static let maxEntries = 400
    private static let maxAliasesPerTerm = 8
    /// Auto-learned terms need this many sightings before they stick (pinned bypass).
    private static let promoteThreshold = 1

    private static var cache: [Entry]?
    private static let lock = NSLock()

    // MARK: - Paths

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.freeze.quill", isDirectory: true)
    }

    static var fileURL: URL {
        supportDirectory.appendingPathComponent(fileName)
    }

    // MARK: - Load / save

    static func all() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        let loaded = loadFromDisk()
        cache = loaded
        return loaded
    }

    static func count() -> Int { all().count }

    @discardableResult
    private static func mutate(_ body: (inout [Entry]) -> Void) -> [Entry] {
        lock.lock()
        var entries = cache ?? loadFromDisk()
        body(&entries)
        // Keep pinned first, then by frequency, cap size (drop weakest unpinned).
        entries.sort {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.lastSeen > $1.lastSeen
        }
        if entries.count > maxEntries {
            var kept: [Entry] = []
            kept.reserveCapacity(maxEntries)
            for e in entries {
                if e.pinned || kept.count < maxEntries { kept.append(e) }
            }
            entries = Array(kept.prefix(maxEntries))
        }
        cache = entries
        saveToDisk(entries)
        lock.unlock()
        return entries
    }

    private static func loadFromDisk() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        // Drop anything that is clearly everyday English (list improves over time).
        // Keep pinned terms and the built-in AI/harness seed pack.
        return decoded.filter { entry in
            if entry.pinned { return true }
            if isStandardSeedTerm(entry.term) { return true }
            return !isCommonWord(entry.term) && looksUnique(entry.term)
        }
    }

    private static func isStandardSeedTerm(_ term: String) -> Bool {
        standardHarnessTerms.contains {
            $0.term.caseInsensitiveCompare(term) == .orderedSame
        }
    }

    private static func saveToDisk(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Public API

    static var learningEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vocabLearning") == nil { return true }
            return UserDefaults.standard.bool(forKey: "vocabLearning")
        }
        set { UserDefaults.standard.set(newValue, forKey: "vocabLearning") }
    }

    /// Watch the field after paste and learn when the user hand-edits.
    static var learnFromEditsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vocabLearnFromEdits") == nil { return true }
            return UserDefaults.standard.bool(forKey: "vocabLearnFromEdits")
        }
        set { UserDefaults.standard.set(newValue, forKey: "vocabLearnFromEdits") }
    }

    /// Version of the built-in AI/harness seed pack. Bump when the list grows so
    /// existing installs merge new terms once without clobbering user pins.
    private static let standardSeedVersion = 1
    private static let standardSeedVersionKey = "vocabStandardSeedVersion"

    /// Terms sorted for the menu (pinned first, then count).
    static func listed(limit: Int = 40) -> [Entry] {
        Array(all().prefix(limit))
    }

    /// Merge the built-in AI / coding-harness vocabulary once per seed version
    /// (or force). Never overwrites pinned user terms; only fills missing aliases
    /// on existing unpinned matches.
    @discardableResult
    static func ensureStandardSeed(force: Bool = false) -> Int {
        let applied = UserDefaults.standard.integer(forKey: standardSeedVersionKey)
        guard force || applied < standardSeedVersion else { return 0 }

        var added = 0
        mutate { entries in
            for seed in standardHarnessTerms {
                let term = seed.term
                if let i = entries.firstIndex(where: {
                    $0.term.caseInsensitiveCompare(term) == .orderedSame
                }) {
                    // Keep user's preferred casing if pinned; still add missing aliases.
                    var e = entries[i]
                    var changed = false
                    for a in seed.aliases {
                        let aTrim = a.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !aTrim.isEmpty else { continue }
                        if !e.aliases.contains(where: {
                            $0.caseInsensitiveCompare(aTrim) == .orderedSame
                        }) {
                            e.aliases.append(aTrim)
                            changed = true
                        }
                    }
                    if e.aliases.count > maxAliasesPerTerm {
                        e.aliases = Array(e.aliases.prefix(maxAliasesPerTerm))
                    }
                    if !e.pinned {
                        e.count = max(e.count, 3)
                    }
                    if changed {
                        entries[i] = e
                        added += 1
                    }
                } else {
                    entries.append(Entry(
                        term: term,
                        aliases: seed.aliases,
                        count: 3,
                        lastSeen: Date().timeIntervalSince1970,
                        pinned: false
                    ))
                    added += 1
                }
            }
        }
        UserDefaults.standard.set(standardSeedVersion, forKey: standardSeedVersionKey)
        if added > 0 {
            Log.write("vocab: standard AI/harness seed v\(standardSeedVersion) merged \(added) term(s) (library=\(count()))")
        } else {
            Log.write("vocab: standard AI/harness seed v\(standardSeedVersion) already present")
        }
        return added
    }

    /// Built-in spellings for AI coding harnesses, models, and STT tools.
    /// Aliases are common speech-to-text mishearings.
    private static let standardHarnessTerms: [(term: String, aliases: [String])] = [
        // xAI / Grok / this app
        ("Grok", ["Grock", "Grog", "Croc", "Grokk"]),
        ("Grok Build", ["Grock Build", "Grog Build", "Grok build", "Grock build"]),
        ("Grok 4.5", ["Grok 4 point 5", "Grok four five", "Grok 4 5"]),
        ("xAI", ["X AI", "ex AI", "X.A.I."]),
        ("SpaceXAI", ["Space X AI", "SpaceX AI", "space x a i"]),
        ("Quill", ["Quil", "Qwil", "Qwill", "QWELL", "Kwilt"]),
        ("SuperGrok", ["Super Grok", "Super Grock"]),

        // Agent harness / IDE agents
        ("Claude", ["Clod", "Clawed", "Claud"]),
        ("Claude Code", ["Clod Code", "Claude code", "Cloud Code"]),
        ("Codex", ["Code X", "CodeX", "Codecks"]),
        ("Cursor", ["Curser", "Cursur"]),
        ("GitHub Copilot", ["Copilot", "Co-pilot", "Github Copilot", "Co pilot"]),
        ("Windsurf", ["Wind surf", "Windsorf"]),
        ("Aider", ["Aid er", "Adar"]),
        ("Devin", ["Devon", "Devan"]),
        ("OpenHands", ["Open Hands", "Openhands"]),
        ("SWE-agent", ["SWE agent", "swe agent", "S W E agent"]),
        ("Terminal-Bench", ["Terminal Bench", "terminal bench"]),
        ("coding agent", ["coding agents", "code agent"]),
        ("agent harness", ["agent hairness", "AI harness", "harness"]),

        // Protocols & architecture
        ("MCP", ["M C P", "em cee pee"]),
        ("Model Context Protocol", ["model context protocol"]),
        ("RAG", ["R A G"]),
        ("LLM", ["L L M", "large language model"]),
        ("STT", ["S T T", "speech to text", "speech-to-text"]),
        ("TTS", ["T T S", "text to speech", "text-to-speech"]),
        ("ASR", ["A S R"]),
        ("BYOK", ["B Y O K", "bring your own key"]),
        ("OIDC", ["O I D C"]),
        ("API", ["A P I"]),
        ("SDK", ["S D K"]),
        ("CLI", ["C L I"]),
        ("JSON", ["J S O N", "jay son"]),
        ("YAML", ["Y A M L"]),
        ("HTTP", ["H T T P"]),
        ("WebSocket", ["web socket", "websocket"]),
        ("OAuth", ["O Auth", "oauth"]),
        ("tokenizer", ["token izer", "tokeniser"]),
        ("embeddings", ["embedding"]),
        ("fine-tune", ["finetune", "fine tune", "fine tuning"]),
        ("context window", ["contextwindow", "context-window"]),
        ("system prompt", ["systemprompt", "system-prompt"]),
        ("subagent", ["sub agent", "sub-agent", "sub agents"]),
        ("agentic", ["a gentic", "agent tick"]),
        ("tool call", ["toolcall", "tool-call", "function call"]),
        ("function calling", ["function-calling"]),
        ("worktree", ["work tree", "git worktree"]),
        ("plan mode", ["Plan Mode", "plan-mode"]),

        // Local / open models & runtimes
        ("Hugging Face", ["HuggingFace", "hugging face"]),
        ("MLX", ["M L X", "em el ex"]),
        ("GGUF", ["G G U F", "gee gee you ef"]),
        ("Ollama", ["O llama", "Olama", "Oh llama"]),
        ("llama.cpp", ["llama cpp", "llama C plus plus", "llamacpp"]),
        ("Whisper", ["Whisper model", "OpenAI Whisper"]),
        ("whisper.cpp", ["whisper cpp", "whispercpp"]),
        ("Parakeet", ["Para keet", "pair a keet"]),
        ("NVIDIA Parakeet", ["Nvidia Parakeet"]),
        ("DeepSeek", ["Deep Seek", "deepseek"]),
        ("Qwen", ["Quen", "Q when", "Chwen"]),
        ("Gemma", ["Jemma", "Gemma model"]),
        ("Llama", ["LLaMA"]),
        ("Mistral", ["Mistrahl", "Miss tral"]),
        ("vLLM", ["V L L M", "v llm"]),
        ("LM Studio", ["L M Studio", "LMStudio"]),
        ("Core ML", ["CoreML", "core m l"]),
        ("Apple Silicon", ["apple silicon"]),
        ("M5 Max", ["M 5 Max", "M5 max", "em five max"]),

        // Dictation peers
        ("Wispr Flow", ["Whisper Flow", "WhisperFlow", "Wispr"]),
        ("Superwhisper", ["Super Whisper", "super whisper"]),
        ("MacWhisper", ["Mac Whisper", "mac whisper"]),
        ("FreeFlow", ["Free Flow", "freeflow"]),
        ("FluidVoice", ["Fluid Voice", "Fluid Whisper", "fluidvoice"]),
        ("MacParakeet", ["Mac Parakeet", "mac parakeet"]),
        ("OpenWhispr", ["Open Whisper", "OpenWhisper", "open whispr"]),

        // Cloud / providers
        ("OpenAI", ["Open AI"]),
        ("Anthropic", ["An thropic", "Anthropic AI"]),
        ("Gemini", ["Gemeni", "Jimini"]),
        ("ChatGPT", ["Chat G P T", "Chat GPT"]),
        ("Groq", ["Grock inference"]),
        ("OpenRouter", ["Open Router", "openrouter"]),

        // Dev platforms
        ("GitHub", ["Github", "git hub", "Git Hub"]),
        ("GitLab", ["Git Lab", "gitlab"]),
        ("pull request", ["pullrequest"]),
        ("Graphite", ["graph ite"]),
        ("VS Code", ["VSCode", "V S Code", "Visual Studio Code"]),
        ("Xcode", ["X code", "ex code"]),
        ("SwiftUI", ["Swift UI", "swift u i"]),
        ("TypeScript", ["Type Script"]),
        ("Node.js", ["Node JS", "nodejs"]),
        ("Kubernetes", ["K8s", "kubes", "coo bernetes"]),
        ("Firebase", ["Fire base"]),
        ("Postgres", ["PostgreSQL", "post gress"]),
        ("Tailwind", ["tail wind", "Tailwind CSS"]),

        // Product names used with this fork
        ("Syanara", ["Signara", "Synara", "Signa", "Sainara", "Cyannara", "Sai Nara"]),
        ("Syanara Ward", ["Signara Ward", "Synara Ward", "Signa Ward"]),
        ("Origin Ark", ["OriginArk", "origin ark"]),
        ("Ghostty", ["Ghosty", "Ghost tee", "ghosty"]),
        ("Accessibility", ["access ability"]),
    ]

    /// Block injected into the cleanup system prompt.
    static func promptBlock(limit: Int = 80) -> String {
        let entries = all().prefix(limit)
        guard !entries.isEmpty else { return "" }
        var lines: [String] = [
            "PERSONAL DICTIONARY (unique names/terms — spelling reference only;",
            "correct close mishearings to the preferred term; never insert a term that was not spoken):",
        ]
        for e in entries {
            if e.aliases.isEmpty {
                lines.append("- \(e.term)")
            } else {
                let aliasList = e.aliases.prefix(4).joined(separator: ", ")
                lines.append("- \(e.term)  (often heard as: \(aliasList))")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Learn unique terms from text that was actually inserted.
    static func learnFromFinalText(_ text: String) {
        guard learningEnabled else { return }
        let candidates = extractUniqueTerms(from: text)
        guard !candidates.isEmpty else { return }
        var added = 0
        mutate { entries in
            for term in candidates {
                if upsert(term, alias: nil, pinned: false, into: &entries) { added += 1 }
            }
        }
        if added > 0 {
            Log.write("vocab: learned \(added) term(s) from final text (library=\(count()))")
        }
    }

    /// Learn preferred spellings + STT aliases from a cleanup pass.
    static func learnFromCleanup(raw: String, cleaned: String) {
        let n = learnPair(raw: raw, preferredSource: cleaned, pinPreferred: false)
        if n > 0 {
            Log.write("vocab: cleanup taught \(n) update(s) (library=\(count()))")
        }
    }

    /// Learn from the user hand-editing text after Quill inserted it.
    ///
    /// - `original`: the exact string Quill pasted
    /// - `fieldBefore`: field contents shortly after paste (when readable)
    /// - `fieldAfter`: field contents after the user stopped editing
    ///
    /// Preferred spellings come from the edited text; aliases come from the
    /// original STT/cleaned paste. Returns how many dictionary updates were made.
    @discardableResult
    static func learnFromUserEdit(original: String, fieldBefore: String, fieldAfter: String) -> Int {
        guard learningEnabled else { return 0 }
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, fieldBefore != fieldAfter else { return 0 }

        // Isolate the middle span that actually changed (ignores typing far away).
        let (oldMid, newMid) = editedMiddles(before: fieldBefore, after: fieldAfter)
        let base = !oldMid.isEmpty ? oldMid : o
        let edited = !newMid.isEmpty ? newMid : fieldAfter

        // No meaningful change to our inserted text (only typed elsewhere).
        if edited.contains(o), oldMid.isEmpty || oldMid.contains(o) {
            // Still learn unique terms from any brand-new unique words in the edit span.
            if !newMid.isEmpty, !newMid.contains(o) {
                // fall through
            } else if fieldAfter.contains(o) {
                return 0
            }
        }

        var total = learnPair(raw: base, preferredSource: edited, pinPreferred: false)
        total += learnWordSubstitutions(from: base, to: edited)
        // Also align original insert against the edited middle when they differ.
        if base != o {
            total += learnPair(raw: o, preferredSource: edited, pinPreferred: false)
            total += learnWordSubstitutions(from: o, to: edited)
        }
        if total > 0 {
            Log.write("vocab: user edit taught \(total) update(s) (library=\(count()))")
        }
        return total
    }

    /// Shared path: preferred terms + mishearing aliases from two strings.
    @discardableResult
    private static func learnPair(raw: String, preferredSource: String, pinPreferred: Bool) -> Int {
        guard learningEnabled else { return 0 }
        let preferred = extractUniqueTerms(from: preferredSource)
        let rawTokens = extractUniqueTerms(from: raw)

        var aliasPairs: [(preferred: String, alias: String)] = []
        for p in preferred {
            for r in rawTokens where r.compare(p, options: .caseInsensitive) != .orderedSame {
                if looksLikeMishearing(heard: r, preferred: p) {
                    aliasPairs.append((p, r))
                }
            }
        }

        for p in preferred {
            let pl = p.lowercased()
            let rawLower = raw.lowercased()
            if p.contains(" "), !rawLower.contains(pl) {
                let compact = pl.replacingOccurrences(of: " ", with: "")
                for r in rawTokens {
                    let rl = r.lowercased().replacingOccurrences(of: " ", with: "")
                    if rl == compact || (rl.count >= 4 && (compact.hasPrefix(rl) || rl.hasPrefix(compact))) {
                        aliasPairs.append((p, r))
                    }
                }
            }
        }

        var changed = 0
        mutate { entries in
            for term in preferred {
                if upsert(term, alias: nil, pinned: pinPreferred, into: &entries) { changed += 1 }
            }
            for pair in aliasPairs {
                if upsert(pair.preferred, alias: pair.alias, pinned: pinPreferred, into: &entries) {
                    changed += 1
                }
            }
        }
        return changed
    }

    /// Token-level substitutions when the user fixes one word to another.
    /// e.g. "Signa" → "Signara" in roughly the same place.
    @discardableResult
    private static func learnWordSubstitutions(from raw: String, to edited: String) -> Int {
        let a = tokenizeWords(raw)
        let b = tokenizeWords(edited)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var changed = 0
        // Similar-length sequences: pair by index.
        if abs(a.count - b.count) <= 2, min(a.count, b.count) >= 1 {
            let n = min(a.count, b.count)
            for i in 0..<n {
                let left = a[i], right = b[i]
                if left.compare(right, options: .caseInsensitive) == .orderedSame { continue }
                if isCommonWord(left), isCommonWord(right) { continue }
                // Prefer unique-looking preferred form.
                if looksUnique(right) || looksUnique(left) {
                    let preferred = looksUnique(right) ? right : left
                    let alias = preferred.compare(right, options: .caseInsensitive) == .orderedSame ? left : right
                    if preferred.compare(alias, options: .caseInsensitive) != .orderedSame {
                        mutate { entries in
                            if upsert(preferred, alias: alias, pinned: false, into: &entries) {
                                changed += 1
                            }
                        }
                    }
                }
            }
        }

        // Also: unique tokens that disappeared vs new unique tokens (mishearing map).
        let aUnique = a.filter { looksUnique($0) && !isCommonWord($0) }
        let bUnique = b.filter { looksUnique($0) && !isCommonWord($0) }
        for r in aUnique {
            if bUnique.contains(where: { $0.compare(r, options: .caseInsensitive) == .orderedSame }) {
                continue
            }
            for p in bUnique where looksLikeMishearing(heard: r, preferred: p) {
                mutate { entries in
                    if upsert(p, alias: r, pinned: false, into: &entries) { changed += 1 }
                }
            }
        }
        return changed
    }

    /// Longest common prefix/suffix → middle spans that changed.
    private static func editedMiddles(before: String, after: String) -> (String, String) {
        let b = Array(before)
        let a = Array(after)
        var i = 0
        while i < b.count, i < a.count, b[i] == a[i] { i += 1 }
        var j = 0
        while j < (b.count - i), j < (a.count - i),
              b[b.count - 1 - j] == a[a.count - 1 - j] { j += 1 }
        let oldMid = String(b[i..<(b.count - j)])
        let newMid = String(a[i..<(a.count - j)])
        return (oldMid, newMid)
    }

    private static func tokenizeWords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Manual add from menu (pinned so it never auto-drops).
    @discardableResult
    static func addManual(_ term: String, alias: String? = nil) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2 else { return false }
        var ok = false
        mutate { entries in
            ok = upsert(t, alias: alias, pinned: true, into: &entries)
            // Force pin even if already existed.
            if let i = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
                entries[i].pinned = true
                ok = true
            }
        }
        if ok { Log.write("vocab: pinned \"\(t)\"") }
        return ok
    }

    static func remove(term: String) {
        mutate { entries in
            entries.removeAll { $0.term.caseInsensitiveCompare(term) == .orderedSame }
        }
        Log.write("vocab: removed \"\(term)\"")
    }

    static func clearAll() {
        mutate { $0.removeAll() }
        Log.write("vocab: cleared library")
    }

    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            saveToDisk([])
        }
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    // MARK: - Upsert

    /// Returns true if something changed.
    @discardableResult
    private static func upsert(_ term: String, alias: String?, pinned: Bool,
                               into entries: inout [Entry]) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 2, !isCommonWord(t) else { return false }

        let now = Date().timeIntervalSince1970
        if let i = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(t) == .orderedSame }) {
            var e = entries[i]
            // Prefer the casing that appears more often; pinned keeps user casing.
            if !e.pinned, t != e.term, t.first?.isUppercase == true {
                e.term = t
            }
            e.count += 1
            e.lastSeen = now
            if pinned { e.pinned = true }
            if let alias {
                let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !a.isEmpty,
                   a.caseInsensitiveCompare(e.term) != .orderedSame,
                   !e.aliases.contains(where: { $0.caseInsensitiveCompare(a) == .orderedSame }) {
                    e.aliases.insert(a, at: 0)
                    if e.aliases.count > maxAliasesPerTerm {
                        e.aliases = Array(e.aliases.prefix(maxAliasesPerTerm))
                    }
                }
            }
            entries[i] = e
            return true
        }

        // New term.
        var aliases: [String] = []
        if let alias {
            let a = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            if !a.isEmpty, a.caseInsensitiveCompare(t) != .orderedSame {
                aliases = [a]
            }
        }
        // Only auto-add if clearly unique or pinned.
        if !pinned && !looksUnique(t) { return false }
        _ = promoteThreshold // reserved for future higher bar
        entries.append(Entry(term: t, aliases: aliases, count: 1, lastSeen: now, pinned: pinned))
        return true
    }

    // MARK: - Extraction (unique only — not standard English)

    static func extractUniqueTerms(from text: String) -> [String] {
        var found: [String] = []
        var seen = Set<String>()

        func keep(_ s: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2 else { return }
            guard !isCommonWord(t) else { return }
            guard looksUnique(t) else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            found.append(t)
        }

        // 1) CamelCase / PascalCase product names (SignaraApp, SpaceXAI)
        let camel = try! NSRegularExpression(pattern: #"\b[A-Z][a-z0-9]*(?:[A-Z][a-z0-9]+)+\b"#)
        for m in camel.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { keep(String(text[r])) }
        }

        // 2) ALL-CAPS acronyms (2–8 letters), not single letter
        let caps = try! NSRegularExpression(pattern: #"\b[A-Z]{2,8}\b"#)
        for m in caps.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { keep(String(text[r])) }
        }

        // 3) Multi-word proper names: "Project Quill", "US Bank"
        let multi = try! NSRegularExpression(
            pattern: #"\b(?:[A-Z][a-z0-9]+(?:\s+[A-Z][a-z0-9]+){1,3})\b"#)
        for m in multi.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) {
                let phrase = String(text[r])
                // Skip pure sentence starts that are common: "The App", "This Feature"
                let parts = phrase.split(separator: " ")
                if parts.count >= 2, parts.contains(where: { !isCommonWord(String($0)) }) {
                    keep(phrase)
                }
            }
        }

        // 4) Alphanumeric product codes: M5, Grok4, GPT-4, 128GB (with letters)
        let codes = try! NSRegularExpression(pattern: #"\b(?=[A-Za-z]*\d)(?=\d*[A-Za-z])[A-Za-z0-9][A-Za-z0-9.\-]{1,15}\b"#)
        for m in codes.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { keep(String(text[r])) }
        }

        // 5) Capitalized single tokens that look like names/brands — not plain English.
        //    Sentence-initial words are ignored unless product-like (CamelCase / digits).
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for (i, tok) in tokens.enumerated() {
            var w = String(tok).trimmingCharacters(in: .punctuationCharacters)
            if w.hasSuffix("'s") || w.hasSuffix("’s") { w = String(w.dropLast(2)) }
            guard w.count >= 3 else { continue }
            guard let first = w.first, first.isUppercase else { continue }
            guard !isCommonWord(w) else { continue }
            // Require either product shape, non-ASCII, or longer uncommon proper name.
            let sentenceStart = (i == 0)
            if looksProductLike(w) || w.unicodeScalars.contains(where: { $0.value > 127 }) {
                keep(w)
            } else if !sentenceStart, w.count >= 5, looksLikeProperName(w) {
                keep(w)
            }
        }

        // 6) Non-Latin scripts (names in Japanese, etc.) — whole runs of 2+ chars
        let nonLatin = try! NSRegularExpression(pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]{2,}"#)
        for m in nonLatin.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range, in: text) { keep(String(text[r])) }
        }

        return found
    }

    private static func looksUnique(_ term: String) -> Bool {
        if looksProductLike(term) { return true }
        if term.count >= 2, term.unicodeScalars.contains(where: {
            !$0.isASCII || $0.properties.isAlphabetic == false && $0.properties.numericType != nil
        }) {
            // Has non-ASCII letters or mixed scripts
            if term.unicodeScalars.contains(where: { $0.value > 127 }) { return true }
        }
        // Capitalized multi-word
        if term.contains(" ") { return true }
        // Single capitalized uncommon word length 3+
        if let f = term.first, f.isUppercase, term.count >= 3, !isCommonWord(term) { return true }
        // camelCase
        if term.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil { return true }
        // has digit
        if term.contains(where: \.isNumber) { return true }
        return false
    }

    private static func looksProductLike(_ term: String) -> Bool {
        if term.range(of: #"[a-z][A-Z]"#, options: .regularExpression) != nil { return true }
        if term.contains(where: \.isNumber) { return true }
        if term.count >= 2, term == term.uppercased(), term.allSatisfy(\.isLetter) { return true }
        return false
    }

    /// Uncommon proper-name shape: letters only, mixed or title case, not a stopword.
    private static func looksLikeProperName(_ term: String) -> Bool {
        guard term.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "'" }) else { return false }
        guard term.count >= 5 else { return false }
        // Reject if the lowercased form is a common English word we know.
        if isCommonWord(term) { return false }
        // Heuristic rarity: uncommon letter patterns / length 6+ title case.
        return term.count >= 6 || term.contains("-")
    }

    /// Heuristic: STT mangled a name (shared prefix/suffix, similar length).
    private static func looksLikeMishearing(heard: String, preferred: String) -> Bool {
        let a = heard.lowercased().filter { $0.isLetter || $0.isNumber }
        let b = preferred.lowercased().filter { $0.isLetter || $0.isNumber }
        guard a.count >= 3, b.count >= 3, a != b else { return false }
        // Shared prefix of 3+ or one contains the other
        let prefix = zip(a, b).prefix(while: { $0 == $1 }).count
        if prefix >= 3 { return true }
        if a.contains(b) || b.contains(a) { return abs(a.count - b.count) <= 4 }
        // Edit distance light: length close and first+last char match
        if abs(a.count - b.count) <= 2, a.first == b.first, a.last == b.last { return true }
        return false
    }

    private static func isCommonWord(_ word: String) -> Bool {
        let w = word.lowercased()
        if commonWords.contains(w) { return true }
        // Very short pure English particles
        if w.count <= 2, w.allSatisfy(\.isLetter) { return true }
        return false
    }

    /// Everyday English we never store — unique names/jargon only.
    private static let commonWords: Set<String> = [
        "the","a","an","and","or","but","if","then","else","when","while","for","to","of","in",
        "on","at","by","with","from","as","into","about","than","that","this","these","those",
        "it","its","is","are","was","were","be","been","being","am","do","does","did","done",
        "have","has","had","having","will","would","could","should","may","might","must","can",
        "not","no","yes","so","very","just","also","only","even","still","already","yet",
        "i","me","my","mine","you","your","yours","he","him","his","she","her","hers","we",
        "us","our","ours","they","them","their","theirs","who","whom","whose","which","what",
        "where","why","how","all","each","every","both","few","more","most","other","some",
        "such","any","own","same","too","here","there","now","again","once","always","never",
        "often","sometimes","please","thanks","thank","hello","hey","hi","okay","ok","yeah",
        "yep","nope","well","actually","basically","literally","really","thing","things",
        "stuff","way","ways","make","made","making","get","got","getting","go","going","went",
        "come","coming","came","see","saw","look","looking","know","knew","think","thought",
        "want","wanted","need","needed","use","used","using","try","tried","trying","let",
        "lets","put","set","keep","take","took","give","gave","tell","told","say","said",
        "ask","asked","work","worked","working","check","checked","open","opened","close",
        "right","left","up","down","out","over","under","after","before","between","through",
        "during","without","within","because","although","though","however","therefore",
        "feature","features","option","options","toggle","button","menu","app","apps",
        "file","files","text","word","words","voice","chat","key","keys","mode","time",
        "today","tomorrow","yesterday","first","second","third","last","next","new","old",
        "good","bad","great","best","better","able","sure","like","liked","love","hate",
        "enable","disable","enabled","disabled","update","updated","add","added","remove",
        "clear","store","local","mac","library","reference","standard","unique","speaking",
        "correcting","maintain","using","cleaning","cleanup","clean","dictation","simple",
        "different","direction","assign","stay","another","itself","onto","again","especially",
        "can","cannot","don't","doesn't","didn't","isn't","aren't","wasn't","weren't","i'm",
        "you're","we're","they're","it's","that's","what's","there's","here's","let's",
        "i'll","you'll","we'll","they'll","i've","you've","we've","they've","i'd","you'd",
        "project","company","number","phone","question","online","research","confirm",
        "actually","otherwise","point","extra","needed","working","correctly","reflecting",
        "things","when","open","app","ui","check","sign","dot","bank","business","essential",
        "essentials","virtual","cards","card","store","stores","google","apple","microsoft",
        "tragedy","dinner","remove","tell","whats","going","here","repo","better","tools",
        "other","ways","confirm","actually","will","work","apple","otherwise","there",
        "point","some","extra","research","well","needed","which","company","are","they",
        "have","virtual","cards","for","number","one","us","bank","business","essential",
        "do","they","have","enable","that","feature","give","toggle","option","chat",
        "assign","another","key","direction","simple","dictation","stay","different",
        "working","great","does","this","sft","combined","intelligence","clean","text",
        "much","overkill","update","make","hold","trigger","voice","know","about",
        "project","well","ciao",
        // Intentionally NOT blocking unique names: Quill, Signara, Grok, Qwil, etc.
        "american","english","united","states","monday","tuesday","wednesday","thursday",
        "friday","saturday","sunday","january","february","march","april","june","july",
        "august","september","october","november","december","please","thanks","hello",
        "message","email","document","documents","folder","folders","window","windows",
        "screen","settings","system","privacy","security","microphone","access","granted",
        "failed","error","success","ready","start","stop","finish","cancel","continue",
        "people","person","user","users","team","teams","client","clients","server",
        "model","models","local","remote","cloud","token","session","build","version",
    ]
}

