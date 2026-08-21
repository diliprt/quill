# Before/after benchmark report — dictation latency improvements

Method: the real `Sources/STT.swift` + `Sources/Cleaner.swift` (+
`SpeculativeCleanup.swift`) compiled into a harness on Linux (Swift 6.0.3,
`-swift-version 5`), driven against mock STT WebSocket / Grok-cleanup HTTP
servers with scripted delays. `before` = these files as on `main`; `after` =
this branch. 3 reps per config, medians reported; run-to-run jitter was ≤5ms.
All times are ms from "user stops" to "text ready to insert" (the insert settle
of 0.16–0.22s applies equally to every variant and is excluded).

## Results

| scenario | what it exercises | before | after | after + speculative | text accuracy |
|---|---|---|---|---|---|
| fast_done | server finalizes 150ms after stop | 151 | 151 | — | ok / ok |
| slow_done | `transcript.done` takes 2.5s | 2503 | **2000** | — | ok / ok |
| missing_done_sf | `done` never arrives, speech_final seen | 3000 | **2000** | — | ok / ok |
| missing_done_nosf | `done` never arrives, no speech_final | 3000 | **2000** | — | ok / ok |
| late_tail | last segment lands 400ms after stop | 2503 | 2401 | — | ok / ok (tail kept) |
| late_head | server revises segment with missing head 1s later | 1401 | 1402 | — | ok / ok (head kept) |
| consolidated_fast | `done` carries better text at 200ms | 201 | 201 | — | ok / ok |
| consolidated_slow | `done` carries better text at 1.2s | 1202 | 1202 | — | ok / ok |
| empty_interims | empty partials must not wipe text | 151 | 151 | — | ok / ok |
| long_multiseg | ~700 chars over 4 segments | 301 | 301 | — | ok / ok |
| smart_fast | cleanup 300ms | 457 | 456 | **303** | ok / ok / ok |
| smart_slow_clean | long text, cleanup 2s | 2306 | 2306 | **2004** | ok / ok / ok |
| smart_timeout | cleanup over budget → raw | 1683 | 1683 | 1532 | ok / ok / ok |
| resemble_reject | over-rewrite rejected → raw | 456 | 457 | **304** | ok / ok / ok |
| spec_hit | partial == final, cleanup 800ms | 956 | 956 | **803** | ok / ok / ok |
| spec_miss | transcript grew after stop | 3313 | 3207 | 3204 (2 requests) | ok / ok / ok |
| spec_empty | nothing said before stop → spec skipped | 906 | 906 | 906 | ok / ok / ok |
| spec_race | cleanup (100ms) faster than finalize | 506 | 506 | **402** | ok / ok / ok |
| fastpath_clean | STT already formatted the sentence | 457 | **151** (0 requests) | 153 (0 requests) | ok / ok / ok |
| fastpath_lower | unformatted → must still use model | 455 | 455 | 303 | ok / ok / ok |
| resemble_filler | filler-heavy speech, correct cleanup shrinks | 455 | 455 | 303 | **DIFF** (old bug) / ok / ok |
| spec_norm_hit | final transcript gains a trailing period | 1306 | 1306 | **803** (1 request) | ok / ok / ok |

## What improved

1. **Early finalize (biggest win).** Whenever the server is slow to send
   `transcript.done` — or never sends it — the wait collapses from 2.5–3.0s to
   0.35s (`slow_done` −86%, `missing_done_sf` −88%, `late_tail` −70% with the
   tail segment still captured by the grace window). When the server is already
   fast (≤350ms), nothing changes.
2. **Fallback 3s → 2s.** The worst case with no `speech_final` signal at all
   drops 1s (`missing_done_nosf`).
3. **Speculative cleanup (toggle on).** On the smart lane it consistently
   overlaps the finalize wait with the model call: −151ms on short
   dictations (`smart_fast` 457→306), −300ms on long ones
   (`smart_slow_clean` 2307→2007), −150ms on `spec_hit`. It never produced
   wrong text: a miss re-sends with the final transcript (correct output, one
   extra request), an empty partial skips speculation, and the resemble/budget
   guards still fire through the speculative path.

## Round 2: cleaner-side fixes (same harness, added scenarios)

4. **Local fast-path** (`Cleaner.alreadyClean`): when the transcript is short
   (≤80 chars), a single sentence, already capitalized and terminated, with no
   fillers or self-correction markers, the smart lane inserts it as-is —
   `fastpath_clean` went 457→151ms with **zero** API requests. The gate is
   conservative: unformatted text (`fastpath_lower`) still goes to the model
   unchanged, and speculation is skipped for already-clean text so no request
   is wasted.
5. **Filler-aware resemble guard**: before, a filler-heavy sentence
   ("um so uh um i think um uh friday works um") had its *correct* cleanup
   rejected — the guard compared lengths against the raw original and the model
   had legitimately removed the fillers the prompt told it to remove — so the
   raw ums were pasted (`resemble_filler` before: fallback=true, wrong text).
   After: fillers are stripped from the original before comparing; the cleanup
   is accepted. Pure quality fix, no latency change.
6. **Normalized speculative matching**: the server flushing a trailing period
   into the final transcript used to turn a hit into a miss (second request +
   full serial wait). Now whitespace/case/trailing punctuation are normalized
   before comparing: `spec_norm_hit` resolves as a hit — 805ms with 1 request
   instead of a 2-request miss.

## Round 3: eager insert, self-tuning speculation, quality guards

7. **Early-finalize grace widened 0.35s → 0.6s** in response to a real quality
   drop reported after the first on-device build (suspected tail clipping).
   Slow-finalize scenarios now land at 600ms instead of 350ms — still 4–5×
   faster than before — and the window is tunable without rebuilding:
   `defaults write com.freeze.quill earlyFinalizeGrace -float 1.0`. Every early
   finalize now writes an `early finalize — no transcript.done within …s` log
   line, so tail clipping can be confirmed or ruled out from `Quill.log`.
8. **"Paste raw first, polish in place"** (toggle, default off): the smart lane
   inserts the raw transcript at raw-lane speed, then swaps in the polished
   version via Accessibility only when the field still ends with exactly what
   was pasted (nothing typed), the field is not secure, and the AX attributes
   are settable; otherwise the raw text simply stays. Not measurable in this
   harness (Accessibility is macOS-only) — the timing benefit equals the raw
   lane rows above, with polish arriving ~0.5–1.5s later in place.
9. **Self-tuning speculation**: a rolling window (last 12 sessions) of
   hit/miss outcomes pauses speculation when the hit rate drops below 40%
   (min 8 samples) and — because outcomes keep being recorded from the
   stop-time snapshot even while paused — resumes on its own. Verified by 14
   deterministic assertions in `bench/governor_test_main.swift`
   (run as part of `bench/build.sh`).

## Round 4: head-clipping regression — reproduced, fixed

On-device reports after the first build of this branch: leading words dropped
("Can we review the Architecture…" → "Architecture…"). Reproduced in the
harness with the `late_head` scenario: after `audio.done`, the server's first
pass misses the opening words and is `speech_final`; it re-emits the SAME
segment ~1s later with the head recovered. The speech_final early-finalize
(0.6s grace) completed before that revision arrived — the pre-PR code, waiting
for `transcript.done`, kept the full sentence. Exact repro: after-code returned
"architecture to make sure we are doing the right thing", before-code returned
the full "can we review the architecture to make sure we are doing the right
thing".

Fixes, all verified by the matrix above:
- **speech_final early finalize is now OFF by default** (`earlyFinalizeGrace`
  defaults to 0 = disabled; re-enable for experiments via `defaults write`).
- **The fallback timer is now a quiet window**: 2.0s, restarted on EVERY
  partial after `audio.done` (6.0s hard cap). An actively-revising server is
  never cut off; a silent line still completes 1s sooner than the old fixed
  3.0s.
- **Tail-only `transcript.done` guard**: a non-empty done shorter than ~90% of
  the accumulated partials no longer replaces them wholesale.
- **Mic tap buffer reverted 1024 → 2048** — it shipped alongside the reported
  quality drop and its ~20ms benefit is not worth audio-path risk.

Net effect vs the aggressive round-3 numbers: pathological finalize waits
settle at 2000ms instead of 600ms — still better than the pre-PR 2500–3000ms —
and every accuracy scenario now passes, including the two that previously
documented deliberate trades (`late_head`, `consolidated_slow`).

## Round 5: correction-learning audit — found broken, fixed

Asked whether "learn from my edits after paste" works, the audit found a
pre-existing bug (not introduced by this branch): fixing a word IN PLACE — the
most common correction gesture — taught nothing. Typing "ra" to turn "Signa"
into "Signara" made the diff isolator (`editedMiddles`) hand the learner the
raw character fragment "ra", which matches no word. Learning only worked when
a whole word was selected and replaced.

Fixes, verified by 11 deterministic assertions in `bench/vocab_test_main.swift`
(compiled against the real shipped `Vocabulary.swift`, run by `bench/build.sh`):
- `editedMiddles` expands the changed span to word boundaries (inside the
  common prefix/suffix, so both sides stay aligned) — in-place fixes now teach
  the full word pair (Signa → Signara stored as term + alias).
- Multi-word extraction strips leading everyday capitalized words, so cleanup
  pairs teach "Grok Build", not "Tell Grok Build".
- Regression guards all pass: identical text, appended everyday words, and
  disabled toggles still teach nothing; common words are never stored.

The runtime chain was audited and is intact: insert completion arms
`PostInsertEditWatch` (snapshot 0.55s after paste, 1Hz polls, 30s window,
2 stable ticks after an edit), and the round-3 eager polish re-arms the watcher
with the polished text so Quill's own swap is never mistaken for a user edit.
On-device confirmation: `vocab: edit-watch armed` then `vocab: user edit
taught …` in Quill.log after hand-fixing a pasted word.

## What did not improve

- **Fast-server scenarios** (`fast_done`, `consolidated_fast`,
  `empty_interims`, `long_multiseg`): unchanged, as expected — there was no
  dead time to remove. The changes are pure tail-latency fixes.
- **`spec_empty`**: speculation can't help when nothing was said before stop.
- **Speculative on a miss**: no latency win over plain "after" (1555 vs
  1558) and costs a second Grok request.

## The one measured regression

`consolidated_slow`: if the server sends a *consolidated, corrected* transcript
in `transcript.done` more than ~350ms after the last speech_final partial, the
early finalize inserts the accumulated partials instead (kept `hello world`,
lost `Hello, world.`). Mitigations already in place: the 0.35s grace window
catches consolidations that arrive quickly (`consolidated_fast` stays
accurate), and the protocol note in `STT.swift` — verified live against the
real endpoint — says the real server sends `transcript.done` with **empty**
text, so this path is defensive, not observed in production. If a future
server change starts populating it, raise `earlyFinalizeGrace`.

## Keep / remove verdicts

| change | verdict | why |
|---|---|---|
| Early finalize on speech_final | **Removed (default off)** | Clipped the head of real dictations (round 4); replaced by the activity-aware quiet window. |
| Quiet-window fallback (2s, activity-reset, 6s cap) | **Keep** | 1s faster than the old fixed 3s when the line is quiet; never cuts off a server mid-revision. |
| Speculative cleanup toggle | **Keep, default off** | 150–300ms consistent smart-lane win, never wrong text; extra request on a miss is why it stays opt-in. Turn it on and watch `spec=hit/miss` in the log — if your miss rate is low, leave it on. |
| Cleanup warm at smart key-down | **Keep, verify on-device** | Not measurable against localhost mocks. Mechanism is sound and your own logs measured ~1.9s cold vs ~0.8–0.9s warm; confirm via `cleanup ok … ms` before/after on the Mac. Revert if no delta. |
| Launch warm-up of api.x.ai | **Keep, verify on-device** | Same: costs one throwaway request at launch, expected to shave several hundred ms off the *first* dictation only. |
| Mic buffer 2048 → 1024 | **Reverted** | Shipped alongside the reported quality drop; ~20ms was never worth audio-path risk. |
| Latency summary log line | **Keep** | It is the on-device instrument for everything above. |
| Local fast-path (already-clean) | **Keep** | 3× faster and 0 requests on formatted short phrases; conservative gate leaves everything else on the model path. Only fires if the real STT emits formatted text — check `spec=local` in the log. |
| Filler-aware resemble guard | **Keep** | Fixes a real bug: correct cleanups of filler-heavy speech were being rejected and the fillers pasted back. |
| Normalized speculative matching | **Keep** | Converts trailing-punctuation/whitespace near-misses into hits; word content must still match exactly. |
| Early-finalize / finalize logging | **Keep** | `early finalize`, `finalize hard cap`, and `transcript.done shorter…` log lines make finalize behavior visible on-device. |
| Eager insert (paste raw, polish in place) | **Keep, default off** | Raw-lane speed with polish arriving in place; guarded so it never touches a field the user has typed into. Needs on-device validation across apps (Electron fields may refuse the AX swap — raw text stays, which is the safe failure). |
| Speculation governor | **Keep** | Makes the speculative toggle self-managing; logic unit-tested, watch `spec=paused` in the log. |

## Reproduce

See `bench/README.md`. `results.json` has every scenario/variant with raw
numbers.
