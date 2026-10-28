import BubblesCore
import Foundation
import whisper

/// The built-in Whisper (whisper.cpp, linked from `Vendor/whisper.xcframework`). The model is loaded once,
/// on the first dictation, and kept; every call runs on the engine's own serial queue, never on the main
/// thread. Language is detected per segment (Russian, English and mixed phrases).
///
/// Only Foundation and whisper here: `scripts/whisper-smoke.sh` compiles this file into a small tool that
/// checks the real model on synthetic speech.
actor WhisperEngine {
    static let shared = WhisperEngine()

    enum Failure: Error, Equatable {
        /// No model file in the app or in Application Support.
        case noModel
        /// whisper.cpp could not read the model file.
        case loadFailed
        case transcriptionFailed
    }

    private let queue = DispatchSerialQueue(label: "app.bubbles.whisper", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var context: OpaquePointer?
    private var loadedPath: String?
    private var unloadTask: Task<Void, Never>?

    /// Loads the model if another one (or none) is loaded. Takes a second or two the first time.
    func prepare(modelURL: URL) throws {
        unloadTask?.cancel()
        unloadTask = nil
        if context != nil, loadedPath == modelURL.path { return }
        unload()
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw Failure.noModel }
        Self.silenceLogs()
        var params = whisper_context_default_params()
        params.use_gpu = true
        params.flash_attn = true
        guard let loaded = whisper_init_from_file_with_params(modelURL.path, params) else { throw Failure.loadFailed }
        context = loaded
        loadedPath = modelURL.path
    }

    var isLoaded: Bool { context != nil }

    /// One segment of 16 kHz mono Float32 audio → its text (trimmed; empty when nothing was said).
    func transcribe(_ samples: [Float]) throws -> String {
        guard let context else { throw Failure.noModel }
        let audio = PauseSegmenter.paddedForWhisper(samples)
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.no_timestamps = true
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        let status: Int32 = "auto".withCString { language in
            params.language = language
            params.detect_language = false
            return audio.withUnsafeBufferPointer { buffer in
                whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
            }
        }
        guard status == 0 else { throw Failure.transcriptionFailed }
        var parts: [String] = []
        for i in 0..<whisper_full_n_segments(context) {
            // A segment Whisper itself thinks is silence is dropped (its usual "To be continued…").
            if whisper_full_get_segment_no_speech_prob(context, i) > 0.8 { continue }
            if let text = whisper_full_get_segment_text(context, i) { parts.append(String(cString: text)) }
        }
        return WhisperText.clean(parts.joined(separator: " ")) ?? ""
    }

    /// Frees the model's memory after `delay` without dictation; a new `prepare` cancels it.
    func unload(after delay: Duration) {
        unloadTask?.cancel()
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    func unload() {
        if let context { whisper_free(context) }
        context = nil
        loadedPath = nil
    }

    /// The app is quitting: frees the model right now, waiting for a running segment. ggml's Metal backend
    /// aborts at exit if a model is still loaded, which would leave a crash report on every quit.
    nonisolated func shutdownNow() {
        queue.sync { self.assumeIsolated { $0.unload() } }
    }

    /// whisper.cpp and ggml print every loading step to stderr.
    private static func silenceLogs() {
        whisper_log_set({ _, _, _ in }, nil)
    }
}
