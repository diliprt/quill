# Quill

**Speak anywhere on your Mac. The text lands where you point.**

Tap a key, talk, then click into whatever window you want the words in. They appear there — at
the end of what's already written, without touching your clipboard.

Quill transcribes with **your existing Grok subscription**, so there's no API key to buy and
nothing metered.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xfreeze2/quill/main/install.sh | bash
```

Installs to `~/Applications`, so it never asks for your password. Quill opens and walks you
through the three things it needs.

Prefer to do it by hand? Grab `Quill.zip` from
[Releases](https://github.com/xfreeze2/quill/releases), unzip it into `~/Applications`, and run:

```sh
xattr -dr com.apple.quarantine ~/Applications/Quill.app && open ~/Applications/Quill.app
```

That last step is needed because Quill isn't notarised by Apple — macOS quarantines anything
downloaded from the internet. See [Why the quarantine step](#why-the-quarantine-step).

## Use it

1. **Tap `Control`** — a panel appears in the corner and starts listening.
2. **Talk.** The transcript streams in live as you speak.
3. **Click wherever you want the words.** That click stops the recording *and* chooses the
   destination. Tap `Control` again instead if you want them where your cursor already is.

The corner pill is clickable too, if you'd rather use the mouse for both ends. Drag it anywhere;
it stays where you put it.

## What you need

| | |
|---|---|
| **macOS 12 or newer** | Universal — Apple Silicon and Intel |
| **A Grok subscription** | Quill uses the login the `grok` CLI stores. Without it there's nothing to transcribe with. |
| **Microphone access** | Asked for on first use |
| **Accessibility access** | So the trigger key works, and so Quill can type into other apps |

The setup window shows all of these live, with a button next to whatever isn't ready. It reopens
from the menu any time.

> **If only the corner pill responds and the keyboard does nothing, that's always Accessibility.**
> macOS lets an app create a keyboard listener without permission and then simply never sends it
> anything. Quill turns its pill **amber** when this is the case — click it and it takes you
> straight to the right settings pane.

## Settings

Right-click the pill (or the menu-bar icon):

- **Trigger** — `Control`, right `⌘`, right `⌥`, `🌐`, or `F5`; single tap or double tap
- **Click anywhere to insert** — the click-to-choose-destination gesture
- **Insert at end of field** — append after existing text rather than at the cursor
- **Language** — 24 supported
- **Recent** — your last 20 transcripts, click to copy
- **Start at login**, **Show corner button**, **Reset panel position**

### About the trigger key

Bare modifier taps are used deliberately: a modifier pressed on its own means nothing to macOS or
to any app, so it can't shadow a shortcut in whatever you're typing into.

Chords are filtered out without needing Input Monitoring. Rather than watching the keypress inside
`⌃C` — which requires that permission — Quill samples the system's input-activity counters when
the modifier goes down and again when it comes up. Different counts mean you were pressing
something, so it stays quiet. Clicks and scrolls count too, since `⌃`-click is the right-click
gesture and `⌃`-scroll is screen zoom, and neither moves a key counter.

`F5` is offered but rarely useful: on most Macs the function row is in media mode, where F5 *is*
the system Dictation key and never arrives as a keypress at all.

## How the text gets in

Quill doesn't simulate `⌘V` and doesn't touch your clipboard.

1. It asks Accessibility for the focused element.
2. It reads what's already in that field and puts the caret after the last character.
3. It writes the text into the selection, joining with a space if needed.

Terminals, canvases and most web views expose no editable text to Accessibility. Those fall back
to a synthetic `⌘V` — but the caret is still moved to the end first where possible, and your
previous clipboard contents are snapshotted and restored afterwards. Either way, what you had
copied is still there when it's done.

## Privacy

- Your audio is streamed to xAI's speech-to-text service to be transcribed. Nothing goes anywhere
  else.
- Your Grok token is read fresh from `~/.grok/auth.json` at the start of each recording. Quill
  never copies, stores or transmits it anywhere except to xAI.
- Your last 20 transcripts are kept locally so you can re-copy them. Clear them with
  `defaults delete com.freeze.quill history`.
- Quill does **not** log keystrokes. A debug trail exists for troubleshooting the trigger key and
  stays off unless you explicitly turn it on.
- `~/Library/Logs/Quill.log` records what it did — which app it wrote into, and whether the text
  landed.

## Why the quarantine step

Quill is signed, but with a self-signed certificate rather than an Apple Developer one, and it
isn't notarised. macOS quarantines anything downloaded from the internet and refuses to open apps
it can't trace to a paid Apple developer account — usually with a misleading "damaged" message.

The install script strips that quarantine flag for you. Removing it is your decision to trust this
app, the same decision Homebrew makes on your behalf for every cask you install. If you'd rather
not, build from source instead — locally built apps are never quarantined.

## Build from source

```sh
git clone https://github.com/xfreeze2/quill && cd quill
./signing/install-identity.sh   # once per machine
./build.sh
open -a Quill
```

No Xcode project and no dependencies — `swiftc` against Cocoa and AVFoundation, assembled into a
bundle by `build.sh`.

`install-identity.sh` creates a local self-signed certificate so the app's code identity stays
stable between builds. That matters more than it sounds: with ad-hoc signing macOS treats every
rebuild as a brand-new app, silently drops your Accessibility and Microphone grants, and leaves
the old entries sitting in System Settings still looking enabled. The certificate lives in its own
keychain, so builds never prompt for your password.

Verify the transcription path without a microphone:

```sh
# 16 kHz mono PCM16: ffmpeg -i in.wav -ar 16000 -ac 1 -f s16le out.pcm
QUILL_SELFTEST=out.pcm ~/Applications/Quill.app/Contents/MacOS/Quill
```

## Known limits

- Settings live per-machine and don't sync.
- A recording stops itself after 5 minutes, or after 10 seconds if it hears nothing at all.
- If your Grok token has expired and `grok` isn't running to refresh it, Quill says so rather than
  failing quietly.
- Not notarised — see above.

## Licence

MIT. Use it for anything.
