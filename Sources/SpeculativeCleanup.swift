import Foundation

/// One cleanup request fired at stop-time with the live partial transcript,
/// racing STT finalisation so the model is already thinking while the socket
/// drains. Resolved by `finishSession`, and only used when the final transcript
/// is exactly the text that was sent — a speculative result for different words
/// must never reach the field.
final class SpeculativeCleanup {

    let input: String
    let startedAt = Date()

    private var outcome: Cleaner.Outcome?
    private var waiter: ((Cleaner.Outcome) -> Void)?

    init(input: String, token: String, context: Inserter.CleanupContext?) {
        self.input = input
        Cleaner.clean(input, token: token, context: context) { [weak self] outcome in
            guard let self else { return }
            self.outcome = outcome
            self.waiter?(outcome)
            self.waiter = nil
        }
    }

    /// Whitespace, case, and trailing punctuation are normalised away: the
    /// server often flushes a trailing period or space into the final
    /// transcript, and the cleanup output for two texts differing only by
    /// those is identical — treating them as a miss just re-bought the same
    /// answer with a second request. Word content must still match exactly.
    func matches(final text: String) -> Bool {
        Self.equivalent(input, text)
    }

    static func equivalent(_ a: String, _ b: String) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[\\s.,!?;:…]+$", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Main queue only (that is where `Cleaner.clean` reports). Delivers
    /// immediately when the request already came back.
    func resolve(_ completion: @escaping (Cleaner.Outcome) -> Void) {
        if let outcome {
            completion(outcome)
        } else {
            waiter = completion
        }
    }
}

/// Rolling hit-rate governor: speculation costs a wasted request on every
/// miss, so when misses dominate recent sessions it pauses itself, and —
/// because outcomes keep being recorded even while paused — resumes on its
/// own when the final transcripts start matching the partials again.
enum SpeculationGovernor {
    static let window = 12
    static let minSamples = 8
    static let minHitRate = 0.4

    private static let outcomesKey = "speculativeOutcomes"

    static func shouldSpeculate(history: [Bool]) -> Bool {
        let recent = Array(history.suffix(window))
        guard recent.count >= minSamples else { return true }
        let hits = recent.filter { $0 }.count
        return Double(hits) / Double(recent.count) >= minHitRate
    }

    static func record(hit: Bool) {
        var outcomes = history()
        outcomes.append(hit)
        UserDefaults.standard.set(
            Array(outcomes.suffix(window)).map { $0 ? 1 : 0 },
            forKey: outcomesKey
        )
    }

    static func history() -> [Bool] {
        let stored = UserDefaults.standard.array(forKey: outcomesKey) ?? []
        let decoded: [Bool] = stored.compactMap { value in
            if let number = value as? NSNumber {
                let integer = number.intValue
                guard integer == 0 || integer == 1 else { return nil }
                return integer == 1
            }
            if let boolean = value as? Bool { return boolean }
            if let integer = value as? Int, integer == 0 || integer == 1 {
                return integer == 1
            }
            return nil
        }
        return Array(decoded.suffix(window))
    }

    static func describe(_ history: [Bool]) -> String {
        let recent = Array(history.suffix(window))
        let hits = recent.filter { $0 }.count
        return "\(hits)/\(recent.count) hits over last \(recent.count)"
    }
}
