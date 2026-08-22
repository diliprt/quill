# Latency / accuracy benchmark

Headless benchmark for the stop-to-insert pipeline. It compiles the **real
shipped** `Sources/STT.swift`, `Sources/Cleaner.swift` (and
`SpeculativeCleanup.swift`) into a harness and drives them against local mock
servers with scripted, deterministic delays — once for the baseline (`main`)
and once for the working tree, speculative cleanup off and on.

Not part of the app: `build.sh` at the repo root only compiles `Sources/*.swift`.

## Requirements (Linux)

- Swift for Linux toolchain (`SWIFTC` env var, default `~/swift/usr/bin/swiftc`)
- Python 3 + `websockets`
- libcurl with WebSocket support (`ws://`). Ubuntu 24.04's libcurl 8.5 has it
  disabled; build curl ≥ 8.11 from source and pass it via
  `BENCH_LD_PRELOAD=/usr/local/lib/libcurl.so.4`.

## Run

```sh
./build.sh                                   # builds build/harness-{before,after}
BENCH_LD_PRELOAD=/usr/local/lib/libcurl.so.4 python3 run_bench.py --reps 3
```

Results land in `results/results.json` and `results/summary.md`.

## What is and is not measured

- Measured with real clocks: STT finalize waits (fallback timers, early
  finalize), cleanup HTTP round-trips and budget timeouts, speculative
  hit/miss/skip behavior, and output-text accuracy per scenario.
- Not measurable here: DNS/TLS warm-up effects (`Cleaner.warm`, the launch
  warm-up) — localhost handshakes are ~0ms. Verify those on-device via the
  `latency summary:` lines in `~/Library/Logs/Quill.log`.

## Fidelity notes

- `patch_linux.py` applies mechanical transport shims (conditional
  `FoundationNetworking` import, `waitsForConnectivity` guard, env-var endpoint
  override for the baseline) IDENTICALLY to both variants; timing logic is
  untouched.
- `Support.swift` stubs the Cocoa-side types (`Log`, `Vocabulary`,
  `Inserter.CleanupContext`) and provides completion-handler overloads for
  `URLSessionWebSocketTask.send/receive` (Linux Foundation only ships the async
  forms).
- `harness_main.swift` mirrors the `finishSession` orchestration from
  `Sources/main.swift` (budget, raw fallback, speculative resolution), since
  `main.swift` itself cannot compile off-macOS.
