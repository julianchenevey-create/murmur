# Murmur

A small, local-first dictation tool for macOS, in the spirit of Wispr Flow. Hold a key,
talk, let go, and the cleaned-up text lands at your cursor in whatever app you're using.

- **Hold to talk.** Hold `fn` (or the key you configure), speak, release. Murmur transcribes and pastes.
- **Hands-free.** Double-tap the hotkey to record without holding anything. Tap once more to stop.
  Sessions stop by themselves after 5 minutes, so one you forget about can't keep recording.
- **Esc cancels.** It drops a recording, or kills a transcription that's already running. Esc is only
  watched, never swallowed, so it still reaches the app you're typing in.
- **Local or cloud transcription.** whisper.cpp runs on your Mac (offline), or the Groq / OpenAI
  Whisper API if you'd rather.
- **LLM cleanup.** Removes "um"s and false starts, fixes punctuation and casing. Works with Groq,
  OpenAI, Anthropic, or a local Ollama model. If cleanup fails, Murmur pastes the raw transcript.
- **Floating pill.** Shows that it's live and which mode you're in: Listening / Hands-free 0:42 / Transcribing.
- **Menu bar.** On/off toggle, launch at login, and quick access to the settings file.
- **No accounts, no telemetry.** Nothing leaves your Mac unless you put an API key in `.env`.

Requires macOS 13.3 (Ventura) or later.

---

## 1. Install

### Option A: one line in Terminal (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/julianchenevey-create/murmur/main/scripts/install.sh | bash
```

This downloads the latest `Murmur.app` (whisper.cpp is built in, so you don't need Homebrew),
downloads the `small.en` speech model, sets the 🌐 key to "Do Nothing", and opens the app.
Then click **Allow** for the microphone and turn Murmur on under **Accessibility**.
Run the same line again to update. For the larger model, use `... | MURMUR_MODEL=medium.en bash`.

Each update is a new ad-hoc signed build, so macOS may forget the Accessibility grant after
updating. If the hotkey stops working, see "Permissions reset after a rebuild" below.

### Option B: build it yourself (needs Xcode Command Line Tools)

```bash
# Xcode Command Line Tools (for `swift`), if you don't have them yet
xcode-select --install

# whisper.cpp: provides `whisper-cli` (and `whisper-server`)
brew install whisper-cpp

# Download a model (small.en is the default; medium.en is more accurate but slower)
scripts/download-model.sh small.en
# scripts/download-model.sh medium.en

# Build the app bundle and copy it to /Applications
chmod +x scripts/*.sh
scripts/build-app.sh --install
```

Murmur shows up as a waveform icon in the menu bar. There's no Dock icon.

> Run it from the `.app`, not with `swift run`. macOS ties microphone and Accessibility
> permissions to the app bundle, and Launch at Login only works for a bundled app.

## 2. Grant permissions

Open **System Settings › Privacy & Security** and enable **Murmur** in each of these:

| Permission | Why Murmur needs it | What happens without it |
|---|---|---|
| **Microphone** | Recording while you hold the hotkey. macOS asks the first time. | Recording fails and the pill says so. |
| **Accessibility** | Watching the hotkey and Esc system-wide (a keyboard event tap), and sending ⌘V / keystrokes to paste into other apps. | The menu bar icon shows ⚠︎ and the hotkey does nothing. |
| **Input Monitoring** | Some macOS versions also require this for keyboard event taps. Murmur asks for it only if the tap still fails after Accessibility is granted. | Same as above. |

The menu bar icon's **Permissions** submenu shows ✓/✗ for each one and opens the matching
settings pane. After you grant Accessibility, Murmur retries every 2 seconds. If the icon
still shows ⚠︎, quit and relaunch it.

### Using `fn` / 🌐 as the hotkey

By default, macOS opens the emoji picker or switches input source when you press 🌐 on its own.
Turn that off:
**System Settings › Keyboard › "Press 🌐 key to" → Do Nothing.**

Holding `fn` and pressing another key (for example fn+F1 for brightness) is treated as a
shortcut. Murmur discards that recording quietly.

### Permissions reset after a rebuild

An ad-hoc signed app gets a new identity on every build, so macOS forgets the Accessibility
grant. You'll see the toggle already on, but it doesn't work. Fix it either way:

- **Quick fix:** `tccutil reset Accessibility local.murmur.dictation`, then grant it again.
- **Permanent fix:** sign every build with the same certificate. In **Keychain Access › Certificate
  Assistant › Create a Certificate…**, name it `Murmur Dev`, set Identity Type to *Self-Signed Root*
  and Certificate Type to *Code Signing*. Then build with
  `CODESIGN_IDENTITY="Murmur Dev" scripts/build-app.sh --install`.

## 3. Use it

| Action | What it does |
|---|---|
| Hold hotkey, speak, release | Transcribes and pastes at the cursor |
| Double-tap hotkey | Starts a hands-free session (orange pill with 🔒 and a timer) |
| Tap hotkey during hands-free | Stops and pastes |
| Hands-free reaches 5:00 | Stops automatically (transcribes by default; can discard instead) |
| **Esc** while recording | Throws the recording away |
| **Esc** while transcribing | Stops whisper or the API call. Nothing is pasted |

By default the transcript stays on your clipboard after pasting, so you can paste it again
with ⌘V. To get your previous clipboard back instead, set `insert.restoreClipboard` to `true`.

## 4. Configuration

Everything lives in `~/.config/murmur/`:

| File | Purpose |
|---|---|
| `config.json` | Settings. Created with defaults on first launch. Comments and trailing commas are allowed. |
| `.env` | API keys (file permissions 600). Optional. |
| `models/` | whisper.cpp models |
| `murmur.log` | Local log of errors and timings. Transcript text is never logged. |
| `whisper.log` | Output from the most recent whisper-cli run, for debugging |

After editing, choose **Reload Settings** (⌘R) from the menu bar icon. Any key you leave out
uses its default value.

```jsonc
{
  // "fn", "rightOption", "rightCommand", "rightControl", "rightShift", "leftOption", ...
  // or a combo like "ctrl+option+space", "cmd+shift+d", "f13"
  "hotkey": "fn",
  "tapThresholdMs": 250,          // shorter presses count as taps
  "doubleTapWindowMs": 400,       // max gap between the two taps
  "handsFreeMaxSeconds": 300,
  "handsFreeTimeoutAction": "transcribe",   // or "discard"
  "showPill": true,

  "transcription": {
    "engine": "local",            // "local" | "groq" | "openai" | "auto" (API if a key exists, else local)
    "language": "en",             // or "auto" / "de" / ... (needs a non-.en model)
    "modelPath": "~/.config/murmur/models/ggml-small.en.bin",
    "whisperCliPath": "",         // empty = /opt/homebrew/bin or /usr/local/bin
    "threads": 0,
    "serverURL": "",              // e.g. "http://127.0.0.1:8178" to use whisper-server (see below)
    "groqModel": "whisper-large-v3-turbo",
    "openaiModel": "whisper-1",
    "vocabulary": ""              // names/jargon Whisper should spell right: "Kubernetes, Priya, Murmur"
  },

  "cleanup": {
    "provider": "auto",           // "auto" | "groq" | "openai" | "anthropic" | "ollama" | "none"
    "style": "sentence",          // or "casual": lowercase, light punctuation, like texting
    "extraInstructions": "",      // e.g. "Use British spelling."
    "groqModel": "llama-3.1-8b-instant",
    "openaiModel": "gpt-4.1-mini",
    "anthropicModel": "claude-haiku-4-5",
    "ollamaModel": "llama3.2:3b",
    "ollamaURL": "http://localhost:11434",
    "timeoutSeconds": 8           // slower than this → paste the raw transcript
  },

  "insert": {
    "method": "paste",            // "paste" (pasteboard + ⌘V) or "type" (simulated keystrokes)
    "restoreClipboard": false,    // true = put your previous clipboard back after pasting
    "restoreDelayMs": 500,
    "trailingSpace": false
  }
}
```

### API keys (`~/.config/murmur/.env`)

```bash
GROQ_API_KEY=gsk_...
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
```

`cleanup.provider: "auto"` uses the first key it finds, in the order Groq → OpenAI → Anthropic.
With no keys, cleanup is skipped and you get the raw Whisper transcript. Hosted models get
renamed and retired over time. If cleanup calls start failing with HTTP 404, update the model
name in `config.json`.

## Fully offline

- Leave `.env` empty, or set `transcription.engine` to `"local"` and `cleanup.provider` to `"none"`.
  Nothing is sent over the network.
- To keep cleanup offline too, install [Ollama](https://ollama.com), run `ollama pull llama3.2:3b`,
  and set `cleanup.provider` to `"ollama"`.

## Faster local transcription with whisper-server

`whisper-cli` loads the model from disk on every dictation. With `medium` that adds about a second.
To keep the model in memory, run the server and point Murmur at it:

```bash
whisper-server -m ~/.config/murmur/models/ggml-medium.en.bin --port 8178
```

```jsonc
"transcription": { "engine": "local", "serverURL": "http://127.0.0.1:8178" }
```

The server listens only on localhost, so this is still offline.

## Troubleshooting

- **Nothing happens when I hold the hotkey.** Check the Permissions submenu, then see
  "Permissions reset after a rebuild" above. If you use `fn`, set "Press 🌐 key to" to Do Nothing.
- **The pill says "whisper-cli failed".** Read `~/.config/murmur/whisper.log`. A wrong `modelPath`
  or a `.en` model combined with a non-English `language` are the usual causes.
- **Text appears in the wrong place, or isn't pasted.** Some apps block synthetic ⌘V (password
  fields, some terminals with secure input enabled). Try `"insert": { "method": "type" }`.
- **I use Dvorak or another non-QWERTY layout.** The paste shortcut is sent as the physical V key.
  If ⌘V lands on the wrong key, use `"method": "type"`.
- **A very short or silent recording does nothing.** That's on purpose. Whisper tends to invent
  text ("Thank you.") when given silence, so Murmur skips recordings under 0.3 s or with almost no sound.

## Project layout

```
Sources/Murmur/
  MurmurApp.swift          entry point (menu bar app with no Dock icon)
  AppDelegate.swift        menu bar item, launch at login, settings actions
  DictationController.swift  hold / double-tap / hands-free / Esc state machine
  HotkeyMonitor.swift      CGEventTap: fn and modifier keys, key combos, Esc
  AudioRecorder.swift      AVAudioEngine → 16 kHz mono → WAV
  Transcriber.swift        whisper-cli, whisper-server, Groq / OpenAI APIs
  Cleaner.swift            LLM cleanup prompt and providers
  Inserter.swift           pasteboard + ⌘V, or simulated typing; clipboard restore
  PillWindow.swift         floating SwiftUI status pill
  Config.swift / Support.swift / Permissions.swift
```
