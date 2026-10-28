import Foundation

/// 16-bit PCM WAV, mono, for sending a segment to a transcription API.
public enum WAVFile {
    public static func pcm16(_ samples: [Float], sampleRate: Int = PauseSegmenter.sampleRate) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        u32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)                          // fmt chunk size
        u16(1)                           // PCM
        u16(1)                           // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))      // byte rate
        u16(2)                           // block align
        u16(16)                          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        u32(bytes)
        for sample in samples {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            u16(UInt16(bitPattern: Int16((clamped * 32767).rounded())))
        }
        return data
    }
}

/// "ChatGPT (cloud)": one segment → text through OpenAI's `audio/transcriptions` (Claude's API has no speech
/// recognition). The key travels only in the `Authorization` header and is never logged or stored here; the
/// session is the shared ephemeral one without a cache. Errors are `ClaudeParserError`s, so `ClaudeFailure`
/// classifies them like the parser's.
public struct OpenAITranscriber: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let defaultModel = "gpt-4o-mini-transcribe"
    public static let timeout: TimeInterval = 20

    private let apiKey: String
    private let model: String
    public let session: URLSession

    public init(apiKey: String, model: String = OpenAITranscriber.defaultModel, session: URLSession = ClaudeHTTP.session) {
        self.apiKey = apiKey
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmed.isEmpty ? Self.defaultModel : trimmed
        self.session = session
    }

    /// 16 kHz mono audio → its text (trimmed; may be empty).
    public func transcribe(_ samples: [Float]) async throws -> String {
        let request = Self.request(wav: WAVFile.pcm16(samples), apiKey: apiKey, model: model)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ClaudeParserError.timeout
        }
        guard let http = response as? HTTPURLResponse else { throw ClaudeParserError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429, String(decoding: data, as: UTF8.self).contains("insufficient_quota") {
                throw ClaudeParserError.noCredit
            }
            throw ClaudeParserError.http(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// multipart/form-data: `model`, `response_format=json`, `file` (segment.wav).
    public static func request(wav: Data, apiKey: String, model: String, boundary: String = UUID().uuidString) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func text(_ string: String) { body.append(contentsOf: Array(string.utf8)) }
        func field(_ name: String, _ value: String) {
            text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        field("model", model)
        field("response_format", "json")
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\n")
        text("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        text("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    /// `{"text": "…"}` → the text, trimmed.
    public static func decode(_ body: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = object["text"] as? String else { throw ClaudeParserError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The cloud did not transcribe a segment: the same wording as a failed parse, and the built-in Whisper
/// takes over for the rest of the dictation.
public enum SpeechCloudFailure {
    public static let takeover = "the built-in Whisper takes over from here"

    public static func message(_ failure: ClaudeFailure) -> String {
        let parse = failure.message(for: .openAI)
        guard let dash = parse.range(of: " — ", options: .backwards) else { return "\(parse) — \(takeover)" }
        return parse[..<dash.lowerBound] + " — " + takeover
    }
}
