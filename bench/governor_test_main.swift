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

// Speculation never pauses: a miss finishes no later than not speculating,
// while pausing forces the full serial cleanup wait on every dictation.
expect(SpeculationGovernor.shouldSpeculate(history: []), "empty history speculates")
expect(SpeculationGovernor.shouldSpeculate(history: Array(repeating: false, count: 12)),
       "all misses still speculates (pausing only ever cost latency)")
expect(SpeculationGovernor.shouldSpeculate(history: Array(repeating: true, count: 12)),
       "all hits speculates")

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
