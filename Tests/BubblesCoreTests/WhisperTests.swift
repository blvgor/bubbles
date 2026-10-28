import Foundation
import Testing
import BubblesCore

/// F7: the built-in Whisper and the cloud transcription — cutting the microphone audio at pauses, the
/// engine setting, segment text → transcript lines, the ChatGPT `audio/transcriptions` request, the model file.
@Suite struct WhisperTests {
    static let rate = 16_000

    /// A loud tone of `seconds` (speech stand-in, about −13 dBFS).
    static func speech(_ seconds: Double, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(rate)) }
    }

    /// Quiet noise of `seconds` at about `amplitude` (room tone).
    static func quiet(_ seconds: Double, amplitude: Float = 0) -> [Float] {
        var generator = SplitMix(seed: 7)
        return (0..<Int(seconds * Double(rate))).map { _ in amplitude * (Float(generator.next() % 2001) / 1000 - 1) }
    }

    /// Feeds `audio` in microphone-sized chunks, then ends the session.
    static func segments(_ audio: [Float], chunk: Int = 1_600) -> [AudioSegment] {
        var segmenter = PauseSegmenter()
        var out: [AudioSegment] = []
        var i = 0
        while i < audio.count {
            out += segmenter.append(Array(audio[i..<min(audio.count, i + chunk)]))
            i += chunk
        }
        if let last = segmenter.finish() { out.append(last) }
        return out
    }

    // MARK: Pauses cut the audio

    @Test func aPauseOfOneSecondCutsTwoSegments() {
        let audio = Self.quiet(0.5) + Self.speech(1.2) + Self.quiet(1.0) + Self.speech(0.9) + Self.quiet(0.3)
        let cut = Self.segments(audio)
        #expect(cut.count == 2)
        guard cut.count == 2 else { return }
        #expect(abs(cut[0].start - 0.5) < 0.05)
        #expect(abs(cut[0].end - 1.7) < 0.05)
        #expect(abs(cut[1].start - 2.7) < 0.05)
        // The pause between them is longer than the transcript's line threshold.
        #expect(cut[1].start - cut[0].end > Transcript.pauseThreshold)
    }

    @Test func aShortBreathDoesNotCut() {
        let audio = Self.speech(1.0) + Self.quiet(0.5) + Self.speech(1.0) + Self.quiet(1.0)
        let cut = Self.segments(audio)
        #expect(cut.count == 1)
        #expect(abs((cut.first?.end ?? 0) - 2.5) < 0.05)
    }

    @Test func theSegmentIsEmittedAsSoonAsThePauseReaches08Seconds() {
        var segmenter = PauseSegmenter()
        #expect(segmenter.append(Self.speech(1.0) + Self.quiet(0.7)).isEmpty)
        #expect(segmenter.append(Self.quiet(0.12)).count == 1)
    }

    @Test func silenceAndClicksGiveNothing() {
        #expect(Self.segments(Self.quiet(3)).isEmpty)
        let click = Self.quiet(1) + Self.speech(0.06) + Self.quiet(1.5)
        #expect(Self.segments(click).isEmpty)
    }

    @Test func steadyRoomNoiseIsNotSpeech() {
        // Room tone around −45 dBFS throughout, speech on top of it.
        let noise: Float = 0.01
        let audio = Self.quiet(1, amplitude: noise) + Self.speech(1.0) + Self.quiet(1.2, amplitude: noise)
            + Self.speech(1.0) + Self.quiet(1.0, amplitude: noise)
        #expect(Self.segments(audio).count == 2)
    }

    @Test func stoppingMidPhraseKeepsTheTail() {
        let cut = Self.segments(Self.quiet(0.3) + Self.speech(1.5))
        #expect(cut.count == 1)
        #expect(abs((cut.first?.end ?? 0) - 1.8) < 0.05)
    }

    @Test func segmentsCarryTheirAudioWithAShortMargin() {
        let cut = Self.segments(Self.quiet(1) + Self.speech(1.0) + Self.quiet(1.0))
        let samples = cut.first?.samples.count ?? 0
        // 1 s of speech plus up to 0.2 s before and after.
        #expect(samples >= Self.rate && samples <= Int(1.45 * Double(Self.rate)))
    }

    @Test func aMonologueIsCutBeforeWhispersThirtySecondWindow() {
        let cut = Self.segments(Self.speech(40))
        #expect(cut.count == 2)
        #expect(cut.allSatisfy { $0.end - $0.start <= PauseSegmenter.maximumSegment + 0.01 })
        // Cut without a pause: the parts continue each other (same transcript line).
        if cut.count == 2 { #expect(cut[1].start - cut[0].end < Transcript.pauseThreshold) }
    }

    @Test func shortSegmentsArePaddedToWhatWhisperAccepts() {
        let padded = PauseSegmenter.paddedForWhisper(Self.speech(0.4))
        #expect(padded.count >= Self.rate + Self.rate / 10)
        #expect(PauseSegmenter.paddedForWhisper(Self.speech(3)).count == 3 * Self.rate)
    }

    // MARK: Segment text → lines

    @Test func everySegmentIsALineAndCommandsStillWork() {
        var transcript = Transcript()
        transcript.commit(SpeechSegmentText.words("Оплатить интернет.", start: 0.5, end: 1.7))
        transcript.commit(SpeechSegmentText.words("Call the dentist", start: 2.7, end: 3.6))
        #expect(transcript.lines == ["Оплатить интернет", "Call the dentist"])
        // A monologue cut at 25 s continues the same line.
        transcript.commit(SpeechSegmentText.words("и записаться", start: 4.6, end: 29.6))
        transcript.commit(SpeechSegmentText.words("к стоматологу", start: 29.62, end: 31))
        #expect(transcript.lines.last == "и записаться к стоматологу")
        let commands = transcript.commit(SpeechSegmentText.words("Готово.", start: 32, end: 32.5))
        #expect(commands == [.finish])
    }

    @Test func englishSegmentsAndDoneWork() {
        var transcript = Transcript()
        transcript.commit(SpeechSegmentText.words("Pay the internet bill.", start: 0.5, end: 1.7))
        transcript.commit(SpeechSegmentText.words("Book a dentist appointment next week", start: 2.7, end: 3.6))
        let commands = transcript.commit(SpeechSegmentText.words("Done.", start: 5, end: 5.4))
        #expect(transcript.lines == ["Pay the internet bill", "Book a dentist appointment next week"])
        #expect(commands == [.finish])
    }

    @Test func whispersSilencePhrasesAreDropped() {
        #expect(WhisperText.clean("  Продолжение следует...  ") == nil)
        #expect(WhisperText.clean("Субтитры сделал DimaTorzok") == nil)
        #expect(WhisperText.clean("[BLANK_AUDIO]") == nil)
        #expect(WhisperText.clean(" (музыка) ") == nil)
        #expect(WhisperText.clean("Thank you.") == nil)
        #expect(WhisperText.clean("") == nil)
        #expect(WhisperText.clean("  Оплатить интернет до 16. ") == "Оплатить интернет до 16.")
        #expect(WhisperText.clean("Thank you, отправить счёт клиенту") == "Thank you, отправить счёт клиенту")
    }

    // MARK: Engine setting

    @Test func whisperIsTheDefaultAndExplicitSystemStays() throws {
        #expect(BubbleSettings().speechEngine == .whisper)
        let old = Data(#"{"roundness": 40}"#.utf8)
        #expect(try JSONDecoder().decode(BubbleSettings.self, from: old).speechEngine == .whisper)
        let system = Data(#"{"speechEngine": "system"}"#.utf8)
        #expect(try JSONDecoder().decode(BubbleSettings.self, from: system).speechEngine == .system)
        let unknown = Data(#"{"speechEngine": "parakeet"}"#.utf8)
        #expect(try JSONDecoder().decode(BubbleSettings.self, from: unknown).speechEngine == .whisper)
        var cloud = BubbleSettings()
        cloud.speechEngine = .openAI
        cloud.transcriptionModel = "whisper-1"
        let decoded = try JSONDecoder().decode(BubbleSettings.self, from: JSONEncoder().encode(cloud))
        #expect(decoded.speechEngine == .openAI)
        #expect(decoded.transcriptionModel == "whisper-1")
    }

    @Test func enginesInTheSettingsOrder() {
        #expect(SpeechEngine.allCases == [.whisper, .openAI, .system, .handy])
        #expect(SpeechEngine.allCases.map(\.label) == ["Built-in Whisper", "ChatGPT (cloud)", "macOS", "Handy"])
    }

    @Test func theEngineInUseFallsBackToWhatCanWork() {
        func pick(_ s: SpeechEngine, handy: Bool = false, model: Bool = true, key: Bool = false) -> SpeechEngine {
            SpeechEngine.effective(selected: s, handyInstalled: handy, whisperReady: model, openAIKey: key)
        }
        #expect(pick(.whisper) == .whisper)
        #expect(pick(.whisper, model: false) == .system)
        #expect(pick(.openAI, key: true) == .openAI)
        #expect(pick(.openAI) == .whisper)
        #expect(pick(.openAI, model: false) == .system)
        #expect(pick(.handy, handy: true) == .handy)
        #expect(pick(.handy) == .whisper)
        #expect(pick(.system) == .system)
    }

    // MARK: Cloud: ChatGPT audio/transcriptions

    @Test func theCloudRequestIsMultipartWithTheKeyOnlyInTheHeader() throws {
        let wav = WAVFile.pcm16(Self.speech(0.5))
        let request = OpenAITranscriber.request(wav: wav, apiKey: "sk-test-123", model: "gpt-4o-mini-transcribe",
                                                boundary: "BOUNDARY")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        let body = try #require(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        #expect(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"))
        #expect(text.hasSuffix("--BOUNDARY--\r\n"))
        #expect(!text.contains("sk-test-123"))
        #expect(body.range(of: wav) != nil)
    }

    @Test func wavHeaderDescribes16kMono16Bit() throws {
        let wav = WAVFile.pcm16([0, 1, -1, 2])
        try #require(wav.count == 44 + 8)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: UInt16(wav[at]) | UInt16(wav[at + 1]) << 8) }
        #expect(u32(24) == 16_000)              // sample rate
        #expect(i16(22) == 1)                   // channels
        #expect(i16(34) == 16)                  // bits per sample
        #expect(u32(40) == 8)                   // data bytes
        #expect([i16(44), i16(46), i16(48), i16(50)] == [0, 32767, -32767, 32767])   // clamped
    }

    @Test func theCloudReplyIsReadAndErrorsAreClassifiedLikeTheParser() async throws {
        #expect(try OpenAITranscriber.decode(Data(#"{"text":"  Pay the internet bill. "}"#.utf8)) == "Pay the internet bill.")
        #expect(throws: ClaudeParserError.badResponse) { try OpenAITranscriber.decode(Data("<html>".utf8)) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubTranscriptions.self]
        let session = URLSession(configuration: config)
        let audio = Self.speech(1)
        let ok = OpenAITranscriber(apiKey: "ok", session: session)
        #expect(try await ok.transcribe(audio) == "Book a dentist appointment")
        for (key, failure) in [("bad", ClaudeFailure.invalidKey), ("broke", .noCredit), ("busy", .unavailable),
                               ("offline", .offline)] {
            do {
                _ = try await OpenAITranscriber(apiKey: key, session: session).transcribe(audio)
                Issue.record("\(key) should fail")
            } catch {
                #expect(ClaudeFailure.classify(error) == failure)
            }
        }
        #expect(OpenAITranscriber(apiKey: "x").session === ClaudeHTTP.session)
    }

    @Test func cloudFailuresSayTheBuiltInWhisperTookOver() {
        #expect(SpeechCloudFailure.message(.invalidKey) == "The ChatGPT key doesn't work — the built-in Whisper takes over from here")
        #expect(SpeechCloudFailure.message(.offline) == "No internet — the built-in Whisper takes over from here")
        #expect(SpeechCloudFailure.message(.noCredit) == "Your OpenAI account is out of credit — the built-in Whisper takes over from here")
    }

    // MARK: Model file

    @Test func theModelIsLookedForInTheAppFirstThenInApplicationSupport() {
        let resources = URL(fileURLWithPath: "/Applications/Bubbles.app/Contents/Resources")
        let support = URL(fileURLWithPath: "/tmp/support/ggml-large-v3-turbo-q5_0.bin")
        let bundled = resources.appendingPathComponent("Models/ggml-large-v3-turbo-q5_0.bin")
        #expect(WhisperModel.locate(resources: resources, downloaded: support, exists: { _ in true }) == bundled)
        #expect(WhisperModel.locate(resources: resources, downloaded: support, exists: { $0 == support }) == support)
        #expect(WhisperModel.locate(resources: nil, downloaded: support, exists: { _ in false }) == nil)
        #expect(WhisperModel.downloadURL.absoluteString
            == "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        #expect(WhisperModel.defaultDownloadedURL.path.hasSuffix("Application Support/Bubbles/Models/ggml-large-v3-turbo-q5_0.bin"))
    }
}

/// Answers `audio/transcriptions` without the network: the bearer token picks the canned response.
final class StubTranscriptions: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        if key == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let (status, body): (Int, String) = switch key {
        case "ok": (200, #"{"text":"Book a dentist appointment"}"#)
        case "broke": (429, #"{"error":{"type":"insufficient_quota","code":"insufficient_quota"}}"#)
        case "busy": (429, #"{"error":{"code":"rate_limit_exceeded"}}"#)
        default: (401, #"{"error":{"code":"invalid_api_key"}}"#)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Deterministic noise for the room-tone fixtures.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E4B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
