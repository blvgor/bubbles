#!/bin/bash
# Packages the release build into build/Bubbles.app with Info.plist and an ad-hoc signature.
# Needs only the Command Line Tools. DIRECT=1 compiles with swiftc instead of SwiftPM
# (for restricted sandboxes, see scripts/direct-build.sh).
# The built-in Whisper goes in too: whisper.framework → Contents/Frameworks, the model →
# Contents/Resources/Models (both from Vendor/, downloaded once by scripts/fetch-whisper.sh).
# WHISPER_MODEL=0 builds without the model: the app then offers a "Download model" button in its settings.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/fetch-whisper.sh framework
MODEL="Vendor/Models/ggml-large-v3-turbo-q5_0.bin"
if [ "${WHISPER_MODEL:-1}" != 0 ]; then
  scripts/fetch-whisper.sh model || echo "warning: no Whisper model in this build (download failed) — the app will offer to download it" >&2
fi

APP=build/Bubbles.app
if [ "${DIRECT:-0}" = 1 ]; then
  BIN=$(scripts/direct-build.sh app release | tail -1)
else
  swift build -c release --product Bubbles ${SWIFTPM_FLAGS:-}
  BIN="$(swift build -c release --show-bin-path ${SWIFTPM_FLAGS:-})/Bubbles"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Bubbles"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"   # whisper.cpp + Whisper model
printf 'APPL????' > "$APP/Contents/PkgInfo"

# whisper.framework, only this Mac's architecture (the release ships arm64 and x86_64).
FW="$APP/Contents/Frameworks/whisper.framework"
cp -R Vendor/whisper.xcframework/macos-arm64_x86_64/whisper.framework "$FW"
lipo "$FW/Versions/A/whisper" -thin "$(uname -m)" -output "$FW/Versions/A/whisper.thin"
mv "$FW/Versions/A/whisper.thin" "$FW/Versions/A/whisper"
codesign --force --sign - --timestamp=none "$FW"

if [ "${WHISPER_MODEL:-1}" != 0 ] && [ -f "$MODEL" ]; then
  mkdir -p "$APP/Contents/Resources/Models"
  cp "$MODEL" "$APP/Contents/Resources/Models/"
fi
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"
