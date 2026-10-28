import AVFoundation
import BubblesCore
import Combine
import Speech

/// Live speech-to-text for the dictation, as lines (one future task per line).
///
/// Phrase engines (F7), when the panel asks for them (`preferred`):
/// - `.whisper`: the built-in Whisper (`WhisperEngine`) — the microphone is cut at pauses (`SegmentRecorder`,
///   `PauseSegmenter`) and every phrase is recognised in the background and becomes a line; Russian and
///   English, no internet, only the microphone permission;
/// - `.openAI`: the same phrases sent to ChatGPT (`OpenAITranscriber`) with the person's key; on an error the
///   built-in Whisper takes over for the rest of the dictation and `onNotice` says why.
/// Without the Whisper model these fall back to the macOS recognizer below.
///
/// macOS engine, chosen per session (ru-RU):
/// 1. `SpeechAnalyzer` + `SpeechTranscriber` when its installed models cover ru-RU;
/// 2. `SpeechAnalyzer` + `DictationTranscriber` (the same new engine with the Dictation models, which do cover
///    ru-RU on macOS 26+) when installed;
/// 3. otherwise `SFSpeechRecognizer`, restarted after every final result, with its hypotheses accumulated
///    so a fragment restarted after a pause never overwrites what was said before.
/// If the new engine supports ru-RU but its model is not installed yet, the download starts in the background
/// and this session uses (3).
///
/// Line splitting and voice commands live in `BubblesCore.Transcript`. Permissions are asked on the first
/// `start()`. When voice cannot work it reports why through `onFailure` and the panel switches to typing.
@MainActor final class SpeechRecognizer: ObservableObject {
    enum State: Equatable {
        case idle, requesting, listening
        /// Voice is not possible; the text is the one-line hint shown in text mode.
        case unavailable(String)
    }

    enum Engine: Equatable {
        /// Phrases cut at pauses, recognised by the built-in Whisper / by ChatGPT.
        case whisper, cloud
        case speechTranscriber, dictationTranscriber
        /// `SFSpeechRecognizer`; the text says why the new engine is not used.
        case legacy(String)
    }

    /// Everything heard so far, final and volatile, one line per future task.
    @Published private(set) var lines: [String] = []
    /// Input loudness 0…1 for the wave.
    @Published private(set) var level: Float = 0
    @Published private(set) var state: State = .idle
    @Published private(set) var engine: Engine?
    /// When the current session started listening (for the panel's timer).
    @Published private(set) var startedAt: Date?
    /// Set when recognition broke off after some speech: "Recognition stopped at 01:32". Lines are kept.
    @Published private(set) var interruption: String?

    /// Lines joined by newlines.
    var transcript: String { lines.joined(separator: "\n") }

    /// Called once when voice turns out to be impossible, with the hint for text mode.
    var onFailure: ((String) -> Void)?
    /// "done" was said.
    var onFinishCommand: (() -> Void)?
    /// A one-line notice for the panel's hint (the cloud failed and Whisper took over, no model…).
    var onNotice: ((String) -> Void)?

    /// The engine the panel wants (`SpeechEngine.effective`); set before `start`.
    var preferred: SpeechEngine = .system
    /// ChatGPT's transcription model for `.openAI`.
    var cloudModel = OpenAITranscriber.defaultModel
    /// Phrases recorded but not recognised yet (queued or being recognised).
    @Published private(set) var pendingSegments = 0

    private var model = Transcript()
    /// Bumped on every start/stop so late callbacks from a previous session are ignored.
    private var session = 0

    private var audio: AVAudioEngine?
    private var sink: AudioSink?
    // New engine
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    // Legacy engine
    private var recognizer: SFSpeechRecognizer?
    private var legacyTask: SFSpeechRecognitionTask?
    private var legacyHypothesis: [SpokenWord] = []
    private var legacyOffset: TimeInterval = 0
    private var legacyRestarts = 0
    // Phrase engines
    private var recorder: SegmentRecorder?
    private var segmentQueue: [QueuedSegment] = []
    private var segmentWorker: Task<Void, Never>?
    /// Bumped when the lines start over, so phrases of an abandoned transcript are dropped.
    private var transcriptGeneration = 0
    private var cloud: OpenAITranscriber?
    private var cloudFailed = false
    private var modelURL: URL?
    /// The last phrase written: a phrase that starts right where it ended (a monologue cut at 25 s) continues
    /// its line; any other starts a new one.
    private var lastPhrase: (session: Int, end: TimeInterval)?

    static let speechDeniedHint = "No access to speech recognition. Turn it on in System Settings → Privacy & Security → Speech Recognition"
    static let micDeniedHint = "No access to the microphone. Turn it on in System Settings → Privacy & Security → Microphone"
    static let unavailableHint = "Russian speech recognition isn't available right now — type instead"
    static let noInputHint = "No microphone found — type instead"
    static let whisperFailedHint = "The built-in Whisper didn't start — type instead or choose macOS in Settings"
    static let noModelNotice = "No Whisper model — macOS is recognizing. Download it in Settings → Dictation & AI"
    static let russian = Locale(identifier: "ru-RU")

    /// Replaces the lines (restored draft, hand edits). Does not touch a running session's audio.
    func setLines(_ lines: [String]) {
        model.replaceLines(lines)
        publish()
    }

    /// `continuing`: keep the lines heard before (new speech starts a new line); otherwise start empty.
    func start(continuing: Bool = false) async {
        stop()
        if continuing {
            model.beginSession()
        } else {
            model = Transcript()
            discardPendingSegments()
        }
        publish()
        interruption = nil
        session += 1
        let current = session

        if preferred == .whisper || preferred == .openAI {
            modelURL = WhisperModelStore.modelURL
            let key = preferred == .openAI ? await Self.openAIKey() : nil
            guard current == session else { return }
            cloud = key.map { OpenAITranscriber(apiKey: $0, model: cloudModel) }
            cloudFailed = false
            if cloud != nil || modelURL != nil { return await startPhrases(session: current) }
            onNotice?(Self.noModelNotice)
        }

        // Without the usage strings (bare binary outside the .app) macOS would kill the app on the request.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["NSSpeechRecognitionUsageDescription"] != nil, info["NSMicrophoneUsageDescription"] != nil else {
            return fail(Self.unavailableHint)
        }

        state = .requesting
        let speechStatus = await Self.speechAuthorization()
        guard current == session else { return }
        guard speechStatus == .authorized else { return fail(Self.speechDeniedHint) }

        let micGranted = await Self.microphoneAccess()
        guard current == session else { return }
        guard micGranted else { return fail(Self.micDeniedHint) }

        let choice = await Self.chooseEngine()
        guard current == session else { return }
        do {
            switch choice {
            case .speechTranscriber(let locale):
                try await startAnalyzer(module: .speech(SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                                         reportingOptions: [.volatileResults],
                                                                         attributeOptions: [.audioTimeRange])),
                                        session: current)
                engine = .speechTranscriber
            case .dictationTranscriber(let locale):
                try await startAnalyzer(module: .dictation(DictationTranscriber(locale: locale, contentHints: [],
                                                                               transcriptionOptions: [.punctuation],
                                                                               reportingOptions: [.volatileResults, .frequentFinalization],
                                                                               attributeOptions: [.audioTimeRange])),
                                        session: current)
                engine = .dictationTranscriber
            case .legacy(let reason):
                try startLegacy(session: current)
                engine = .legacy(reason)
            }
            guard current == session else { return }
            startedAt = Date()
            state = .listening
        } catch PipelineError.unavailable {
            fail(Self.unavailableHint)
        } catch {
            // The new engine failed to start (model busy, format): one more try with the legacy recognizer.
            if case .legacy = choice { return fail(Self.noInputHint) }
            teardown()
            do {
                try startLegacy(session: current)
                engine = .legacy("SpeechAnalyzer didn't start: \(error.localizedDescription)")
                startedAt = Date()
                state = .listening
            } catch {
                fail(Self.noInputHint)
            }
        }
    }

    /// Stops listening and keeps everything heard, including the not yet finalised tail (a phrase engine
    /// still recognises the last phrase: `waitForPendingSegments`).
    func stop() {
        let ending = session
        session += 1
        if let recorder {
            self.recorder = nil
            if let tail = recorder.stop() { enqueue(tail, session: ending) }
        }
        model.commitVolatile()
        publish()
        teardown()
        level = 0
        if state == .listening || state == .requesting { state = .idle }
    }

    private func teardown() {
        if let recorder { _ = recorder.stop() }
        recorder = nil
        if let audio {
            audio.stop()
            audio.inputNode.removeTap(onBus: 0)
        }
        sink?.finish()
        audio = nil
        sink = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        legacyTask?.cancel()
        legacyTask = nil
        recognizer = nil
        legacyHypothesis = []
    }

    private func fail(_ hint: String) {
        stop()
        state = .unavailable(hint)
        onFailure?(hint)
    }

    /// Recognition broke after speech: keep the lines, stop, say where it broke.
    private func interrupt() {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        stop()
        let seconds = Int(elapsed)
        interruption = String(format: "Recognition stopped at %02d:%02d", seconds / 60, seconds % 60)
    }

    private func publish() {
        let next = model.lines
        if next != lines { lines = next }
    }

    private func handle(_ commands: [TranscriptCommand]) {
        publish()
        if commands.contains(.finish) { onFinishCommand?() }
    }

    // MARK: - Phrase engines (built-in Whisper, ChatGPT cloud)

    private struct QueuedSegment {
        let segment: AudioSegment
        let session: Int
        let generation: Int
    }

    /// Waits until every recorded phrase is recognised (or dropped).
    func waitForPendingSegments() async {
        while let worker = segmentWorker { await worker.value }
    }

    /// The panel closed: phrases still queued are not needed any more.
    func discardPendingSegments() {
        transcriptGeneration += 1
        segmentQueue = []
        lastPhrase = nil
        pendingSegments = segmentWorker == nil ? 0 : 1
    }

    private func startPhrases(session current: Int) async {
        // Without the usage string (bare binary outside the .app) macOS would kill the app on the request.
        guard Bundle.main.infoDictionary?["NSMicrophoneUsageDescription"] != nil else { return fail(Self.unavailableHint) }
        state = .requesting
        let micGranted = await Self.microphoneAccess()
        guard current == session else { return }
        guard micGranted else { return fail(Self.micDeniedHint) }

        // The model loads while the person starts talking (a second or two, once).
        if cloud == nil, let modelURL {
            Task.detached(priority: .userInitiated) { try? await WhisperEngine.shared.prepare(modelURL: modelURL) }
        }
        let recorder = SegmentRecorder(
            onSegment: { [weak self] segment in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.enqueue(segment, session: current) } }
            },
            onLevel: levelHandler(session: current))
        do {
            try recorder.start()
        } catch {
            return fail(Self.noInputHint)
        }
        self.recorder = recorder
        engine = cloud == nil ? .whisper : .cloud
        startedAt = Date()
        state = .listening
    }

    private func enqueue(_ segment: AudioSegment, session owner: Int) {
        segmentQueue.append(QueuedSegment(segment: segment, session: owner, generation: transcriptGeneration))
        pendingSegments = segmentQueue.count + (segmentWorker == nil ? 0 : 1)
        guard segmentWorker == nil else { return }
        segmentWorker = Task { [weak self] in await self?.drainSegments() }
    }

    /// One phrase at a time, in the order spoken.
    private func drainSegments() async {
        while !segmentQueue.isEmpty {
            let item = segmentQueue.removeFirst()
            pendingSegments = segmentQueue.count + 1
            guard item.generation == transcriptGeneration else { continue }
            let text = await recognize(item.segment)
            guard item.generation == transcriptGeneration, let text, !text.isEmpty else { continue }
            write(text, of: item)
        }
        segmentWorker = nil
        pendingSegments = 0
        // Not dictating: the model's memory is freed after ten idle minutes.
        if recorder == nil { Task { await WhisperEngine.shared.unload(after: .seconds(600)) } }
    }

    private func recognize(_ segment: AudioSegment) async -> String? {
        if let cloud, !cloudFailed {
            do {
                return WhisperText.clean(try await cloud.transcribe(segment.samples)) ?? ""
            } catch {
                cloudFailed = true
                let failure = ClaudeFailure.classify(error)
                guard modelURL != nil else {
                    onNotice?(failure.message(for: .openAI).replacingOccurrences(of: "kept the lines as written",
                                                                                with: "what you dictated is saved"))
                    stopAfterFailure()
                    return nil
                }
                onNotice?(SpeechCloudFailure.message(failure))
            }
        }
        guard let modelURL else { return nil }
        do {
            try await WhisperEngine.shared.prepare(modelURL: modelURL)
            return try await WhisperEngine.shared.transcribe(segment.samples)
        } catch {
            stopAfterFailure()
            return nil
        }
    }

    /// The phrase engine broke: with nothing heard yet, to typing; otherwise keep the lines and say where.
    private func stopAfterFailure() {
        if lines.isEmpty { fail(Self.whisperFailedHint) } else if state == .listening { interrupt() }
        discardPendingSegments()   // after the stop above, which queued the last phrase
    }

    private func write(_ text: String, of item: QueuedSegment) {
        guard !model.isFinished else { return }
        let continues = lastPhrase.map { $0.session == item.session && item.segment.start - $0.end < 0.1 } ?? false
        if !continues { model.beginSession() }   // closes the line being spoken
        lastPhrase = (item.session, item.segment.end)
        handle(model.commit(SpeechSegmentText.words(text, start: item.segment.start, end: item.segment.end)))
    }

    /// ChatGPT's key from the Keychain, read off the main thread.
    nonisolated private static func openAIKey() async -> String? {
        await Task.detached { APIKeyStore.load(.openAI) }.value
    }

    // MARK: - New engine (SpeechAnalyzer)

    private enum Module: Sendable {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)
        var any: any SpeechModule {
            switch self {
            case .speech(let m): m
            case .dictation(let m): m
            }
        }
    }

    private func startAnalyzer(module: Module, session current: Int) async throws {
        let audio = AVAudioEngine()
        let input = audio.inputNode
        let natural = input.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw PipelineError.noInput }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module.any], considering: natural) else {
            throw PipelineError.unavailable
        }
        let analyzer = SpeechAnalyzer(modules: [module.any])
        try await analyzer.prepareToAnalyze(in: format)
        guard current == session else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AudioSink(analyzerInput: continuation, from: natural, to: format)
        try Self.startAudio(audio, sink: sink, onLevel: levelHandler(session: current))
        // Owned from here on, so a stop() during the awaits below tears everything down.
        self.audio = audio
        self.sink = sink
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
        guard current == session else { return }

        let deliver: @Sendable ([SpokenWord], Bool) -> Void = { [weak self] words, isFinal in
            Task { @MainActor in self?.receiveAnalyzer(words, isFinal: isFinal, session: current) }
        }
        let failed: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.analyzerFailed(session: current) }
        }
        resultsTask = Task.detached {
            do {
                switch module {
                case .speech(let m):
                    for try await r in m.results { deliver(Self.words(from: r.text), r.isFinal) }
                case .dictation(let m):
                    for try await r in m.results { deliver(Self.words(from: r.text), r.isFinal) }
                }
            } catch {
                if !Task.isCancelled { failed() }
            }
        }
    }

    private func receiveAnalyzer(_ words: [SpokenWord], isFinal: Bool, session current: Int) {
        guard current == session else { return }
        if isFinal {
            handle(model.commit(words))
        } else {
            model.update(volatile: words)
            publish()
        }
    }

    private func analyzerFailed(session current: Int) {
        guard current == session else { return }
        if lines.isEmpty { fail(Self.unavailableHint) } else { interrupt() }
    }

    /// Word timings from the transcriber's `audioTimeRange` attribute runs.
    nonisolated private static func words(from text: AttributedString) -> [SpokenWord] {
        var out: [SpokenWord] = []
        for run in text.runs {
            let chunk = String(text[run.range].characters)
            let tokens = chunk.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let start: TimeInterval
            let end: TimeInterval
            if let range = run.audioTimeRange {
                start = range.start.seconds
                end = range.end.seconds
            } else {
                start = out.last?.end ?? 0
                end = start
            }
            for token in tokens { out.append(SpokenWord(token, start: start, end: end)) }
        }
        return out
    }

    // MARK: - Legacy engine (SFSpeechRecognizer), restarted after each final result

    private func startLegacy(session current: Int) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Self.russian), recognizer.isAvailable else {
            throw PipelineError.unavailable
        }
        let audio = AVAudioEngine()
        let natural = audio.inputNode.outputFormat(forBus: 0)
        guard natural.sampleRate > 0, natural.channelCount > 0 else { throw PipelineError.noInput }
        let sink = AudioSink(sampleRate: natural.sampleRate)
        try Self.startAudio(audio, sink: sink, onLevel: levelHandler(session: current))
        self.recognizer = recognizer
        self.audio = audio
        self.sink = sink
        legacyRestarts = 0
        startLegacyTask(session: current)
    }

    /// A new recognition request continuing the same audio; its timestamps are shifted to session time.
    private func startLegacyTask(session current: Int) {
        guard let recognizer, let sink else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        legacyOffset = sink.switchRequest(to: request)
        legacyHypothesis = []
        let onResult: @Sendable ([LegacySegment], Bool, Bool) -> Void = { [weak self] segments, isFinal, failed in
            Task { @MainActor in self?.receiveLegacy(segments, isFinal: isFinal, failed: failed, session: current) }
        }
        legacyTask = recognizer.recognitionTask(with: request) { result, error in
            let segments = result?.bestTranscription.segments.map {
                LegacySegment(text: $0.substring, start: $0.timestamp, duration: $0.duration)
            } ?? []
            onResult(segments, result?.isFinal ?? false, error != nil)
        }
    }

    private func receiveLegacy(_ segments: [LegacySegment], isFinal: Bool, failed: Bool, session current: Int) {
        guard current == session else { return }
        if !segments.isEmpty {
            let words: [SpokenWord]
            if segments.contains(where: { $0.start > 0 || $0.duration > 0 }) {
                words = segments.map { SpokenWord($0.text, start: $0.start + legacyOffset, end: $0.start + $0.duration + legacyOffset) }
            } else {
                // Partial results without timings: time of arrival stands in for when a word was said.
                let now = startedAt.map { Date().timeIntervalSince($0) } ?? legacyOffset
                words = SpokenWord.stamped(segments.map(\.text), previous: legacyHypothesis, now: now)
            }
            legacyHypothesis = words
            handle(model.receiveHypothesis(words, isFinal: isFinal || failed))
            guard current == session, state == .listening else { return }
        }
        guard isFinal || failed else { return }
        // The task is over (final result, end of an utterance, or the per-request time limit): continue
        // with a fresh request on the same audio. Repeated failures without any speech mean voice is broken.
        if failed && segments.isEmpty {
            legacyRestarts += 1
            if legacyRestarts > 3 {
                return lines.isEmpty ? fail(Self.unavailableHint) : interrupt()
            }
        } else {
            legacyRestarts = 0
        }
        legacyTask?.cancel()
        startLegacyTask(session: current)
    }

    private struct LegacySegment: Sendable {
        let text: String
        let start: TimeInterval
        let duration: TimeInterval
    }

    // MARK: - Engine choice

    private enum EngineChoice {
        case speechTranscriber(Locale), dictationTranscriber(Locale), legacy(String)
    }

    nonisolated private static func chooseEngine() async -> EngineChoice {
        func covers(_ installed: [Locale], _ locale: Locale) -> Bool {
            installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
        }
        if SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: russian) {
            if covers(await SpeechTranscriber.installedLocales, locale) { return .speechTranscriber(locale) }
            downloadInBackground(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        }
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: russian) {
            if covers(await DictationTranscriber.installedLocales, locale) { return .dictationTranscriber(locale) }
            downloadInBackground(DictationTranscriber(locale: locale, preset: .progressiveLongDictation))
            return .legacy("the SpeechAnalyzer model for ru-RU is still downloading")
        }
        return .legacy("SpeechAnalyzer doesn't support ru-RU on this Mac")
    }

    /// Next session will find the model installed; this one goes on with the legacy recognizer.
    nonisolated private static func downloadInBackground(_ module: any SpeechModule) {
        Task.detached(priority: .utility) {
            try? await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
        }
    }

    // MARK: - Audio

    private enum PipelineError: Error { case noInput, unavailable }

    private func levelHandler(session current: Int) -> @Sendable (Float) -> Void {
        { [weak self] value in
            Task { @MainActor in
                guard let self, self.session == current else { return }
                self.level = value
            }
        }
    }

    /// Built outside the main actor's isolation: the tap block runs on the audio thread.
    nonisolated private static func startAudio(_ audio: AVAudioEngine, sink: AudioSink,
                                               onLevel: @escaping @Sendable (Float) -> Void) throws {
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
            onLevel(rms(buffer))
        }
        audio.prepare()
        do {
            try audio.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return min(1, (sum / Float(n)).squareRoot() * 8)
    }

    nonisolated private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    nonisolated private static func microphoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Where the microphone tap sends audio, from the audio thread: either the analyzer's input stream
/// (converted to its format) or the current legacy recognition request, which can be swapped mid-stream.
private final class AudioSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var frames: AVAudioFramePosition = 0
    private let sampleRate: Double
    private let analyzerInput: AsyncStream<AnalyzerInput>.Continuation?
    private let converter: AVAudioConverter?
    private let outputFormat: AVAudioFormat?

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        analyzerInput = nil
        converter = nil
        outputFormat = nil
    }

    init(analyzerInput: AsyncStream<AnalyzerInput>.Continuation, from input: AVAudioFormat, to output: AVAudioFormat) {
        sampleRate = input.sampleRate
        self.analyzerInput = analyzerInput
        outputFormat = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if let analyzerInput {
            if let converted = convert(buffer) { analyzerInput.yield(AnalyzerInput(buffer: converted)) }
            return
        }
        lock.lock()
        request?.append(buffer)
        frames += AVAudioFramePosition(buffer.frameLength)
        lock.unlock()
    }

    /// Ends the current legacy request and routes audio to `next`. Returns the session time (seconds of audio
    /// so far) at which `next` starts, to shift its timestamps.
    func switchRequest(to next: SFSpeechAudioBufferRecognitionRequest?) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        request?.endAudio()
        request = next
        return sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    func finish() {
        analyzerInput?.finish()
        _ = switchRequest(to: nil)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let outputFormat else { return buffer }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
