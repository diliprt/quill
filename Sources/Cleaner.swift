import Foundation

/// Light post-STT polish via Grok chat — same Grok Build token as STT.
///
/// Fast non-reasoning model on purpose: hold-to-talk should stay snappy.
/// On any failure the caller keeps the raw transcript.
/// When a personal vocabulary exists, those unique terms are injected so cleanup
/// preserves the user's preferred spellings.
enum Cleaner {

    /// Prefer a fast non-reasoning model; fall through if the account remaps names.
    private static let models = [
        "grok-4-1-fast-non-reasoning",
        "grok-4-1-fast",
        "grok-3-mini",
    ]

    private static let baseSystemPrompt = """
        You clean up spoken dictation transcripts.
        Fix grammar, punctuation, and capitalization.
        Remove filler words (um, uh, like, you know) and false starts.
        Do NOT change meaning, add content, or answer questions in the text.
        Do NOT wrap the result in quotes or add a preface.
        When a PERSONAL DICTIONARY is provided, treat those terms as authoritative:
        keep their exact spelling and capitalization; if the transcript has a close
        mishearing listed as an alias, rewrite it to the preferred term.
        Do not invent dictionary terms that are not in the transcript or aliases.
        Output ONLY the cleaned text.
        """

    enum Outcome {
        case cleaned(String)
        case failed(String)
    }

    /// Clean `text` with Grok. Always calls `completion` on the main queue.
    static func clean(_ text: String, token: String, completion: @escaping (Outcome) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion(.cleaned(trimmed)) }
            return
        }

        let vocabBlock = Vocabulary.promptBlock()
        let system: String
        if vocabBlock.isEmpty {
            system = baseSystemPrompt
        } else {
            system = baseSystemPrompt + "\n\n" + vocabBlock
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var lastError = "cleanup failed"
            for model in models {
                switch request(text: trimmed, token: token, model: model, system: system) {
                case .cleaned(let out):
                    Log.write("cleanup ok model=\(model) chars \(trimmed.count)→\(out.count)"
                        + (vocabBlock.isEmpty ? "" : " vocab=\(Vocabulary.count())"))
                    DispatchQueue.main.async { completion(.cleaned(out)) }
                    return
                case .failed(let message):
                    lastError = message
                    Log.write("cleanup fail model=\(model): \(message)")
                }
            }
            DispatchQueue.main.async { completion(.failed(lastError)) }
        }
    }

    private static func request(text: String, token: String, model: String, system: String) -> Outcome {
        guard let url = URL(string: "https://api.x.ai/v1/chat/completions") else {
            return .failed("bad cleanup URL")
        }

        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "max_tokens": min(max(text.count * 2, 64), 2048),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .failed("could not encode cleanup request")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let semaphore = DispatchSemaphore(value: 0)
        var result: Outcome = .failed("no response")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failed(error.localizedDescription)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data else {
                result = .failed("empty response (HTTP \(code))")
                return
            }
            guard code == 200 else {
                let snippet = String(decoding: data.prefix(240), as: UTF8.self)
                result = .failed("HTTP \(code): \(snippet)")
                return
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let message = choices.first?["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                result = .failed("unexpected cleanup response shape")
                return
            }
            let cleaned = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip accidental wrapping quotes the model sometimes adds.
            let unquoted: String = {
                guard cleaned.count >= 2,
                      (cleaned.hasPrefix("\"") && cleaned.hasSuffix("\""))
                        || (cleaned.hasPrefix("“") && cleaned.hasSuffix("”"))
                else { return cleaned }
                return String(cleaned.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }()
            guard !unquoted.isEmpty else {
                result = .failed("model returned empty cleanup")
                return
            }
            result = .cleaned(unquoted)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 22)
        return result
    }
}
