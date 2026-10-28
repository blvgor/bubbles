import Foundation

/// Turns dictated lines into tasks with the OpenAI Chat Completions API, in JSON mode and in the same reply
/// format as Claude (`TaskReply`). The key travels only in the `Authorization` header; it is never logged
/// or stored here. Errors are the same `ClaudeParserError`s as Claude's, so `ClaudeFailure` reads both alike.
public struct OpenAITaskParser: Sendable {
    public static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// "Check": the models list needs a valid key and costs nothing.
    public static let modelsEndpoint = URL(string: "https://api.openai.com/v1/models")!
    public static let timeout: TimeInterval = 15

    private let apiKey: String
    private let model: String
    public let session: URLSession

    public init(apiKey: String, model: String = ParserProvider.openAI.defaultModel, session: URLSession = ClaudeHTTP.session) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Sends the transcript as numbered lines; every task in the reply is tied to its line, and a line the
    /// reply does not mention lands in `leftover`.
    public func parse(lines: [String], now: Date = Date()) async throws -> TaskParseResult {
        let lines = TaskReply.clean(lines)
        let request = Self.request(for: lines, apiKey: apiKey, model: model, now: now)
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
        return try Self.decode(data, lines: lines, now: now)
    }

    /// System prompt = the shared reply format; user message = the lines numbered from 1.
    public static func request(for lines: [String], apiKey: String, model: String, now: Date) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "max_completion_tokens": 4096,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": TaskReply.systemPrompt(now: now)],
                ["role": "user", "content": TaskReply.numbered(lines)],
            ],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Chat Completions response → tasks with `sourceLine` (0-based index into `lines`) and `leftover`.
    /// No assistant text (a refusal, an empty reply) is a bad response.
    public static func decode(_ body: Data, lines: [String], now: Date = Date()) throws -> TaskParseResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ClaudeParserError.badResponse }
        return try TaskReply.decode(text, lines: lines, now: now)
    }
}
