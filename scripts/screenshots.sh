#!/bin/bash
# Screenshots of Bubbles only: the wallpaper window plus Bubbles' own windows. Nothing else on your
# screen (other apps, the menu bar, the Dock) is in the frame.
#
#   scripts/screenshots.sh desk [name]      the desk: wallpaper + bubbles + whatever Bubbles windows are open
#   scripts/screenshots.sh window [name] [n]  one Bubbles window (menu, settings, dictation…) with its own corners
#
# Open the screen you want first (the menu bar icon, Settings…, ⌥Space), then run the command. Files go to
# docs/screenshots/<name>.png. The terminal needs «Screen Recording» in System Settings → Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-desk}
NAME=${2:-$MODE}
INDEX=${3:-0}
OUT="docs/screenshots/$NAME.png"
mkdir -p docs/screenshots

TOOL_DIR=$(mktemp -d)
trap 'rm -rf "$TOOL_DIR"' EXIT
cat > "$TOOL_DIR/shot.swift" <<'SWIFT'
import AppKit
import ScreenCaptureKit

_ = NSApplication.shared
let args = CommandLine.arguments
let mode = args[1], out = args[2]
let index = args.count > 3 ? Int(args[3]) ?? 0 : 0

func save(_ image: CGImage) {
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
    print("saved \(out) \(image.width)x\(image.height)")
}

let done = DispatchSemaphore(value: 0)
Task {
    defer { done.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { print("no display"); return }
        let mine = content.windows.filter { $0.owningApplication?.applicationName == "Bubbles" }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        if mode == "desk" {
            let wallpaper = content.windows.filter { $0.owningApplication?.applicationName == "WindowManager" && $0.title == "Wallpaper" }
            guard !wallpaper.isEmpty, !mine.isEmpty else { print("Bubbles is not running or the wallpaper window is not visible"); return }
            // Only these windows are in the filter, so other apps never reach the picture.
            let filter = SCContentFilter(display: display, including: wallpaper + mine)
            configuration.width = display.width * 2
            configuration.height = display.height * 2
            save(try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
        } else {
            let panels = mine.filter { $0.frame.width < display.frame.width - 50 && $0.frame.width > 40 }
            guard index < panels.count else { print("no Bubbles window #\(index); open windows: \(panels.count)"); return }
            let panel = panels[index]
            configuration.width = Int(panel.frame.width * 2)
            configuration.height = Int(panel.frame.height * 2)
            configuration.shouldBeOpaque = false
            save(try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: panel), configuration: configuration))
        }
    } catch {
        print("capture failed: \(error)")
    }
}
done.wait()
SWIFT
swiftc -O -o "$TOOL_DIR/shot" "$TOOL_DIR/shot.swift"
"$TOOL_DIR/shot" "$MODE" "$OUT" "$INDEX"
echo "Open $OUT and check that nothing but Bubbles is in the frame before committing it."
