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

    func matches(final text: String) -> Bool { input == text }

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
