// The built-in Whisper on real audio, without the app: an audio file → pause segments → text per segment.
// Built and run by scripts/whisper-smoke.sh; not part of Bubbles.app.
import AVFoundation
import BubblesCore
import Foundation

@main struct WhisperSmoke {
    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: whisper-smoke <model.bin> <audio>…\n".utf8))
            exit(2)
        }
        let model = URL(fileURLWithPath: args.first!)
        let clock = ContinuousClock()
        let loading = clock.now
        try await WhisperEngine.shared.prepare(modelURL: model)
        print("model loaded in \(loading.duration(to: clock.now))")
        for path in args.dropFirst() {
            let samples = try read16kMono(URL(fileURLWithPath: path))
            var segmenter = PauseSegmenter()
            var segments = segmenter.append(samples)
            if let tail = segmenter.finish() { segments.append(tail) }
            print("\(URL(fileURLWithPath: path).lastPathComponent): \(segments.count) segments")
            for segment in segments {
                let started = clock.now
                let text = try await WhisperEngine.shared.transcribe(segment.samples)
                print(String(format: "  %5.2f–%5.2f s", segment.start, segment.end), "→", text,
                      "(\(started.duration(to: clock.now)))")
            }
        }
        // Metal asserts at exit if the model is still loaded; the same call the app makes when quitting.
        WhisperEngine.shared.shutdownNow()
    }

    /// Any file AVAudioFile reads, converted to 16 kHz mono Float32 like the microphone path.
    static func read16kMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
