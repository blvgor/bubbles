#!/bin/bash
# Checks the built-in Whisper on the real model, without the app and without the microphone:
# macOS `say` speaks a few neutral tasks in Russian (Milena) and English (Samantha) with pauses between
# them; the audio goes through the same pause segmenter and engine as the dictation and the text is printed.
#
#   scripts/whisper-smoke.sh            synthetic speech
#   scripts/whisper-smoke.sh file…      your own audio files
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/fetch-whisper.sh
scripts/direct-build.sh core
ROOT=$PWD
OUT="$ROOT/.build/direct"
FW="$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"
swiftc -swift-version 6 -target "$(uname -m)-apple-macosx26.0" -parse-as-library -O -module-name WhisperSmoke \
  -I "$OUT" -L "$OUT" -lBubblesCore -F "$FW" -framework whisper -Xlinker -rpath -Xlinker "$FW" \
  Sources/Bubbles/Dictation/WhisperEngine.swift scripts/whisper-smoke.swift -o "$OUT/whisper-smoke"

if [ $# -eq 0 ]; then
  WORK="${TMPDIR:-/tmp}/bubbles-whisper-smoke"
  mkdir -p "$WORK"
  say -v Milena -o "$WORK/ru.aiff" "Оплатить интернет до шестнадцати. [[slnc 1200]] Записаться к стоматологу на завтра. [[slnc 1200]] Продлить загранпаспорт. [[slnc 1200]] Готово."
  say -v Samantha -o "$WORK/en.aiff" "Send the invoice to the client by six. [[slnc 1200]] Call the dentist tomorrow morning. [[slnc 1200]] Buy milk and bread."
  say -v Milena -o "$WORK/mixed.aiff" "Отправить invoice клиенту до восемнадцати. [[slnc 1200]] Созвон в Zoom по проекту в три часа."
  set -- "$WORK/ru.aiff" "$WORK/en.aiff" "$WORK/mixed.aiff"
fi
"$OUT/whisper-smoke" "$ROOT/Vendor/Models/ggml-large-v3-turbo-q5_0.bin" "$@"
