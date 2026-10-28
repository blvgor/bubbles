import AVFoundation
import BubblesCore
import Foundation

/// The microphone for the phrase engines (built-in Whisper, ChatGPT cloud): input converted to 16 kHz mono
/// Float32 and cut at pauses by `PauseSegmenter`. Conversion and cutting run on the recorder's own queue,
/// not on the audio thread and not on the main thread.
final class SegmentRecorder: @unchecked Sendable {
    private let audio = AVAudioEngine()
    private let queue = DispatchQueue(label: "app.bubbles.segments", qos: .userInitiated)
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(PauseSegmenter.sampleRate),
                                       channels: 1, interleaved: false)!
    // Touched only on `queue`.
    private var segmenter = PauseSegmenter()
    private var converter: AVAudioConverter?
    private var running = false

    private let onSegment: @Sendable (AudioSegment) -> Void
    private let onLevel: @Sendable (Float) -> Void

    init(onSegment: @escaping @Sendable (AudioSegment) -> Void, onLevel: @escaping @Sendable (Float) -> Void) {
        self.onSegment = onSegment
        self.onLevel = onLevel
    }

    enum Failure: Error { case noInput }

    func start() throws {
        let input = audio.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw Failure.noInput }
        guard let converter = AVAudioConverter(from: natural, to: target) else { throw Failure.noInput }
        queue.sync {
            self.converter = converter
            self.segmenter = PauseSegmenter()
            self.running = true
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: natural) { [weak self] buffer, _ in
            // The tap's buffer is reused after the block returns: hand a copy to the queue.
            guard let self, let copy = Self.copy(buffer) else { return }
            let owned = OwnedBuffer(buffer: copy)
            self.queue.async { self.process(owned.buffer) }
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            queue.sync { self.running = false }
            throw error
        }
    }

    /// Stops the microphone and returns the phrase being spoken (it is not passed to `onSegment`).
    func stop() -> AudioSegment? {
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        return queue.sync {
            running = false
            converter = nil
            return segmenter.finish()
        }
    }

    // MARK: - Queue

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard running, let samples = convert(buffer), !samples.isEmpty else { return }
        onLevel(min(1, pow(10, PauseSegmenter.level(samples) / 20) * 8))
        for segment in segmenter.append(samples) { onSegment(segment) }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        // `.noDataNow` (not end of stream) keeps the resampler's state between buffers.
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let data = out.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let destination = copy.floatChannelData {
            let perChannel = buffer.format.isInterleaved ? frames * channels : frames
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                destination[channel].update(from: source[channel], count: perChannel)
            }
            return copy
        }
        if let source = buffer.int16ChannelData, let destination = copy.int16ChannelData {
            let perChannel = buffer.format.isInterleaved ? frames * channels : frames
            for channel in 0..<(buffer.format.isInterleaved ? 1 : channels) {
                destination[channel].update(from: source[channel], count: perChannel)
            }
            return copy
        }
        return nil
    }
}

/// A buffer copied off the tap: nothing else holds it, so it may cross to the recorder's queue.
private struct OwnedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}
