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
        return decoded.filter { entry in
            if entry.pinned { return true }
            return !isCommonWord(entry.term) && looksUnique(entry.term)
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

    /// Terms sorted for the menu (pinned first, then count).
    static func listed(limit: Int = 40) -> [Entry] {
        Array(all().prefix(limit))
    }

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
        guard learningEnabled else { return }

        // Preferred forms come from cleaned text (unique terms only).
        let preferred = extractUniqueTerms(from: cleaned)
        // Raw unique tokens may be mishearings of the same things.
        let rawTokens = extractUniqueTerms(from: raw)

        var aliasPairs: [(preferred: String, alias: String)] = []
        // Same-length-ish token alignment: if cleaned has "Signara" and raw has
        // "Signa" / "Signora", record as alias when they share a long prefix.
        for p in preferred {
            for r in rawTokens where r.compare(p, options: .caseInsensitive) != .orderedSame {
                if looksLikeMishearing(heard: r, preferred: p) {
                    aliasPairs.append((p, r))
                }
            }
        }

        // Also scan for multi-word preferred phrases vs single raw lumps.
        for p in preferred {
            let pl = p.lowercased()
            let rawLower = raw.lowercased()
            // If preferred is multi-word and raw doesn't contain it, try fuzzy.
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
                if upsert(term, alias: nil, pinned: false, into: &entries) { changed += 1 }
            }
            for pair in aliasPairs {
                if upsert(pair.preferred, alias: pair.alias, pinned: false, into: &entries) {
                    changed += 1
                }
            }
        }
        if changed > 0 {
            Log.write("vocab: cleanup taught \(changed) update(s) (library=\(count()))")
        }
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

