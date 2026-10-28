import Foundation
import Testing
import BubblesCore

/// Answers Chat Completions requests without the network: the bearer token picks the canned response.
final class StubOpenAI: URLProtocol, @unchecked Sendable {
    static let okBody = ProvidersTests.completion(content: #"{"tasks":[{"line":1,"title":"Оплатить интернет","priority":3,"time":"16:00","kind":"by","long":false}],"leftover":[]}"#)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let auth = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let key = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
        if key == "slow" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        if key == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let status: Int
        let body: Data
        switch key {
        case "ok":
            (status, body) = (200, Self.okBody)
        case "broke":
            (status, body) = (429, Data(#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8))
        case "busy":
            (status, body) = (429, Data(#"{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}"#.utf8))
        default:
            (status, body) = (401, Data(#"{"error":{"message":"Incorrect API key provided","code":"invalid_api_key"}}"#.utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct ProvidersTests {
    /// A Chat Completions response whose assistant message is `content`.
    static func completion(content: String?, finish: String = "stop") -> Data {
        let message: [String: Any] = ["role": "assistant", "content": content ?? NSNull()]
        let object: [String: Any] = [
            "id": "chatcmpl-test", "object": "chat.completion", "model": "gpt-4o-mini",
            "choices": [["index": 0, "message": message, "finish_reason": finish]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private var stubSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOpenAI.self]
        return URLSession(configuration: config)
    }

    // MARK: OpenAI request

    @Test func openAIRequestIsChatCompletionsWithKeyOnlyInAuthorization() throws {
        let key = "sk-test-not-a-real-key"
        let lines = ["срочно оплатить интернет до 16", "созвон с командой в 12", "ну вроде всё"]
        let request = OpenAITaskParser.request(for: lines, apiKey: key, model: "gpt-4o-mini", now: Date())
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 15)

        let body = try #require(request.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains(key))
        #expect(!(request.url?.absoluteString.contains(key) ?? true))
        let headersWithKey = (request.allHTTPHeaderFields ?? [:]).filter { $0.value.contains(key) }.map(\.key)
        #expect(headersWithKey == ["Authorization"])

        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4o-mini")
        #expect((json["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.last?["content"] as? String == "1. срочно оплатить интернет до 16\n2. созвон с командой в 12\n3. ну вроде всё")
        let system = try #require(messages.first?["content"] as? String)
        // json_object mode needs the word JSON in the prompt; the reply format is Claude's.
        #expect(system.contains("JSON"))
        #expect(system.contains("\"line\"") && system.contains("\"leftover\"") && system.contains("\"long\""))
    }

    @Test func openAIRequestUsesTheModelFromSettings() throws {
        let request = OpenAITaskParser.request(for: ["купить хлеб"], apiKey: "k", model: "gpt-4.1-mini", now: Date())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gpt-4.1-mini")
    }

    // MARK: OpenAI reply

    @Test func openAIReplyBecomesTasksWithLinesAndLeftover() throws {
        let lines = ["срочно оплатить интернет до 16", "купить продукты и забрать посылку", "ну вроде всё", "записаться к стоматологу"]
        let content = #"{"tasks":[{"line":1,"title":"Оплатить интернет","priority":3,"time":"16:00","kind":"by","long":false},{"line":2,"title":"Купить продукты","priority":1,"time":null,"kind":null,"long":false},{"line":2,"title":"Забрать посылку","priority":1,"time":null,"kind":null,"long":false}],"leftover":[3]}"#
        let result = try OpenAITaskParser.decode(Self.completion(content: content), lines: lines)
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет", "Купить продукты", "Забрать посылку"])
        #expect(result.tasks.map(\.sourceLine) == [0, 1, 1])
        #expect(result.tasks.map(\.task.priority) == [.urgent, .normal, .normal])
        #expect(result.tasks.first?.task.dueMinutes == 960)
        #expect(result.tasks.first?.task.dueKind == .deadline)
        // Line 4 is in neither list: it is not lost.
        #expect(result.leftover == ["ну вроде всё", "записаться к стоматологу"])
    }

    @Test func openAIReplyThatIsNotTasksIsBadResponse() {
        #expect(throws: ClaudeParserError.badResponse) { try OpenAITaskParser.decode(Data("not json".utf8), lines: ["x"]) }
        #expect(throws: ClaudeParserError.badResponse) {
            try OpenAITaskParser.decode(Self.completion(content: "Sorry, I can't help with that"), lines: ["x"])
        }
        #expect(throws: ClaudeParserError.badResponse) {
            try OpenAITaskParser.decode(Self.completion(content: nil), lines: ["x"])
        }
        #expect(throws: ClaudeParserError.badResponse) {
            try OpenAITaskParser.decode(Self.completion(content: #"{"tasks":[{"name":"untitled"}]}"#), lines: ["x"])
        }
    }

    @Test func openAIParseThroughTheSession() async throws {
        let result = try await OpenAITaskParser(apiKey: "ok", session: stubSession).parse(lines: ["оплатить интернет до 16"])
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет"])
        #expect(result.tasks.first?.sourceLine == 0)
    }

    @Test func openAIErrorsAreTheSameTypedErrorsAsClaudes() async {
        await #expect(throws: ClaudeParserError.http(401)) {
            try await OpenAITaskParser(apiKey: "bad", session: stubSession).parse(lines: ["x"])
        }
        await #expect(throws: ClaudeParserError.http(429)) {
            try await OpenAITaskParser(apiKey: "busy", session: stubSession).parse(lines: ["x"])
        }
        await #expect(throws: ClaudeParserError.noCredit) {
            try await OpenAITaskParser(apiKey: "broke", session: stubSession).parse(lines: ["x"])
        }
        await #expect(throws: ClaudeParserError.timeout) {
            try await OpenAITaskParser(apiKey: "slow", session: stubSession).parse(lines: ["x"])
        }
    }

    @Test func openAIUsesTheSessionWithoutCache() {
        let parser = OpenAITaskParser(apiKey: "k")
        #expect(parser.session === ClaudeHTTP.session)
        #expect(parser.session.configuration.urlCache == nil)
    }

    // MARK: Who parses

    @Test func theSelectedProviderParsesWhenItHasAKey() {
        #expect(ParserProvider.active(selected: .claude, hasKey: { _ in true }) == .claude)
        #expect(ParserProvider.active(selected: .openAI, hasKey: { _ in true }) == .openAI)
        // Only the other key is stored: the text never goes to a provider that was not chosen.
        #expect(ParserProvider.active(selected: .openAI, hasKey: { $0 == .claude }) == nil)
        #expect(ParserProvider.active(selected: .claude, hasKey: { $0 == .openAI }) == nil)
        // No key at all: the plain tracker.
        #expect(ParserProvider.active(selected: .claude, hasKey: { _ in false }) == nil)
    }

    @Test func theChosenProviderWithoutAKeyIsReportedOnlyWhenAnotherKeyExists() {
        #expect(ParserProvider.missingKey(selected: .openAI, hasKey: { $0 == .claude }) == .openAI)
        #expect(ParserProvider.missingKey(selected: .claude, hasKey: { $0 == .openAI }) == .claude)
        // Nothing missing: it has its key, or there are no keys at all (the plain tracker by choice).
        #expect(ParserProvider.missingKey(selected: .openAI, hasKey: { _ in true }) == nil)
        #expect(ParserProvider.missingKey(selected: .openAI, hasKey: { _ in false }) == nil)
    }

    @Test func aChosenProviderWithoutAKeyKeepsTheLinesAndAsksToConnect() async {
        let lines = ["срочно оплатить интернет до 16"]
        let outcome = await ProviderParser.parse(lines: lines, provider: nil, apiKey: nil, model: "",
                                                 missingKey: .openAI, session: stubSession)
        #expect(outcome.result.tasks.map(\.task.title) == lines)
        #expect(outcome.result.tasks.first?.task.priority == .normal)
        #expect(outcome.parsedBy == nil)
        #expect(outcome.failure == .keyMissing)
        #expect(outcome.provider == .openAI)
        #expect(ClaudeFailure.keyMissing.message(for: .openAI) == "No ChatGPT key connected — kept the lines as written")
        #expect(ClaudeFailure.keyMissing.actionLabel == "Connect")
        #expect(!ClaudeFailure.keyMissing.retries)
    }

    @Test func providersHaveTheirNamesModelsAndKeychainItems() {
        #expect(ParserProvider.claude.label == "Claude")
        #expect(ParserProvider.openAI.label == "ChatGPT")
        #expect(ParserProvider.claude.defaultModel == "claude-haiku-5-5")
        #expect(ParserProvider.openAI.defaultModel == "gpt-4o-mini")
        #expect(ParserProvider.claude.keychainService == "Bubbles.ClaudeAPIKey")
        #expect(ParserProvider.openAI.keychainService == "Bubbles.OpenAIAPIKey")
    }

    // MARK: Without a key: lines as written

    @Test func plainLinesBecomeTasksExactlyAsWritten() {
        let lines = ["срочно оплатить интернет до 16", "  созвон с командой в 12 ", "", "купить продукты и забрать посылку"]
        let result = TaskParser.plain(lines: lines)
        #expect(result.tasks.map(\.task.title) == ["срочно оплатить интернет до 16", "созвон с командой в 12",
                                                    "купить продукты и забрать посылку"])
        #expect(result.tasks.map(\.sourceLine) == [0, 1, 3])
        #expect(result.tasks.allSatisfy { $0.task.priority == .normal && $0.task.dueMinutes == nil && $0.task.dueKind == nil })
        #expect(result.tasks.allSatisfy { $0.task.kind == .today && $0.task.note == nil })
        #expect(result.leftover.isEmpty)
    }

    @Test func noProviderMeansPlainAndNoFailure() async {
        let outcome = await ProviderParser.parse(lines: ["срочно оплатить интернет до 16"], provider: nil, apiKey: nil,
                                                 model: "", session: stubSession)
        #expect(outcome.result.tasks.map(\.task.title) == ["срочно оплатить интернет до 16"])
        #expect(outcome.result.tasks.first?.task.priority == .normal)
        #expect(outcome.parsedBy == nil)
        #expect(outcome.failure == nil)
    }

    @Test func aFailedAIKeepsTheLinesAndSaysWhy() async {
        let lines = ["срочно оплатить интернет до 16", "созвон в 12"]
        let wrong = await ProviderParser.parse(lines: lines, provider: .openAI, apiKey: "bad", model: "gpt-4o-mini",
                                               session: stubSession)
        #expect(wrong.result.tasks.map(\.task.title) == lines)
        #expect(wrong.result.tasks.allSatisfy { $0.task.priority == .normal && $0.task.dueMinutes == nil })
        #expect(wrong.failure == .invalidKey)
        #expect(wrong.parsedBy == nil)
        #expect(wrong.provider == .openAI)

        let offline = await ProviderParser.parse(lines: lines, provider: .openAI, apiKey: "offline", model: "gpt-4o-mini",
                                                 session: stubSession)
        #expect(offline.failure == .offline)
        #expect(offline.result.tasks.count == 2)

        // A key is stored but the Keychain did not hand it over.
        let unreadable = await ProviderParser.parse(lines: lines, provider: .claude, apiKey: nil, model: "claude-haiku-5-5",
                                                    session: stubSession)
        #expect(unreadable.failure == .keyUnreadable)
        #expect(unreadable.result.tasks.map(\.task.title) == lines)
    }

    @Test func aWorkingAIParses() async {
        let outcome = await ProviderParser.parse(lines: ["оплатить интернет до 16"], provider: .openAI, apiKey: "ok",
                                                 model: "gpt-4o-mini", session: stubSession)
        #expect(outcome.parsedBy == .openAI)
        #expect(outcome.failure == nil)
        #expect(outcome.result.tasks.first?.task.dueMinutes == 960)
    }

    // MARK: Failures read the same for both

    @Test func failuresAreClassifiedTheSameForBoth() {
        #expect(ClaudeFailure.classify(ClaudeParserError.noCredit) == .noCredit)
        #expect(ClaudeFailure.classify(ClaudeParserError.http(401)) == .invalidKey)
        #expect(ClaudeFailure.classify(URLError(.notConnectedToInternet)) == .offline)
    }

    @Test func failureTextsNameTheProvider() {
        #expect(ClaudeFailure.invalidKey.message(for: .openAI) == "The ChatGPT key doesn't work — kept the lines as written")
        #expect(ClaudeFailure.invalidKey.message(for: .claude) == "The Claude key doesn't work — kept the lines as written")
        #expect(ClaudeFailure.unavailable.message(for: .openAI) == "ChatGPT didn't answer — kept the lines as written")
        #expect(ClaudeFailure.offline.message(for: .openAI) == "No internet — kept the lines as written")
        #expect(ClaudeFailure.noCredit.message(for: .openAI) == "Your OpenAI account is out of credit — kept the lines as written")
        #expect(ClaudeFailure.noCredit.message(for: .claude) == "Your Anthropic account is out of credit — kept the lines as written")
        #expect(ClaudeFailure.keyUnreadable.message(for: .openAI).contains("ChatGPT"))
        #expect(ClaudeFailure.other.message(for: .openAI).contains("ChatGPT"))
        for failure in [ClaudeFailure.unavailable, .offline, .noCredit, .other] {
            #expect(failure.actionLabel == "Retry")
            #expect(failure.retries)
        }
        for failure in [ClaudeFailure.invalidKey, .keyUnreadable] {
            #expect(failure.actionLabel == "Change key")
            #expect(!failure.retries)
        }
    }

    // MARK: Key check

    @Test func openAIKeyCheckAsksForTheModelsList() {
        let request = ProviderKeyCheck.request(.openAI, apiKey: "  test-key\n")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request.timeoutInterval == 15)
        // Claude's check stays Claude's.
        #expect(ProviderKeyCheck.request(.claude, apiKey: "k").url == ClaudeKeyCheck.endpoint)
    }

    @Test func keyCheckStatusesNameTheProvider() {
        #expect(ProviderKeyCheck.status(.openAI, httpCode: 200) == .valid)
        #expect(ProviderKeyCheck.status(.openAI, httpCode: 401) == .invalid)
        #expect(ProviderKeyCheck.status(.openAI, httpCode: 403) == .invalid)
        guard case .unavailable(let why) = ProviderKeyCheck.status(.openAI, httpCode: 503) else {
            Issue.record("503 should be «unavailable»")
            return
        }
        #expect(why.contains("ChatGPT"))
        #expect(ClaudeKeyStatus.valid.message(for: .openAI) == "The key works — ChatGPT parses your tasks")
        #expect(ClaudeKeyStatus.valid.message(for: .claude) == ClaudeKeyStatus.valid.message)
    }

    // MARK: Settings

    @Test func providerAndModelsHaveDefaultsAndSurviveRestart() throws {
        let fresh = BubbleSettings()
        #expect(fresh.provider == .claude)
        #expect(fresh.model(for: .claude) == "claude-haiku-5-5")
        #expect(fresh.model(for: .openAI) == "gpt-4o-mini")

        // A save from before providers existed keeps working.
        let old = try JSONDecoder().decode(BubbleSettings.self, from: Data(#"{"roundness":40}"#.utf8))
        #expect(old.provider == .claude && old.model(for: .openAI) == "gpt-4o-mini")

        var changed = BubbleSettings()
        changed.provider = .openAI
        changed.openAIModel = "gpt-4.1-mini"
        let back = try JSONDecoder().decode(BubbleSettings.self, from: JSONEncoder().encode(changed))
        #expect(back.provider == .openAI)
        #expect(back.model(for: .openAI) == "gpt-4.1-mini")

        // A cleared field falls back to the default model.
        changed.openAIModel = "   "
        #expect(changed.model(for: .openAI) == "gpt-4o-mini")
    }
}
