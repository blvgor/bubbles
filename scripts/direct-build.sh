#!/bin/bash
# Builds and tests the package with swiftc directly, without SwiftPM.
#
# Why: inside a restricted sandbox (e.g. an agent's Seatbelt profile) SwiftPM cannot write its build
# database, because Foundation's atomic writes go through /var/folders/…/T, which such sandboxes deny.
# swiftc itself writes next to its outputs, so the same sources build and the same Swift Testing suites
# run. Outside a sandbox use `make check` / `make app`, which go through SwiftPM.
#
# Usage: scripts/direct-build.sh core | test [--filter <Suite>] | app [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

ROOT=$PWD
OUT="$ROOT/.build/direct"
mkdir -p "$OUT"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT/.build/module-cache}"

DEV=$(xcode-select -p)
if [ -d "$DEV/Platforms/MacOSX.platform" ]; then
  FW="$DEV/Platforms/MacOSX.platform/Developer/Library/Frameworks"   # full Xcode
else
  FW="$DEV/Library/Developer/Frameworks"                              # Command Line Tools
fi
TESTLIB="$FW/../usr/lib"   # lib_TestingInterop.dylib, loaded by Testing.framework
PLUGINS="$DEV/usr/lib/swift/host/plugins/testing"
TARGET="$(uname -m)-apple-macosx26.0"
# whisper.cpp (scripts/fetch-whisper.sh): the macOS slice of the xcframework.
WHISPER_FW="$ROOT/Vendor/whisper.xcframework/macos-arm64_x86_64"
COMMON=(-swift-version 6 -target "$TARGET" -parse-as-library)

core() {
  local opt=${1:--Onone}
  swiftc "${COMMON[@]}" "$opt" -enable-testing -module-name BubblesCore \
    -emit-module -emit-module-path "$OUT/BubblesCore.swiftmodule" \
    -emit-library -static -o "$OUT/libBubblesCore.a" \
    Sources/BubblesCore/*.swift
}

test_() {
  core
  cat > "$OUT/TestMain.swift" <<'EOF'
import Testing
@main struct TestMain { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }
EOF
  swiftc "${COMMON[@]}" -Onone -module-name BubblesCoreTests \
    -I "$OUT" -L "$OUT" -lBubblesCore \
    -F "$FW" -framework Testing -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$TESTLIB" -plugin-path "$PLUGINS" \
    Tests/BubblesCoreTests/*.swift "$OUT/TestMain.swift" -o "$OUT/BubblesCoreTests"
  "$OUT/BubblesCoreTests" "$@"
}

app() {
  local opt=-Onone
  # rpath: Contents/Frameworks inside the .app; a debug build also finds the Vendor copy when run bare.
  local rpaths=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks -Xlinker -rpath -Xlinker "$WHISPER_FW")
  if [ "${1:-debug}" = release ]; then
    opt=-O
    rpaths=(-Xlinker -rpath -Xlinker @executable_path/../Frameworks)
  fi
  core "$opt"
  scripts/fetch-whisper.sh framework
  swiftc "${COMMON[@]}" "$opt" -module-name Bubbles -I "$OUT" -L "$OUT" -lBubblesCore \
    -F "$WHISPER_FW" -framework whisper "${rpaths[@]}" \
    Sources/Bubbles/*.swift $(find Sources/Bubbles -mindepth 2 -name '*.swift') -o "$OUT/Bubbles"
  echo "$OUT/Bubbles"
}

cmd=${1:-test}; shift || true
case "$cmd" in
  core) core ;;
  test) test_ "$@" ;;
  app) app "$@" ;;
  *) echo "usage: $0 core | test [--filter <Suite>] | app [debug|release]" >&2; exit 2 ;;
esac
