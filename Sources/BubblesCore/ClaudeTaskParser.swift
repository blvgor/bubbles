import Foundation

public enum ClaudeParserError: Error, Equatable {
    /// Non-2xx status from the API.
    case http(Int)
    /// The response is not a Messages API reply with a JSON array of tasks.
    case badResponse
    /// No answer within 15 seconds.
    case timeout
    /// The key works, but the account has no money left (Anthropic 400 «credit balance is too low»,
    /// OpenAI 429 «insufficient_quota»).
    case noCredit
}

/// Turns a dictated day into tasks with the Claude Messages API.
/// The key travels only in the `x-api-key` header; it is never logged or stored here.
/// Other network failures (offline, DNS) surface as `URLError`; on any error `ProviderParser` keeps the lines as written.
public struct ClaudeTaskParser: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let timeout: TimeInterval = 15

    private let apiKey: String
    private let model: String
    public let session: URLSession

    public init(apiKey: String, model: String = "claude-haiku-5-5", session: URLSession = ClaudeHTTP.session) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Free text: newline-separated lines are sent numbered, as in `parse(lines:)`.
    public func parse(_ text: String, now: Date = Date()) async throws -> [DayTask] {
        try await parse(lines: text.components(separatedBy: .newlines), now: now).dayTasks
    }

    /// Sends the transcript as numbered lines; the reply ties every task to its line and lists what is not
    /// a task. A line the reply does not mention is added to `leftover`, so nothing disappears silently.
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
            if http.statusCode == 400, String(decoding: data, as: UTF8.self).contains("credit balance") {
                throw ClaudeParserError.noCredit
            }
            throw ClaudeParserError.http(http.statusCode)
        }
        return try Self.decode(data, lines: lines, now: now)
    }

    public static func request(for text: String, apiKey: String, model: String, now: Date) -> URLRequest {
        request(for: TaskReply.clean(text.components(separatedBy: .newlines)), apiKey: apiKey, model: model, now: now)
    }

    /// The user message is the lines numbered from 1: «1. …\n2. …».
    public static func request(for lines: [String], apiKey: String, model: String, now: Date) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": TaskReply.systemPrompt(now: now),
            "messages": [["role": "user", "content": TaskReply.numbered(lines)]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func decode(_ body: Data) throws -> [DayTask] {
        try decode(body, lines: [], now: Date()).dayTasks
    }

    /// Messages API response → tasks with `sourceLine` (0-based index into `lines`) and `leftover`.
    /// Accepts the `{"tasks": [...], "leftover": [...]}` object and, for older replies, a bare task array.
    public static func decode(_ body: Data, lines: [String], now: Date = Date()) throws -> TaskParseResult {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { throw ClaudeParserError.badResponse }
        let text = content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return try TaskReply.decode(text, lines: lines, now: now)
    }
}

// MARK: - Transport

/// The one URL session for every request that carries the Claude key: ephemeral and without a URL cache,
/// so no request or response (with its `x-api-key` header) ever lands in a Cache.db on disk.
public enum ClaudeHTTP {
    public static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()
}

// MARK: - Why Claude did not parse

/// Why the AI (Claude or ChatGPT) did not parse, with what the person sees and the button that fixes it.
/// The same cases and texts for both providers; the lines are then kept as written.
public enum ClaudeFailure: Equatable, Sendable {
    /// 401/403: the key is wrong.
    case invalidKey
    /// 429/529/5xx or no answer in 15 s.
    case unavailable
    /// No network.
    case offline
    /// A key is stored, but the Keychain did not hand it over.
    case keyUnreadable
    /// Anything else (an unexpected status or reply).
    case other
    /// The key works, but the account has no money left.
    case noCredit
    /// The chosen provider has no key (another one has; the text is not sent there).
    case keyMissing

    public static func classify(_ error: Error) -> ClaudeFailure {
        if let error = error as? ClaudeParserError {
            switch error {
            case .http(401), .http(403): return .invalidKey
            case .http(429), .http(500...): return .unavailable
            case .timeout: return .unavailable
            case .noCredit: return .noCredit
            case .http, .badResponse: return .other
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return .unavailable
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .secureConnectionFailed:
                return .offline
            default: return .other
            }
        }
        return .other
    }

    /// Claude's wording; `message(for:)` names the provider that was asked.
    public var message: String { message(for: .claude) }

    public func message(for provider: ParserProvider) -> String {
        let name = provider.label
        let kept = "kept the lines as written"
        return switch self {
        case .invalidKey: "The \(name) key doesn't work — \(kept)"
        case .unavailable: "\(name) didn't answer — \(kept)"
        case .offline: "No internet — \(kept)"
        case .keyUnreadable: "macOS didn't hand over the \(name) key from the Keychain — \(kept)"
        case .keyMissing: "No \(name) key connected — \(kept)"
        case .noCredit: "Your \(provider.vendor) account is out of credit — \(kept)"
        case .other: "\(name) sent an answer that made no sense — \(kept)"
        }
    }

    /// The banner's button: "Change key" / "Connect" open the settings, "Retry" asks the AI again.
    public var actionLabel: String {
        switch self {
        case .invalidKey, .keyUnreadable: "Change key"
        case .keyMissing: "Connect"
        case .unavailable, .offline, .noCredit, .other: "Retry"
        }
    }

    /// Whether the button retries the parse (else it opens the key settings).
    public var retries: Bool {
        switch self {
        case .invalidKey, .keyUnreadable, .keyMissing: false
        case .unavailable, .offline, .noCredit, .other: true
        }
    }
}
