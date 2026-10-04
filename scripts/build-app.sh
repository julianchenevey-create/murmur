#!/usr/bin/env bash
# Builds build/Murmur.app. Pass --install to copy it to /Applications.
# Set UNIVERSAL=1 for an arm64 + x86_64 binary.
#
# Signing: by default the app is ad-hoc signed, which means macOS treats every rebuild as a
# new app and you must re-grant Accessibility. To avoid that, create a self-signed
# "Code Signing" certificate in Keychain Access (see README) and run:
#   CODESIGN_IDENTITY="Murmur Dev" scripts/build-app.sh --install
set -euo pipefail
cd "$(dirname "$0")/.."

# UNIVERSAL=1 builds one binary for both Apple Silicon and Intel Macs.
SWIFT_FLAGS=(-c release)
if [[ "${UNIVERSAL:-}" == "1" ]]; then SWIFT_FLAGS+=(--arch arm64 --arch x86_64); fi

swift build "${SWIFT_FLAGS[@]}"
BIN="$(swift build "${SWIFT_FLAGS[@]}" --show-bin-path)/Murmur"

APP="build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"

IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Murmur 2>/dev/null || true
    rm -rf /Applications/Murmur.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Murmur.app"
    open /Applications/Murmur.app
fi
