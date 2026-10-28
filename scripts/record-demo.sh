#!/bin/bash
# Records the desk — wallpaper + Bubbles windows only, no other app — to docs/demo.mp4.
#
#   scripts/record-demo.sh [seconds]      default 15
#
# Start Bubbles first (make run), then run this and use the app. The terminal needs «Screen Recording»
# in System Settings → Privacy & Security. Other windows, the menu bar and the Dock are not recorded:
# the capture filter lists only the wallpaper and Bubbles' own windows.
set -euo pipefail
cd "$(dirname "$0")/.."

SECONDS_TO_RECORD=${1:-15}
OUT="docs/demo.mp4"
mkdir -p docs

TOOL_DIR=$(mktemp -d)
trap 'rm -rf "$TOOL_DIR"' EXIT
cat > "$TOOL_DIR/record.swift" <<'SWIFT'
import AVFoundation
import AppKit
import ScreenCaptureKit

_ = NSApplication.shared
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let seconds = Double(CommandLine.arguments[2]) ?? 15

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}

let done = DispatchSemaphore(value: 0)
Task {
    defer { done.signal() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { print("no display"); return }
        let wallpaper = content.windows.filter { $0.owningApplication?.applicationName == "WindowManager" && $0.title == "Wallpaper" }
        let mine = content.windows.filter { $0.owningApplication?.applicationName == "Bubbles" }
        guard !wallpaper.isEmpty, !mine.isEmpty else { print("Bubbles is not running or the wallpaper window is not visible"); return }
        // New windows (the menu, panels) appear after the stream starts and are not in this list: open the
        // ones you want in the video before recording, or keep to the desk and the always-present overlays.
        let filter = SCContentFilter(display: display, including: wallpaper + mine)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width * 2
        configuration.height = display.height * 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.showsCursor = false
        let recorder = try Recorder(url: out, width: configuration.width, height: configuration.height)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "record"))
        try await stream.startCapture()
        print("recording \(Int(seconds)) s to \(out.path)")
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        recorder.input.markAsFinished()
        await recorder.writer.finishWriting()
        print("saved \(out.path)")
    } catch {
        print("recording failed: \(error)")
    }
}
done.wait()
SWIFT
swiftc -O -o "$TOOL_DIR/record" "$TOOL_DIR/record.swift"
"$TOOL_DIR/record" "$OUT" "$SECONDS_TO_RECORD"
echo "Open $OUT and check that nothing but Bubbles is in the frame before committing it."
