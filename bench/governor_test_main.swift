import Foundation

// Deterministic checks for the speculation governor and transcript
// equivalence — the two pure-logic pieces added for self-tuning speculation.

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// Below minSamples: always speculate (still learning).
expect(SpeculationGovernor.shouldSpeculate(history: []), "empty history speculates")
expect(SpeculationGovernor.shouldSpeculate(history: Array(repeating: false, count: 7)),
       "7 misses still speculates (below minSamples)")

// Misses dominate: pause.
expect(!SpeculationGovernor.shouldSpeculate(history: Array(repeating: false, count: 8)),
       "8 misses pauses")
expect(!SpeculationGovernor.shouldSpeculate(
        history: [true, true, false, false, false, false, false, false, false, false]),
       "2/10 hits pauses")

// Hits dominate: speculate.
expect(SpeculationGovernor.shouldSpeculate(history: Array(repeating: true, count: 12)),
       "12 hits speculates")
expect(SpeculationGovernor.shouldSpeculate(
        history: [false, false, false, true, true, true, true, false, true, true]),
       "6/10 hits speculates")

// Only the window counts: old misses roll off.
let oldMissesRecentHits = Array(repeating: false, count: 20) + Array(repeating: true, count: 12)
expect(SpeculationGovernor.shouldSpeculate(history: oldMissesRecentHits),
       "20 old misses forgiven by 12 recent hits")

// Boundary: exactly minHitRate stays on.
let boundary = Array(repeating: true, count: 4) + Array(repeating: false, count: 6)
expect(SpeculationGovernor.shouldSpeculate(history: boundary), "4/10 = 40% stays on")

// Equivalence normalization.
expect(SpeculativeCleanup.equivalent("hello world", "hello world."),
       "trailing period equivalent")
expect(SpeculativeCleanup.equivalent("hello  world", "Hello world "),
       "case + whitespace equivalent")
expect(!SpeculativeCleanup.equivalent("hello world", "hello there"),
       "different words not equivalent")
expect(!SpeculativeCleanup.equivalent("hello world", "hello world again"),
       "grown transcript not equivalent")

// Persistence round-trip (works on corelibs UserDefaults too).
UserDefaults.standard.removeObject(forKey: "speculativeOutcomes")
SpeculationGovernor.record(hit: true)
SpeculationGovernor.record(hit: false)
SpeculationGovernor.record(hit: true)
expect(SpeculationGovernor.history() == [true, false, true], "record/history round-trip")
for _ in 0..<20 { SpeculationGovernor.record(hit: false) }
expect(SpeculationGovernor.history().count == SpeculationGovernor.window,
       "history capped at window")
UserDefaults.standard.removeObject(forKey: "speculativeOutcomes")

print(failures == 0 ? "GOVERNOR_TEST_OK" : "GOVERNOR_TEST_FAILED (\(failures))")
exit(failures == 0 ? 0 : 1)
