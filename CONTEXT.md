# Quill — agent / discussion context

Living notes from product work on this fork ([diliprt/quill](https://github.com/diliprt/quill)).
Read this before changing cleanup, vocabulary, latency, or versioning.

**Owner:** Riyu (product). Prefers working in code, PRs that can revert, versions staying on the 0.8 line until a real 1.0.

**Current shipped build:** **v0.8.9** on `main` (`5261a87`, merge of [PR #4](https://github.com/diliprt/quill/pull/4)).
Installed app: `~/Applications/Quill.app`. Log: `~/Library/Logs/Quill.log`.
Dictionary: `~/Library/Application Support/com.freeze.quill/vocabulary.json`.

**Rollback to last good night-of-merge:** `git checkout 5261a87 && ./build.sh`  
**Rollback before that (v0.8.7):** `git checkout 124b6f3 && ./build.sh`

---

## What this app is

Native macOS menu-bar dictation (`com.freeze.quill`). Dual keys:

- **Raw key** — STT only, no dictionary bias, no Grok.
- **Smart key** — STT → Grok cleanup → insert. Default layout on this machine: raw = 🌐/fn, smart = Right ⌘ (check the menu; it has been swapped at times).

Cleanup is a **light corrector** by default (punctuation, caps, typos, fillers, clear “X no actually Y”). It must never answer the transcript or rewrite meaning.

---

## Versioning (do not jump to 1.0)

Stay on **0.8.x**. A 1.0 means “product, done.” 1.2 would skip numbers and confuse history. Revisit 0.9 / 1.0 only after days of stable use and an explicit call.

| Version | SHA / PR | What landed |
|---------|----------|-------------|
| 0.8.7 | `124b6f3` / PR #3 | First-word / prewarm, stale-session guards, cropped circle captures |
| 0.8.8–0.8.9 | `5261a87` / PR #4 | Insert settle, speculation always on, STT rescue, patient edit-watch, vocab guards, cleanup styles |
| 0.8.10 | **not on main** | grok-4.3 + `low` reasoning on detailed — **rolled back** (PR #5 closed) |

---

## Cleanup styles (v0.8.9)

Menu: **Clean up with Grok → Cleanup style**

| Mode | Behaviour |
|------|-----------|
| Light | Punctuation / typos only (old behaviour) |
| **Detailed for long dictations (10s+)** | **Default.** Hold ≥10s → detailed editor (word order, false starts, run-ons). Shorter stays light. |
| Always detailed | Every smart dictation uses the detailed prompt |

Resolved at **key-release** (`sessionCleanupStyle`). Speculative request carries the same style.

Detailed must **not** teach the vocabulary (rewordings look like mishearings). Detailed skips the local “already clean” fast-path. Resemble-guard is looser for detailed (`0.55–1.5` length, 60% word overlap) vs light (`0.75–1.35`, 82%).

Long-form **does** fire detailed (confirmed in logs: 20s hold, 316→288 chars). Short follow-ups correctly stay light.

---

## Cleanup model — decided, then proven

**What Quill sends today (v0.8.9):** `grok-4-1-fast-non-reasoning`.

**What xAI actually runs (since 15 May 2026):** that slug is **retired**. It still resolves and redirects to **`grok-4.3` + `reasoning_effort=none`**. Official table: [May 15 retirement](https://docs.x.ai/developers/migration/may-15-retirement).

| Slug | Redirect |
|------|----------|
| `grok-4-1-fast-non-reasoning` (current) | `grok-4.3` + **none** |
| `grok-4-1-fast-reasoning` | `grok-4.3` + **low** |

`grok-4-1-fast-reasoning` is **not** a better/newer model. It is the same 4.3 with thinking turned on.

**Tried 2026-08-31 (v0.8.10, PR #5, closed):** pin `grok-4.3` and use `reasoning_effort=low` only on detailed. **Horrible in practice.** Every long-form request **timed out** at 2.5–3.5s and pasted **raw** after ~3.3s wait. Light/`none` still returned in ~500–650ms. User rolled back to 0.8.9.

**Do not** make 4.20 or 4.6 the *only* cleanup model — already tried as the primary path; short phrases felt slow (README, Aug 2026). **Do not** use a reasoning model on this path unless the budget is far larger than 3s (thinking never finished in the current window). If we retry a stronger long-form model later: much bigger detailed budget, or a non-reasoning stronger slug on detailed only — and A/B in the log (`cleanup ok` / `timed out`).

Single model, no fallback chain (retries added latency).

---

## Latency & speculation (log-driven)

From ~320 then ~129 real dictations:

- **Insert settle** used to apply the long 0.32s wait whenever circle capture was *enabled*. ~70% of inserts paid +160ms for an Alt+Tab that never happened. **Fix (0.8.8):** long settle only if **this session has captures**. Insert overhead now ~240ms.
- **Speculation governor** used to pause itself when hit-rate dipped. Pausing never made anything faster; the ten slowest inserts were all `spec=paused`. **Fix:** always speculate. Label `spec=none` only when there was no partial.
- **Clean-looking partials:** skipping speculation when the partial “already looked clean” forced the serial wait on the *longest* dictations (partials lag speech). **Fix:** speculate anyway; a truly clean final still takes the local fast-path.
- Remaining tax: long dictations often **miss** speculation (partial ≪ final) → ~1.2–1.8s total. Acceptable; not a quality bug.
- **STT rescue:** if audio flows, socket is up, no text for 10s → reconnect once and replay buffered PCM. Saved a real sentence (2026-08-31 09:24).
- **Edit-watch:** Electron (Cursor, Grok Bot) builds AX slowly. One 0.45s retry dropped ~14% of corrections. **Fix:** up to 3 retries over ~3s. Armed ~55/58 then 128/129.

---

## Vocabulary / learning

Local JSON, cap **400**. Sources: final insert, cleanup pairs (light only), post-paste edits, manual pin.

**Problem:** aliases like `GitHub ← Git`, `Shift ← Swift`, `ChatGPT ← Comment`, bidirectional clusters (Syanara/Signara, Origin/Origin Arc), and junk (`Send`, `I’ll`, `Run History`). Cleanup then “corrected” ordinary words into brands. One edit taught 15–24 updates.

**Shipped guards (0.8.9):** alias stoplist; alias cannot be another canonical term; wholesale rewrite (word overlap < 50%) teaches nothing; ≤3 substitutions per edit; sentence starts after `.!?:`; fragments of multi-word names not stored; ordinary single words need 5+ letters; expanded everyday-word list.

**One-time prune (local file, not in git):** 400→353, backup `vocabulary.json.bak-20260829-212927`. Canonicals: pinned `Syanara Ward`, `Origin Ark Studio` (Ark, not Arc).

**Still leaks (as of 2026-08-31):** `I’ll`, `Previous`, `Silence`, `Steer`, `Circle Back`, `Run History` / `Run Tap Say` / `Run Return`. Library ~380. Highest-value unshipped idea: periodic Grok tidy every ~25 dictations **after insert** (never delay paste); only drop unpinned low-count junk; never touch pinned/seed. Started then **not finished** — do not assume it exists.

**Vocab tests on macOS:** `FileManager` ignores `HOME` overrides and can wipe the real dictionary. Only run `vocab_test_main` via the Linux bench harness, or restore from backup first.

---

## Circle capture

Hold → speak / circle → **Alt+Tab to target** → release. Text inserts first, then images on the clipboard (never ⌘V text+image together — paste boxes drop the speech). Crops to the circled region. Settle delay only when the session actually captured.

---

## What we explicitly will not do (unless asked again)

- Jump version to 1.0 / 1.2.
- Aggressive rewrite of short phrases.
- Reasoning models on the default cleanup path (timed out, pasted raw).
- Bias STT keyterms on the **raw** key.
- Close a good PR without merging (that abandons `main`).
- Commit `.env` / secrets; push `--force` to main.

---

## How to verify

`~/Library/Logs/Quill.log`

- Insert: `final→insert` overhead ~240ms when no circles.
- Style: `stop (… ) style=light|detailed`
- Speculation: `fired` / `hit` / `miss` / `none` — never `paused` after 0.8.8.
- Cleanup: `cleanup ok` / `local fast-path` / `rejected (resemble)` / `timed out`
- Learning: `vocab: user edit taught` / `learned` / `edit-watch skipped`

Prefs: `defaults read com.freeze.quill` (`cleanupStyle` may be unset → Auto).

---

## Open / later

1. Vocab still accumulates UI-label and contraction junk; optional Grok hygiene pass every 25 dictations.
2. Long-dictation speculation misses (partial lag) — latency only.
3. A few light resemble-rejects still paste raw.
4. Stronger long-form model — only with a budget that actually fits, after 0.8.10’s lesson.
5. English (India) / `en-IN` — not available; accent is STT-side.

---

## Repo / build

`./build.sh` → signed `~/Applications/Quill.app` (identity **Quill Local Signing** in `~/Library/Keychains/quill-signing.keychain-db`). Do not ad-hoc sign if that keychain exists.

GitHub: push as **diliprt** (machine also has `oas-admin`; that account cannot write this fork). Repo-local credential helper may already pin `diliprt`.
