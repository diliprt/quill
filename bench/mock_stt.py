"""Mock of wss://api.x.ai/v1/stt with scripted, deterministic timelines.

The scenario is selected by URL path (query params are rewritten by STTClient,
the path survives). Each scenario is:
  pre:  [(ms_from_connect, message), ...]   partials streamed while "speaking"
  post: [(ms_from_audio_done, message), ...] tail after the client sends audio.done

Message helpers build the exact JSON shapes STT.swift parses.
"""
import asyncio
import json
import sys

import websockets


def partial(start, text, speech_final=False, is_final=False):
    return {"type": "transcript.partial", "start": start, "text": text,
            "is_final": is_final, "speech_final": speech_final}


def done(text=""):
    return {"type": "transcript.done", "text": text}


LONG_SEG = ("the quick brown fox jumps over the lazy dog and keeps running through "
            "the field while the narrator keeps talking about nothing in particular "
            "for quite a while longer than anyone asked for ")
LONG_TEXT = (LONG_SEG * 4).strip()  # ~700 chars

SCENARIOS = {
    # -------- raw-lane latency --------
    "fast_done": {
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(150, done())],
    },
    "slow_done": {
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(2500, done())],
    },
    "missing_done_sf": {  # server never sends done; last partial was speech_final
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [],
    },
    "missing_done_nosf": {  # never done, never speech_final -> pure fallback timer
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world"))],
        "post": [],
    },
    "late_tail": {  # a second segment lands only after audio.done
        "pre": [(300, partial(0, "hello world"))],
        "post": [(400, partial(1.0, "and more", speech_final=True, is_final=True)),
                 (2500, done())],
    },
    # -------- accuracy --------
    "consolidated_fast": {  # done carries better text, arrives quickly
        "pre": [(800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(200, done("Hello, world."))],
    },
    "consolidated_slow": {  # done carries better text, later than the grace window
        "pre": [(800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(1200, done("Hello, world."))],
    },
    "empty_interims": {  # empty partials between segments must not wipe text
        "pre": [(300, partial(0, "hello world", speech_final=True, is_final=True)),
                (500, partial(0.5, "")),
                (700, partial(0.6, ""))],
        "post": [(150, done())],
    },
    "long_multiseg": {
        "pre": [(200, partial(0, LONG_SEG.strip())),
                (500, partial(1.0, LONG_SEG.strip())),
                (700, partial(2.0, LONG_SEG.strip())),
                (900, partial(3.0, LONG_SEG.strip(), speech_final=True, is_final=True))],
        "post": [(300, done())],
    },
    # -------- smart lane reuses fast_done/late_tail timelines --------
    "spec_empty": {  # nothing said before stop; text arrives during finalize
        "pre": [],
        "post": [(400, partial(0, "hello world", speech_final=True, is_final=True)),
                 (600, done())],
    },
    "spec_race": {  # finalize slower than the speculative cleanup
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(400, done())],
    },
    # -------- local fast-path / guard fixes --------
    "fastpath_clean": {  # STT already formatted the sentence
        "pre": [(300, partial(0, "Send it to John.")),
                (800, partial(0, "Send it to John.", speech_final=True, is_final=True))],
        "post": [(150, done())],
    },
    "fastpath_lower": {  # unformatted -> must still go to the model
        "pre": [(300, partial(0, "send it to john")),
                (800, partial(0, "send it to john", speech_final=True, is_final=True))],
        "post": [(150, done())],
    },
    "resemble_filler": {  # filler-heavy; a correct cleanup shrinks a lot
        "pre": [(300, partial(0, "um so uh um i think um uh friday works um")),
                (800, partial(0, "um so uh um i think um uh friday works um",
                              speech_final=True, is_final=True))],
        "post": [(150, done())],
    },
    "spec_norm_hit": {  # final transcript = partial + a flushed trailing period
        "pre": [(300, partial(0, "hello world")),
                (800, partial(0, "hello world", speech_final=True, is_final=True))],
        "post": [(100, partial(0, "hello world.", speech_final=True, is_final=True)),
                 (500, done())],
    },
}
# Smart-lane scenarios share raw timelines under their own names.
for alias, base in [
    ("smart_fast", "fast_done"), ("smart_slow_clean", "long_multiseg"),
    ("smart_timeout", "fast_done"), ("spec_hit", "fast_done"),
    ("spec_miss", "late_tail"), ("resemble_reject", "fast_done"),
]:
    SCENARIOS[alias] = SCENARIOS[base]


async def handler(ws):
    name = ws.request.path.strip("/").split("?")[0]
    scenario = SCENARIOS.get(name)
    if scenario is None:
        await ws.close(code=1008, reason=f"unknown scenario {name}")
        return
    await ws.send(json.dumps({"type": "transcript.created", "id": name}))

    t0 = asyncio.get_event_loop().time()

    async def stream_pre():
        for ms, message in scenario["pre"]:
            delay = t0 + ms / 1000 - asyncio.get_event_loop().time()
            if delay > 0:
                await asyncio.sleep(delay)
            await ws.send(json.dumps(message))

    pre_task = asyncio.create_task(stream_pre())
    try:
        async for raw in ws:
            if isinstance(raw, bytes):
                continue  # PCM, ignored
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if message.get("type") == "audio.done":
                await pre_task  # anything still scheduled pre-stop flushes first
                td = asyncio.get_event_loop().time()
                for ms, out in scenario["post"]:
                    delay = td + ms / 1000 - asyncio.get_event_loop().time()
                    if delay > 0:
                        await asyncio.sleep(delay)
                    await ws.send(json.dumps(out))
                # Keep the socket open; the client closes when it completes.
    except websockets.ConnectionClosed:
        pass
    finally:
        pre_task.cancel()


async def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    async with websockets.serve(handler, "127.0.0.1", port):
        print(f"mock stt on :{port}", flush=True)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
