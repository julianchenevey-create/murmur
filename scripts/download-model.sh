#!/usr/bin/env bash
# Downloads a whisper.cpp model into ~/.config/murmur/models.
# Usage: scripts/download-model.sh [small.en|small|medium.en|medium|large-v3-turbo-q5_0|...]
#   small.en  (~465 MB) fast, English only (default)
#   medium.en (~1.5 GB) more accurate, slower
#   small / medium: multilingual. Set transcription.language to your language or "auto".
set -euo pipefail

MODEL="${1:-small.en}"
DEST="$HOME/.config/murmur/models"
FILE="$DEST/ggml-$MODEL.bin"
URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"

mkdir -p "$DEST"
if [[ -f "$FILE" ]]; then
    echo "Already have $FILE"
else
    echo "Downloading $URL"
    curl -L --fail --progress-bar -o "$FILE.part" "$URL"
    mv "$FILE.part" "$FILE"
fi

echo
echo "Done. In ~/.config/murmur/config.json set:"
echo "  \"transcription\": { \"modelPath\": \"~/.config/murmur/models/ggml-$MODEL.bin\" }"
echo "then choose Reload Settings from the menu bar icon."
