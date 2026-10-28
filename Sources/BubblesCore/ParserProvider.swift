import Foundation

// MARK: - Who parses the dictation

/// The AI that turns dictated lines into tasks. Each has its own key in the Keychain and its own model.
/// With no key at all the app is a plain tracker: every line becomes a task as written.
public enum ParserProvider: String, Codable, CaseIterable, Sendable {
    case claude, openAI

    /// The name the person sees: «Claude» / «ChatGPT».
    public var label: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        }
    }

    /// The company that bills for the API.
    public var vendor: String {
        switch self {
        case .claude: "Anthropic"
        case .openAI: "OpenAI"
        }
    }

    public var defaultModel: String {
        switch self {
        case .claude: "claude-haiku-5-5"
        case .openAI: "gpt-4o-mini"
        }
    }

    /// The Keychain generic-password service the key lives under (the key itself never leaves the Keychain).
    public var keychainService: String {
        switch self {
        case .claude: "Bubbles.ClaudeAPIKey"
        case .openAI: "Bubbles.OpenAIAPIKey"
        }
    }

    /// The key field's placeholder.
    public var keyPrompt: String {
        switch self {
        case .claude: "sk-ant-…"
        case .openAI: "sk-…"
        }
    }

    /// Where to get a key.
    public var consoleURL: URL {
        switch self {
        case .claude: ClaudeKeyCheck.consoleURL
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        }
    }

    /// The one rule for who parses: the selected provider when its key is stored, else nobody (nil — the
    /// plain tracker). The text never goes to a provider that was not chosen, even when its key is stored.
    public static func active(selected: ParserProvider, hasKey: (ParserProvider) -> Bool) -> ParserProvider? {
        hasKey(selected) ? selected : nil
    }

    /// The selected provider when it has no key but another one does: the lines are kept as written and the
    /// banner asks to connect it. nil when it has its key, or when there are no keys at all (no banner).
    public static func missingKey(selected: ParserProvider, hasKey: (ParserProvider) -> Bool) -> ParserProvider? {
        guard !hasKey(selected), allCases.contains(where: { $0 != selected && hasKey($0) }) else { return nil }
        return selected
    }
}

extension BubbleSettings {
    /// The model to ask: the field from the settings, or the provider's default when it is empty.
    public func model(for provider: ParserProvider) -> String {
        let typed = switch provider {
        case .claude: claudeModel
        case .openAI: openAIModel
        }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }
}

// MARK: - Parsing with whichever provider

/// What became of the dictated lines.
public struct ParseOutcome: Equatable, Sendable {
    public var result: TaskParseResult
    /// Who parsed; nil when the lines were kept as written (no key, or the AI failed).
    public var parsedBy: ParserProvider?
    /// Who was asked (nil: no key at all). Names the provider in the failure texts.
    public var provider: ParserProvider?
    /// Why the AI did not parse although a key is stored.
    public var failure: ClaudeFailure?

    public init(result: TaskParseResult, parsedBy: ParserProvider?, provider: ParserProvider?, failure: ClaudeFailure?) {
        self.result = result
        self.parsedBy = parsedBy
        self.provider = provider
        self.failure = failure
    }
}

public enum ProviderParser {
    /// `provider` nil (no key): every line becomes a task as written, no rules; `missingKey` (the chosen
    /// provider has no key, another one has) adds the `.keyMissing` banner. With a provider: its parser;
    /// `apiKey` nil means the Keychain refused the stored key. Any failure keeps the lines as written and says why.
    public static func parse(lines: [String], provider: ParserProvider?, apiKey: String?, model: String,
                             missingKey: ParserProvider? = nil, now: Date = Date(), session: URLSession = ClaudeHTTP.session) async -> ParseOutcome {
        let plain = TaskParser.plain(lines: lines, now: now)
        guard let provider else {
            return ParseOutcome(result: plain, parsedBy: nil, provider: missingKey, failure: missingKey.map { _ in .keyMissing })
        }
        guard let apiKey else { return ParseOutcome(result: plain, parsedBy: nil, provider: provider, failure: .keyUnreadable) }
        do {
            let result = switch provider {
            case .claude: try await ClaudeTaskParser(apiKey: apiKey, model: model, session: session).parse(lines: lines, now: now)
            case .openAI: try await OpenAITaskParser(apiKey: apiKey, model: model, session: session).parse(lines: lines, now: now)
            }
            return ParseOutcome(result: result, parsedBy: provider, provider: provider, failure: nil)
        } catch {
            return ParseOutcome(result: plain, parsedBy: nil, provider: provider, failure: ClaudeFailure.classify(error))
        }
    }
}

// MARK: - "Check" for either key

public enum ProviderKeyCheck {
    public static func request(_ provider: ParserProvider, apiKey: String) -> URLRequest {
        switch provider {
        case .claude: return ClaudeKeyCheck.request(apiKey: apiKey)
        case .openAI:
            var request = URLRequest(url: OpenAITaskParser.modelsEndpoint, timeoutInterval: ClaudeKeyCheck.timeout)
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    public static func status(_ provider: ParserProvider, httpCode: Int) -> ClaudeKeyStatus {
        switch httpCode {
        case 200..<300: .valid
        case 401, 403: .invalid
        case 429, 500...: .unavailable("\(provider.label) is overloaded right now — the key is saved, we'll check later")
        default: .unavailable("\(provider.label) returned error \(httpCode) — try again")
        }
    }

    /// Never throws and never echoes the key: network trouble becomes `.unavailable`.
    public static func verify(_ provider: ParserProvider, apiKey: String, session: URLSession = ClaudeHTTP.session) async -> ClaudeKeyStatus {
        do {
            let (_, response) = try await session.data(for: request(provider, apiKey: apiKey))
            guard let http = response as? HTTPURLResponse else { return .unavailable("\(provider.label) didn't answer — try again") }
            return status(provider, httpCode: http.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return .unavailable("\(provider.label) didn't answer within 15 seconds — try again")
        } catch {
            return .unavailable("No internet — we'll check the key once you're online")
        }
    }
}

extension ClaudeKeyStatus {
    public func message(for provider: ParserProvider) -> String {
        switch self {
        case .valid: "The key works — \(provider.label) parses your tasks"
        case .invalid, .unavailable: message
        }
    }
}

// MARK: - The reply format both providers are asked for

/// Numbered lines in, `{"tasks":[{line,title,priority,time,kind,long}],"leftover":[…]}` out — the same for
/// Claude and ChatGPT, so both are read by one decoder.
enum TaskReply {
    static func systemPrompt(now: Date) -> String {
        """
        You turn a person's spoken plan for today (in Russian or English, messy speech-to-text) into a task list.
        The input is numbered lines; each line usually holds one task, sometimes several, sometimes none.
        Current local time: \(DayTask.clock(Ranker.minutesSinceMidnight(now))).
        Reply with one JSON object only — no prose, no code fences:
        {"tasks": [{"line": number, "title": string, "priority": 1|2|3, "time": "HH:MM" or null, "kind": "by" or "at" or null, "long": true|false}], "leftover": [number]}
        Rules:
        - line: the number of the input line the task came from. A line may give several tasks; never merge tasks from different lines.
        - leftover: numbers of lines that hold no task (chatter like "so I guess that's it" or «ну вроде всё»). Every input line must appear either as some task's "line" or in "leftover".
        - title: short imperative, capitalised, without filler words, priority words or the time. Keep each title in the language the person used for that task (Russian stays Russian, English stays English); never translate.
        - priority: 3 for "urgent", "asap", «срочно», «обязательно» or clearly urgent; 2 for "important", «важно», «главное» or anything with a time; otherwise 1.
        - time: 24-hour local time if one is named (digits or words: «до шестнадцати» → "16:00", "by 4 pm" → "16:00"), else null. "by 16", "before 4 pm", «до 16», «к 16» → kind "by" (deadline); "at 12", «в 12» → kind "at" (appointment). An English hour without am/pm means the next such hour from now during the day.
        - long: true when the speaker calls the task long or multi-day ("long task", "for a few days", "this week", «длинная», «долгая», «на несколько дней», «на неделю»); keep those words out of the title. Otherwise false.
        - Tasks in the order spoken.
        """
    }

    static func clean(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// «1. …\n2. …».
    static func numbered(_ lines: [String]) -> String {
        lines.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    /// The model's text → tasks with `sourceLine` (0-based index into `lines`) and `leftover`.
    /// Accepts the `{"tasks": [...], "leftover": [...]}` object and, for older replies, a bare task array;
    /// tolerant of ```json fences. A line the reply does not mention is added to `leftover`.
    static func decode(_ text: String, lines: [String], now: Date) throws -> TaskParseResult {
        let unfenced = stripFence(text)

        var items: [Any]
        var leftoverItems: [Any] = []
        if let json = extract(from: unfenced, open: "{", close: "}"),
           let reply = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
           let tasks = reply["tasks"] as? [Any] {
            items = tasks
            leftoverItems = reply["leftover"] as? [Any] ?? []
        } else if let json = extract(from: unfenced, open: "[", close: "]"),
                  let array = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] {
            items = array
        } else {
            throw ClaudeParserError.badResponse
        }

        var result = TaskParseResult()
        for case let item as [String: Any] in items {
            guard let task = task(from: item, now: now) else { continue }
            result.tasks.append(ParsedTask(task: task, sourceLine: lineIndex(item["line"], count: lines.count)))
        }
        if result.tasks.isEmpty && !items.isEmpty { throw ClaudeParserError.badResponse }

        var leftoverLines = Set<Int>()
        for entry in leftoverItems {
            if let index = lineIndex(entry, count: lines.count) {
                if leftoverLines.insert(index).inserted { result.leftover.append(lines[index]) }
            } else if let phrase = (entry as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty {
                result.leftover.append(phrase)
            }
        }
        // Only when the reply numbers its tasks can a missing line be told apart from an unnumbered reply.
        if result.tasks.contains(where: { $0.sourceLine != nil }) {
            let used = Set(result.tasks.compactMap(\.sourceLine)).union(leftoverLines)
            for (index, line) in lines.enumerated() where !used.contains(index) {
                result.leftover.append(line)
            }
        }
        return result
    }

    /// A 1-based line number from the reply (number or numeric string) → 0-based index, if in range.
    private static func lineIndex(_ value: Any?, count: Int) -> Int? {
        let number: Int?
        if let n = value as? Int { number = n } else if let s = value as? String { number = Int(s.trimmingCharacters(in: .whitespaces)) } else { number = nil }
        guard let n = number, (1...max(1, count)).contains(n), count > 0 else { return nil }
        return n - 1
    }

    /// The text inside a ``` fence if there is one (the optional «json» tag skipped), else the text itself.
    private static func stripFence(_ text: String) -> String {
        guard let open = text.range(of: "```") else { return text }
        var inner = text[open.upperBound...]
        if let newline = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: newline)...] }
        if let close = inner.range(of: "```") { inner = inner[..<close.lowerBound] }
        return String(inner)
    }

    private static func extract(from text: String, open: Character, close: Character) -> String? {
        guard let first = text.firstIndex(of: open), let last = text.lastIndex(of: close), first < last else { return nil }
        return String(text[first...last])
    }

    static func task(from item: [String: Any], now: Date) -> DayTask? {
        guard let rawTitle = item["title"] as? String else { return nil }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let rawPriority = (item["priority"] as? Int) ?? Int(item["priority"] as? String ?? "") ?? 1
        let priority = Priority(rawValue: min(3, max(1, rawPriority))) ?? .normal

        var minutes: Int?
        if let time = item["time"] as? String {
            let parts = time.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let h = parts.first ?? nil, (0..<24).contains(h) {
                let m = parts.count > 1 ? (parts[1] ?? 0) : 0
                if (0..<60).contains(m) { minutes = h * 60 + m }
            }
        }
        var kind: DueKind?
        if minutes != nil {
            switch (item["kind"] as? String)?.lowercased() {
            case "at", "в": kind = .at
            default: kind = .deadline
            }
        }
        let long = (item["long"] as? Bool) ?? ((item["long"] as? String)?.lowercased() == "true")
        return DayTask(title: title, priority: priority, dueMinutes: minutes, dueKind: kind, kind: long ? .long : .today,
                       note: long ? LongTask.firstDayNote : nil, createdAt: now)
    }
}
