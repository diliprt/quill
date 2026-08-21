import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Drives the shipped STTClient/Cleaner through one scripted dictation and
// reports timings + final text as one JSON line on stdout.
//
// The smart-lane orchestration below mirrors finishSession in Sources/main.swift
// (budget, budget-timeout fall-back-to-raw, speculative hit/miss resolution).
//
// Env:
//   SCENARIO   mock path, e.g. fast_done
//   LANE       raw | smart
//   SPEC       on | off        (speculative cleanup; SPECULATIVE builds only)
//   STOP_MS    when to "release the key" after connect (default 1000)
//   QUILL_STT_URL / QUILL_CHAT_URL   point at the mocks

let env = ProcessInfo.processInfo.environment
let scenario = env["SCENARIO"] ?? "fast_done"
let lane = env["LANE"] ?? "raw"
let specWanted = (env["SPEC"] ?? "off") == "on"
let stopMs = Int(env["STOP_MS"] ?? "1000") ?? 1000

var chatRequests = 0
var specLabel = "off"

func emit(_ fields: [String: Any]) -> Never {
    var out = fields
    out["scenario"] = scenario
    out["lane"] = lane
    out["spec"] = specLabel
    out["chat_requests"] = chatRequests
    let data = try! JSONSerialization.data(withJSONObject: out)
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

let client = STTClient()
var tStop: Date?

func ms(_ from: Date, _ to: Date = Date()) -> Int {
    Int((to.timeIntervalSince(from) * 1000).rounded())
}

#if SPECULATIVE
var speculative: SpeculativeCleanup?
#endif

// Mirrors the finishSession(with:) flow relevant to timing.
func finishSession(with text: String) {
    let tFinal = Date()
    let stopAt = tStop ?? tFinal
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

    guard lane == "smart" else {
        emit(["stop_to_final_ms": ms(stopAt, tFinal),
              "stop_to_ready_ms": ms(stopAt, tFinal),
              "cleanup_ms": 0,
              "output": trimmed])
    }

    #if SPECULATIVE
    // Mirrors the local fast-path in main.swift finishSession.
    if Cleaner.alreadyClean(trimmed) {
        specLabel = "local"
        emit(["stop_to_final_ms": ms(stopAt, tFinal),
              "cleanup_ms": 0,
              "stop_to_ready_ms": ms(stopAt, tFinal),
              "output": trimmed])
    }
    #endif

    let tCleanStart = Date()
    var budget = Cleaner.budgetSeconds(for: trimmed)
    var hit = false
    #if SPECULATIVE
    let spec = speculative
    speculative = nil
    hit = spec?.matches(final: trimmed) ?? false
    if let spec {
        if hit {
            specLabel = "hit"
            budget = max(0.15, budget - Date().timeIntervalSince(spec.startedAt))
        } else {
            specLabel = "miss"
            Log.write("cleanup speculative miss (resent) partial=\(spec.input.count) final=\(trimmed.count) chars")
        }
    } else if specWanted {
        specLabel = "skipped"
    }
    #endif

    var finished = false
    let apply: (Cleaner.Outcome) -> Void = { outcome in
        guard !finished else { return }
        finished = true
        let output: String
        var fallback = false
        switch outcome {
        case .cleaned(let polished):
            output = polished.isEmpty ? trimmed : polished
        case .failed:
            output = trimmed
            fallback = true
        }
        emit(["stop_to_final_ms": ms(stopAt, tFinal),
              "cleanup_ms": ms(tCleanStart),
              "stop_to_ready_ms": ms(stopAt),
              "output": output,
              "raw_fallback": fallback])
    }
    let budgetWork = DispatchWorkItem { apply(.failed("budget timeout")) }
    DispatchQueue.main.asyncAfter(deadline: .now() + budget, execute: budgetWork)

    #if SPECULATIVE
    if hit, let spec {
        spec.resolve { outcome in
            budgetWork.cancel()
            Log.write("cleanup speculative hit \(ms(spec.startedAt))ms")
            apply(outcome)
        }
        return
    }
    #endif
    chatRequests += 1
    Cleaner.clean(trimmed, token: "benchtoken", context: nil) { outcome in
        budgetWork.cancel()
        apply(outcome)
    }
}

client.onComplete = { text in finishSession(with: text) }
client.onFailure = { failure in
    emit(["error": failure.message])
}

client.connect(token: "benchtoken", language: "en")

DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(stopMs)) {
    tStop = Date()
    #if SPECULATIVE
    if lane == "smart", specWanted {
        let snapshot = client.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snapshot.isEmpty, !Cleaner.alreadyClean(snapshot) {
            chatRequests += 1
            speculative = SpeculativeCleanup(input: snapshot, token: "benchtoken", context: nil)
            Log.write("cleanup speculative fired for \(snapshot.count) chars")
        }
    }
    #endif
    client.finish()
}

// Watchdog well above every scripted timeline.
DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
    emit(["error": "watchdog timeout"])
}

RunLoop.main.run()
