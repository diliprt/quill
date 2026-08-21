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
        Self.normalized(input) == Self.normalized(text)
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
