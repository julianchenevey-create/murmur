#!/usr/bin/env bash
# One-line install / update for Murmur. Paste into Terminal on your Mac:
#   curl -fsSL https://raw.githubusercontent.com/julianchenevey-create/murmur/main/scripts/install.sh | bash
#
# Downloads the latest Murmur.app (with whisper.cpp built in), downloads the speech model,
# turns off the 🌐 key's default action so fn can be the hotkey, and opens the app.
# Optional: MURMUR_MODEL=medium.en for the larger, more accurate model.
set -euo pipefail

REPO="julianchenevey-create/murmur"
MODEL="${MURMUR_MODEL:-small.en}"
CONFIG_DIR="$HOME/.config/murmur"
MODEL_FILE="$CONFIG_DIR/models/ggml-$MODEL.bin"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

[[ "$(uname)" == "Darwin" ]] || { echo "This installer is for macOS."; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || { echo "Murmur needs macOS 13 (Ventura) or newer."; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "Downloading Murmur"
curl -fL --progress-bar -o "$TMP/Murmur.zip" "https://github.com/$REPO/releases/latest/download/Murmur.zip"
ditto -x -k "$TMP/Murmur.zip" "$TMP"

say "Installing to Applications"
pkill -x Murmur 2>/dev/null || true
sleep 1
DEST="/Applications"
if ! { rm -rf "$DEST/Murmur.app" && cp -R "$TMP/Murmur.app" "$DEST/"; } 2>/dev/null; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/Murmur.app"
    cp -R "$TMP/Murmur.app" "$DEST/"
fi
xattr -dr com.apple.quarantine "$DEST/Murmur.app" 2>/dev/null || true
echo "Installed $DEST/Murmur.app"

mkdir -p "$CONFIG_DIR/models"
if [[ -f "$MODEL_FILE" ]]; then
    say "Speech model already downloaded ($MODEL)"
else
    say "Downloading speech model ($MODEL). This is a few hundred MB, so it may take a minute"
    curl -fL --progress-bar -o "$MODEL_FILE.part" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
    mv "$MODEL_FILE.part" "$MODEL_FILE"
fi

if [[ "$MODEL" != "small.en" && ! -f "$CONFIG_DIR/config.json" ]]; then
    printf '{\n  "transcription": { "modelPath": "~/.config/murmur/models/ggml-%s.bin" }\n}\n' "$MODEL" \
        > "$CONFIG_DIR/config.json"
fi

say "Setting the 🌐/fn key to \"Do Nothing\" so it can be the dictation hotkey"
defaults write com.apple.HIToolbox AppleFnUsageType -int 0

say "Opening Murmur"
open "$DEST/Murmur.app"

cat <<'EOF'

Almost done. Two clicks macOS makes you do yourself:

  1. Click "Allow" when Murmur asks for the microphone.
  2. When it asks for Accessibility, click "Open System Settings" and turn on Murmur.
     (System Settings › Privacy & Security › Accessibility)

Then hold fn, talk, and let go. A waveform icon in the menu bar means it's running.
If fn still opens the emoji picker, log out and back in once.

Optional: add a Groq/OpenAI/Anthropic key for filler-word cleanup via the menu bar
icon › "Open .env (API Keys)", then "Reload Settings".
EOF
