#!/bin/bash
# Downloads the built-in speech engine into Vendor/ (not in git), once:
#   Vendor/whisper.xcframework                       whisper.cpp, official prebuilt release (MIT)
#   Vendor/Models/ggml-large-v3-turbo-q5_0.bin       Whisper large-v3-turbo, q5_0 (MIT)
# Every file is checked against the SHA-256 pinned below; a second run downloads nothing.
#
# Usage: scripts/fetch-whisper.sh [framework|model|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

# whisper.cpp build b5454 = the v1.9.5 tag (2026-10-06), https://github.com/ggml-org/whisper.cpp/releases/tag/b5454
WHISPER_BUILD=b5454
FRAMEWORK_URL="https://github.com/ggml-org/whisper.cpp/releases/download/$WHISPER_BUILD/whisper-$WHISPER_BUILD-xcframework.zip"
FRAMEWORK_SHA256=e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b

# https://huggingface.co/ggerganov/whisper.cpp — 574 041 195 bytes
MODEL_NAME=ggml-large-v3-turbo-q5_0.bin
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$MODEL_NAME"
MODEL_SHA256=394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2

VENDOR=Vendor
CACHE="$VENDOR/.download"
mkdir -p "$CACHE"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

# download <url> <file> <sha256>: keeps an already verified file, otherwise downloads to a temp name,
# checks the checksum and only then renames it into place.
download() {
  local url=$1 file=$2 sum=$3
  if [ -f "$file" ] && [ "$(sha256 "$file")" = "$sum" ]; then return 0; fi
  echo "Downloading $(basename "$file")…" >&2
  rm -f "$file.part"
  curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
  local got
  got=$(sha256 "$file.part")
  if [ "$got" != "$sum" ]; then
    rm -f "$file.part"
    echo "error: checksum mismatch for $(basename "$file"): got $got, expected $sum" >&2
    return 1
  fi
  mv "$file.part" "$file"
}

framework() {
  local stamp="$VENDOR/whisper.xcframework/.sha256"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$FRAMEWORK_SHA256" ]; then return 0; fi
  local zip="$CACHE/whisper-$WHISPER_BUILD-xcframework.zip"
  download "$FRAMEWORK_URL" "$zip" "$FRAMEWORK_SHA256"
  local tmp="$CACHE/unzip"
  rm -rf "$tmp"
  mkdir -p "$tmp"
  unzip -q "$zip" -d "$tmp"
  rm -rf "$VENDOR/whisper.xcframework"
  mv "$tmp/build-apple/whisper.xcframework" "$VENDOR/whisper.xcframework"
  rm -rf "$tmp"
  echo "$FRAMEWORK_SHA256" > "$stamp"
  echo "whisper.xcframework ($WHISPER_BUILD) is in $VENDOR/" >&2
}

model() {
  local file="$VENDOR/Models/$MODEL_NAME"
  local stamp="$file.sha256"
  # Hashing 550 MB takes a few seconds: the stamp remembers a verified file of this size.
  if [ -f "$file" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$MODEL_SHA256 $(stat -f %z "$file")" ]; then return 0; fi
  mkdir -p "$VENDOR/Models"
  download "$MODEL_URL" "$file" "$MODEL_SHA256"
  echo "$MODEL_SHA256 $(stat -f %z "$file")" > "$stamp"
  echo "$MODEL_NAME is in $VENDOR/Models/" >&2
}

case "${1:-all}" in
  framework) framework ;;
  model) model ;;
  all) framework; model ;;
  *) echo "usage: $0 [framework|model|all]" >&2; exit 2 ;;
esac
