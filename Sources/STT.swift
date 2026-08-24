import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Streaming speech-to-text over the same socket Grok Build's /voice uses.
///
/// Protocol, verified live against the endpoint:
///   → binary PCM16 frames, then {"type":"audio.done"}
///   ← {"type":"transcript.created", id}
///   ← {"type":"transcript.partial", text, words[], is_final, speech_final}
///   ← {"type":"transcript.done"}          (text is empty; the real text is the
///                                          accumulation of the partials)
final class STTClient: NSObject, URLSessionWebSocketDelegate {

    enum Failure: Equatable {
        case unauthorized
        case offline(String)
        case server(String)

        var message: String {
            switch self {
            case .unauthorized:      return "Grok session expired — open Grok Build once to refresh"
            case .offline(let m):    return m
            case .server(let m):     return m
            }
        }
    }

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?

    /// The server segments an utterance by `start` time. Within one segment the
    /// partials are cumulative (each carries the whole segment so far), and the
    /// segment closes with is_final=true — emitted TWICE, once with
    /// speech_final=false and once with true, carrying identical text. So the only
    /// correct model is last-write-wins per `start`, never append.
    private var segmentOrder: [Double] = []
    private var segments: [Double: String] = [:]
    private var didFinish = false
    private var doneTimer: Timer?
    private var socketOpen = false
    private var finishRequested = false

    /// Main-queue state for early finalisation. `speech_final` on the last
    /// meaningful partial means the server thinks the utterance is over, so the
    /// remaining wait for `transcript.done` is dead time.
    private var lastPartialSpeechFinal = false
    private var haveTranscriptText = false
    private var doneSent = false
    private var earlyTimer: Timer?
    /// OFF by default (0 disables). Completing on speech_final clipped the HEAD
    /// of real dictations: the server's first pass after audio.done can miss the
    /// opening words and re-emit the same segment ~1s later with them recovered —
    /// a revision an early completion never sees ("Can we review the architecture…"
    /// arrived as "architecture…", speech_final, then the full text 800ms later).
    /// The quiet-window fallback below is the safe fast path instead. Re-enable
    /// for experiments with `defaults write com.freeze.quill earlyFinalizeGrace -float 0.6`.
    private let earlyFinalizeGrace: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["QUILL_EARLY_GRACE"],
           let seconds = Double(raw) {
            return seconds
        }
        return UserDefaults.standard.double(forKey: "earlyFinalizeGrace")
    }()

    /// After audio.done: complete once the server has been QUIET this long.
    /// Restarted on every partial, so an actively-revising server is never cut
    /// off (the old fixed timer was), while a silent line finishes sooner than
    /// the old 3.0s wait.
    private let quietWindow: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["QUILL_QUIET_WINDOW"],
           let seconds = Double(raw) {
            return seconds
        }
        let configured = UserDefaults.standard.double(forKey: "sttQuietWindow")
        return configured > 0 ? configured : 2.0
    }()
    /// Absolute ceiling from audio.done, however chatty the server is.
    private let hardCap: TimeInterval = 6.0
    private var hardCapTimer: Timer?

    /// Best transcript so far — fires on every partial.
    var onText: (String) -> Void = { _ in }
    /// The socket is up and audio is being accepted.
    var onReady: () -> Void = {}
    /// Terminal: the complete transcript.
    var onComplete: (String) -> Void = { _ in }
    var onFailure: (Failure) -> Void = { _ in }

    /// Segments are written from the URLSession delegate queue and read from
    /// main (speculative cleanup reads mid-stream, and `complete()` reads at the
    /// end), so both sides take this lock. Reading a Dictionary while another
    /// thread inserts into it can crash outright.
    private let segmentLock = NSLock()

    var transcript: String {
        segmentLock.lock()
        defer { segmentLock.unlock() }
        // Ordered by the segment's own start time, not arrival order: a segment
        // whose earlier `start` shows up late belongs at the head of the
        // utterance, not appended to the tail.
        return segments.keys.sorted().compactMap { segments[$0] }.joined(separator: " ")
    }

    private func record(start: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Interim empties are the server clearing its buffer between segments —
        // they must never wipe text we already have.
        guard !trimmed.isEmpty else { return }
        segmentLock.lock()
        segments[start] = trimmed
        segmentLock.unlock()
    }

    func connect(token: String, language: String, keyterms: [String] = []) {
        // QUILL_STT_URL points this at a mock socket for headless benchmarking.
        let endpoint = ProcessInfo.processInfo.environment["QUILL_STT_URL"]
            ?? "wss://api.x.ai/v1/stt"
        var items: [URLQueryItem] = [
            .init(name: "sample_rate", value: "16000"),
            .init(name: "encoding", value: "pcm"),
            .init(name: "interim_results", value: "true"),
        ]
        if !language.isEmpty, language != "auto" {
            items.append(.init(name: "language", value: language))
        }
        // Bias the recogniser toward the user's own names and terms. Without
        // this the personal dictionary only ever reached the cleanup prompt, so
        // raw dictation kept mishearing the same words every session.
        // Service limits: 100 terms, 50 characters each.
        let biases = Array(keyterms.prefix(100))
        for term in biases {
            items.append(.init(name: "keyterm", value: term))
        }
        if !biases.isEmpty {
            Log.write("stt keyterms: \(biases.count) sent (e.g. \(biases.prefix(5).joined(separator: ", ")))")
        }
        guard var components = URLComponents(string: endpoint) else {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure(.server("Bad speech-to-text endpoint: \(endpoint)"))
            }
            return
        }
        components.queryItems = items
        guard let url = components.url else {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure(.server("Bad speech-to-text endpoint: \(endpoint)"))
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20

        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let socket = session.webSocketTask(with: request)
        task = socket
        socket.resume()
        receive()
    }

    func send(pcm: Data) {
        task?.send(.data(pcm)) { _ in }
    }

    /// Tell the server we're done, then wait for the tail of the transcript.
    ///
    /// If the socket has not finished connecting yet — which is exactly the case
    /// on the first recording after launch, where DNS and the TLS handshake are
    /// still in flight — the request is held until it opens, so the buffered audio
    /// is still sent and still transcribed. Ending the session early here is what
    /// made the first dictation silently produce nothing.
    func finish() {
        guard !didFinish else { return }
        if socketOpen {
            sendDone()
        } else {
            Log.write("  finish deferred — socket still connecting, audio held")
            finishRequested = true
        }
    }

    private func sendDone() {
        task?.send(.string(#"{"type":"audio.done"}"#)) { _ in }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.doneSent = true
            self.restartQuietTimer()
            self.hardCapTimer?.invalidate()
            // .common mode, not the default: while a menu is open or the user is
            // dragging, the main run loop is in event-tracking and default-mode
            // timers are suspended — which stalled finalisation entirely and
            // left the HUD stuck on "thinking".
            let cap = Timer(timeInterval: self.hardCap, repeats: false) { [weak self] _ in
                guard let self, !self.didFinish else { return }
                Log.write("finalize hard cap — server still sending after \(self.hardCap)s")
                self.complete()
            }
            RunLoop.main.add(cap, forMode: .common)
            self.hardCapTimer = cap
            // speech_final may already have arrived before the user stopped.
            self.scheduleEarlyFinalizeIfReady()
        }
    }

    /// Main queue only. Every partial after audio.done proves the server is
    /// still working — give it a fresh quiet window before completing.
    private func restartQuietTimer() {
        guard doneSent, !didFinish else { return }
        doneTimer?.invalidate()
        let timer = Timer(timeInterval: quietWindow, repeats: false) { [weak self] _ in
            self?.complete()
        }
        RunLoop.main.add(timer, forMode: .common)
        doneTimer = timer
    }

    /// Main queue only. Arms the opt-in grace window when the server has said
    /// the utterance ended and we have something to insert. Disabled (grace 0)
    /// by default — see `earlyFinalizeGrace`.
    private func scheduleEarlyFinalizeIfReady() {
        guard earlyFinalizeGrace > 0 else { return }
        guard doneSent, !didFinish, lastPartialSpeechFinal, haveTranscriptText else { return }
        earlyTimer?.invalidate()
        let early = Timer(timeInterval: earlyFinalizeGrace, repeats: false) { [weak self] _ in
            guard let self, !self.didFinish else { return }
            let seconds = String(format: "%.2f", self.earlyFinalizeGrace)
            Log.write("early finalize — no transcript.done within \(seconds)s of speech_final")
            self.complete()
        }
        RunLoop.main.add(early, forMode: .common)
        earlyTimer = early
    }

    func cancel() {
        didFinish = true
        doneTimer?.invalidate()
        earlyTimer?.invalidate()
        earlyTimer = nil
        hardCapTimer?.invalidate()
        hardCapTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
    }

    /// Always runs on the main queue.
    ///
    /// Reachable from both the URLSession delegate queue (`transcript.done`,
    /// transport failure, socket close) and the main queue (the finalize
    /// timers). Funnelling everything through one queue is what makes the
    /// `didFinish` check-then-act safe: two concurrent callers could otherwise
    /// both pass it and deliver the transcript twice, which the insert path has
    /// no guard against. It also keeps `Timer.invalidate()` on the thread that
    /// installed the timers, as AppKit requires.
    private func complete() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.complete() }
            return
        }
        guard !didFinish else { return }
        didFinish = true
        doneTimer?.invalidate()
        earlyTimer?.invalidate()
        earlyTimer = nil
        hardCapTimer?.invalidate()
        hardCapTimer = nil
        let text = transcript
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        let final = text
        onComplete(final)
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handleTransportFailure(error)
            case .success(let message):
                switch message {
                case .string(let s): self.handle(json: s)
                case .data(let d):   self.handle(json: String(decoding: d, as: UTF8.self))
                @unknown default:    break
                }
                self.receive()
            }
        }
    }

    private func handle(json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }

        switch type {
        case "transcript.partial":
            let text = (object["text"] as? String) ?? ""
            record(start: (object["start"] as? Double) ?? 0, text: text)
            let snapshot = transcript
            let carriesText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let speechFinal = (object["speech_final"] as? Bool) ?? false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onText(snapshot)
                // Any partial is proof the server is still working — even a
                // buffer-clearing empty one. Give it a fresh quiet window so a
                // late head/tail revision is never cut off mid-delivery.
                self.restartQuietTimer()
                // Empty partials say nothing about whether speech ended.
                guard carriesText else { return }
                self.lastPartialSpeechFinal = speechFinal
                self.haveTranscriptText = true
                // More speech arrived: the previous grace window is stale.
                self.earlyTimer?.invalidate()
                self.earlyTimer = nil
                self.scheduleEarlyFinalizeIfReady()
            }

        case "transcript.created":
            break

        case "transcript.done":
            let text = ((object["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Prefer a consolidated transcript wholesale — but never let a
            // tail-only done clobber a longer accumulation (defensive: the
            // live endpoint sends done with empty text).
            if !text.isEmpty, Double(text.count) >= Double(transcript.count) * 0.9 {
                segmentLock.lock()
                segments = [-1: text]
                segmentLock.unlock()
            } else if !text.isEmpty {
                Log.write("transcript.done shorter than accumulated partials — keeping partials"
                    + " (\(text.count) vs \(transcript.count) chars)")
            }
            complete()

        case "error":
            let message = (object["message"] as? String)
                ?? (object["error"] as? String)
                ?? "Transcription error"
            // Terminal: without this the finalize timers stayed armed and could
            // still complete() the session, racing the failure report.
            didFinish = true
            doneTimer?.invalidate()
            hardCapTimer?.invalidate()
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            DispatchQueue.main.async { [weak self] in self?.onFailure(.server(message)) }

        default:
            break
        }
    }

    private func handleTransportFailure(_ error: Error) {
        guard !didFinish else { return }

        if let response = task?.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            didFinish = true
            DispatchQueue.main.async { [weak self] in self?.onFailure(.unauthorized) }
            return
        }

        // A normal server-side close after audio.done arrives here as an error.
        if !transcript.isEmpty {
            complete()
            return
        }

        didFinish = true
        let ns = error as NSError
        let message = ns.code == NSURLErrorNotConnectedToInternet
            ? "No network connection"
            : ns.localizedDescription
        DispatchQueue.main.async { [weak self] in self?.onFailure(.offline(message)) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.socketOpen = true
            self.onReady()                       // flushes whatever was buffered
            if self.finishRequested { self.sendDone() }
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard !didFinish else { return }
        if !transcript.isEmpty {
            complete()
        } else {
            didFinish = true
            DispatchQueue.main.async { [weak self] in
                self?.onFailure(.server("Connection closed (code \(closeCode.rawValue))"))
            }
        }
    }
}
