"""Benchmark driver: runs the scenario matrix through harness-before and
harness-after (speculative off and on), 3 reps each, and writes
results/results.json plus a markdown summary of medians and accuracy.

Usage: python3 run_bench.py [--reps 3] [--only SCENARIO]
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

from mock_stt import LONG_SEG

HERE = Path(__file__).parent
STT_PORT, CHAT_PORT = 8765, 8766
STT_URL = f"ws://127.0.0.1:{STT_PORT}"
CHAT_URL = f"http://127.0.0.1:{CHAT_PORT}/v1/chat/completions"

SEG = LONG_SEG.strip()
LONG_JOINED = " ".join([SEG] * 4)
LONG_CLEANED = LONG_JOINED[:1].upper() + LONG_JOINED[1:] + "."

# name -> (lane, chat params or None, expected output, note)
SCENARIOS = {
    # raw lane
    "fast_done":         ("raw", None, "hello world", "done 150ms after stop"),
    "slow_done":         ("raw", None, "hello world", "done 2.5s after stop"),
    "missing_done_sf":   ("raw", None, "hello world", "no done; speech_final seen"),
    "missing_done_nosf": ("raw", None, "hello world", "no done; no speech_final"),
    "late_tail":         ("raw", None, "hello world and more", "segment lands 400ms after stop"),
    "consolidated_fast": ("raw", None, "Hello, world.", "done carries better text @200ms"),
    "consolidated_slow": ("raw", None, "Hello, world.", "done carries better text @1.2s (beyond grace)"),
    "empty_interims":    ("raw", None, "hello world", "empty partials must not wipe text"),
    "long_multiseg":     ("raw", None, LONG_JOINED, "~700 chars over 4 segments"),
    # smart lane
    "smart_fast":        ("smart", "delay_ms=300&mode=clean", "Hello world.", "cleanup 300ms"),
    "smart_slow_clean":  ("smart", "delay_ms=2000&mode=clean", LONG_CLEANED, "long text, cleanup 2s"),
    "smart_timeout":     ("smart", "delay_ms=3000&mode=clean", "hello world", "cleanup over budget -> raw"),
    "resemble_reject":   ("smart", "delay_ms=300&mode=rewrite", "hello world", "rewrite rejected -> raw"),
    "spec_hit":          ("smart", "delay_ms=800&mode=clean", "Hello world.", "partial == final"),
    "spec_miss":         ("smart", "delay_ms=800&mode=clean", "Hello world and more.", "final grew after stop"),
    "spec_empty":        ("smart", "delay_ms=300&mode=clean", "Hello world.", "nothing said before stop"),
    "spec_race":         ("smart", "delay_ms=100&mode=clean", "Hello world.", "cleanup faster than finalize"),
    "fastpath_clean":    ("smart", "delay_ms=300&mode=echo", "Send it to John.", "already formatted -> local fast-path"),
    "fastpath_lower":    ("smart", "delay_ms=300&mode=clean", "Send it to john.", "unformatted -> still goes to model"),
    "resemble_filler":   ("smart", "delay_ms=300&mode=strip_fillers", "So i think friday works.",
                          "filler-heavy; guard must accept the shrink"),
    "spec_norm_hit":     ("smart", "delay_ms=800&mode=clean", "Hello world.", "final gains trailing period; normalized hit"),
}


def run_one(binary, scenario, lane, chat_params, spec, ld_preload):
    env = os.environ.copy()
    env["SCENARIO"] = scenario
    env["LANE"] = lane
    env["SPEC"] = spec
    env["STOP_MS"] = "1000"
    env["QUILL_STT_URL"] = f"{STT_URL}/{scenario}"
    if chat_params:
        env["QUILL_CHAT_URL"] = f"{CHAT_URL}?{chat_params}"
    if ld_preload:
        env["LD_PRELOAD"] = ld_preload
    proc = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=30)
    for line in proc.stdout.splitlines():
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return {"error": f"no json (rc={proc.returncode}, stderr tail: {proc.stderr[-300:]})"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=3)
    ap.add_argument("--only")
    ap.add_argument("--ld-preload", default=os.environ.get("BENCH_LD_PRELOAD", ""))
    args = ap.parse_args()

    servers = [
        subprocess.Popen([sys.executable, HERE / "mock_stt.py", str(STT_PORT)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
        subprocess.Popen([sys.executable, HERE / "mock_chat.py", str(CHAT_PORT)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
    ]
    time.sleep(1.0)

    configs = []  # (variant, scenario, spec)
    for name, (lane, _, _, _) in SCENARIOS.items():
        if args.only and name != args.only:
            continue
        configs.append(("before", name, "off"))
        configs.append(("after", name, "off"))
        if lane == "smart":
            configs.append(("after", name, "on"))

    results = []
    try:
        for variant, name, spec in configs:
            lane, chat_params, expected, note = SCENARIOS[name]
            binary = HERE / "build" / f"harness-{variant}"
            runs = []
            for _ in range(args.reps):
                r = run_one(binary, name, lane, chat_params, spec, args.ld_preload)
                runs.append(r)
            ready = [r["stop_to_ready_ms"] for r in runs if "stop_to_ready_ms" in r]
            final = [r["stop_to_final_ms"] for r in runs if "stop_to_final_ms" in r]
            outputs = {r.get("output", r.get("error", "?")) for r in runs}
            entry = {
                "variant": variant, "scenario": name, "spec": spec, "lane": lane,
                "note": note,
                "median_stop_to_ready_ms": statistics.median(ready) if ready else None,
                "median_stop_to_final_ms": statistics.median(final) if final else None,
                "chat_requests": runs[0].get("chat_requests"),
                "spec_label": runs[0].get("spec"),
                "expected": expected,
                "outputs": sorted(outputs),
                "accurate": outputs == {expected},
                "raw_fallback": any(r.get("raw_fallback") for r in runs),
                "errors": [r["error"] for r in runs if "error" in r],
            }
            results.append(entry)
            ok = "OK " if entry["accurate"] else "TEXT!"
            print(f"{variant:6} {name:18} spec={spec:3} "
                  f"ready={entry['median_stop_to_ready_ms']}ms {ok}", flush=True)
    finally:
        for s in servers:
            s.terminate()

    out = HERE / "results"
    out.mkdir(exist_ok=True)
    (out / "results.json").write_text(json.dumps(results, indent=2))

    lines = ["| scenario | note | before ms | after ms | after+spec ms | accuracy |",
             "|---|---|---|---|---|---|"]
    by = {(r["variant"], r["scenario"], r["spec"]): r for r in results}
    for name, (lane, _, expected, note) in SCENARIOS.items():
        if args.only and name != args.only:
            continue
        b = by.get(("before", name, "off"), {})
        a = by.get(("after", name, "off"), {})
        s = by.get(("after", name, "on"), {})
        acc = []
        for tag, r in [("before", b), ("after", a), ("spec", s)]:
            if r:
                acc.append(f"{tag}:{'ok' if r.get('accurate') else 'DIFF'}")
        lines.append(
            f"| {name} | {note} | {b.get('median_stop_to_ready_ms', '—')} "
            f"| {a.get('median_stop_to_ready_ms', '—')} "
            f"| {s.get('median_stop_to_ready_ms', '—')} | {' '.join(acc)} |")
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
