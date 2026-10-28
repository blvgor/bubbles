import Foundation
import Testing
import BubblesCore

/// Answers requests without the network: the API key header picks the canned response.
final class StubAnthropic: URLProtocol, @unchecked Sendable {
    static let okBody = ClaudeTaskParserTests.messagesResponse(text: #"[{"title":"Оплатить интернет","priority":3,"time":"16:00","kind":"by"}]"#)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "x-api-key") ?? ""
        if key == "slow" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = key == "bad" ? 401 : (key == "busy" ? 529 : 200)
        let body = status == 200 ? Self.okBody : Data(#"{"type":"error"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite struct ClaudeTaskParserTests {
    static func messagesResponse(text: String) -> Data {
        let object: [String: Any] = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-haiku-5-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private var stubSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubAnthropic.self]
        return URLSession(configuration: config)
    }

    @Test func requestTargetsMessagesAPIWithKeyOnlyInHeader() throws {
        let key = "sk-test-not-a-real-key"
        let request = ClaudeTaskParser.request(for: "оплатить интернет до 16", apiKey: key, model: "claude-haiku-5-5", now: Date())
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == key)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.timeoutInterval == 15)

        let body = try #require(request.httpBody)
        #expect(!String(decoding: body, as: UTF8.self).contains(key))
        #expect(!(request.url?.absoluteString.contains(key) ?? true))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect((json["max_tokens"] as? Int ?? 0) > 0)
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "user")
        #expect((messages.first?["content"] as? String)?.contains("оплатить интернет до 16") == true)
    }

    @Test func decodesTaskArray() throws {
        let text = #"[{"title":"Отправить счёт клиенту","priority":3,"time":"18:00","kind":"by"},{"title":"Созвон с командой","priority":2,"time":"12:30","kind":"at"},{"title":"Купить хлеб","priority":1,"time":null,"kind":null}]"#
        let tasks = try ClaudeTaskParser.decode(Self.messagesResponse(text: text))
        #expect(tasks.map(\.title) == ["Отправить счёт клиенту", "Созвон с командой", "Купить хлеб"])
        #expect(tasks.map(\.priority) == [.urgent, .important, .normal])
        #expect(tasks.map(\.dueMinutes) == [1080, 750, nil])
        #expect(tasks.map(\.dueKind) == [.deadline, .at, nil])
        #expect(tasks.allSatisfy { $0.kind == .today })
    }

    @Test func decodesArrayWrappedInJsonFence() throws {
        let text = "Here are the tasks:\n```json\n[{\"title\":\"Записаться к стоматологу\",\"priority\":2,\"time\":null,\"kind\":null}]\n```"
        let tasks = try ClaudeTaskParser.decode(Self.messagesResponse(text: text))
        #expect(tasks.map(\.title) == ["Записаться к стоматологу"])
        #expect(tasks.first?.priority == .important)
    }

    @Test func decodesLongFlagIntoMultiDayTask() throws {
        let text = #"[{"title":"Сделать ремонт на балконе","priority":1,"time":null,"kind":null,"long":true},{"title":"Купить хлеб","priority":1,"time":null,"kind":null,"long":false}]"#
        let tasks = try ClaudeTaskParser.decode(Self.messagesResponse(text: text))
        #expect(tasks.map(\.kind) == [.long, .today])
        #expect(tasks.map(\.note) == ["long · day 1", nil])
    }

    @Test func promptAsksForTheLongFlag() throws {
        let request = ClaudeTaskParser.request(for: "x", apiKey: "k", model: "claude-haiku-5-5", now: Date())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(json["system"] as? String)
        #expect(system.contains("\"long\""))
        #expect(system.contains("на несколько дней") && system.contains("for a few days"))
        // Titles stay in the language they were spoken in.
        #expect(system.contains("never translate"))
    }

    // MARK: Numbered lines → tasks with their source line + leftover

    @Test func requestSendsNumberedLinesAndAsksForLineAndLeftover() throws {
        let lines = ["срочно оплатить интернет до 16", "созвон с командой в 12", "ну вроде всё"]
        let request = ClaudeTaskParser.request(for: lines, apiKey: "k", model: "claude-haiku-5-5", now: Date())
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "1. срочно оплатить интернет до 16\n2. созвон с командой в 12\n3. ну вроде всё")
        let system = try #require(json["system"] as? String)
        #expect(system.contains("\"line\""))
        #expect(system.contains("\"leftover\""))
        #expect((json["max_tokens"] as? Int ?? 0) >= 4096)
    }

    @Test func decodesTasksWithSourceLineAndLeftover() throws {
        let lines = ["срочно оплатить интернет до 16", "купить продукты и забрать посылку", "ну вроде всё"]
        let text = #"{"tasks":[{"line":1,"title":"Оплатить интернет","priority":3,"time":"16:00","kind":"by","long":false},{"line":2,"title":"Купить продукты","priority":1,"time":null,"kind":null,"long":false},{"line":2,"title":"Забрать посылку","priority":1,"time":null,"kind":null,"long":false}],"leftover":[3]}"#
        let result = try ClaudeTaskParser.decode(Self.messagesResponse(text: text), lines: lines)
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет", "Купить продукты", "Забрать посылку"])
        #expect(result.tasks.map(\.sourceLine) == [0, 1, 1])
        #expect(result.tasks.first?.task.dueMinutes == 960)
        #expect(result.leftover == ["ну вроде всё"])
    }

    @Test func lineClaudeSkippedIsNotLostButLandsInLeftover() throws {
        let lines = ["купить хлеб", "позвонить в банк", "записаться к стоматологу"]
        let text = "```json\n" + #"{"tasks":[{"line":1,"title":"Купить хлеб","priority":1,"time":null,"kind":null},{"line":3,"title":"Записаться к стоматологу","priority":1,"time":null,"kind":null}],"leftover":["and one more thing"]}"# + "\n```"
        let result = try ClaudeTaskParser.decode(Self.messagesResponse(text: text), lines: lines)
        #expect(result.tasks.map(\.sourceLine) == [0, 2])
        #expect(result.leftover == ["and one more thing", "позвонить в банк"])
    }

    @Test func parseLinesReturnsResultOnSuccess() async throws {
        let parser = ClaudeTaskParser(apiKey: "ok", session: stubSession)
        let result = try await parser.parse(lines: ["оплатить интернет до 16"])
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет"])
    }

    @Test func garbageIsBadResponse() {
        #expect(throws: ClaudeParserError.self) { try ClaudeTaskParser.decode(Data("not json".utf8)) }
        #expect(throws: ClaudeParserError.self) {
            try ClaudeTaskParser.decode(Self.messagesResponse(text: "Sorry, I didn't understand"))
        }
        #expect(throws: ClaudeParserError.self) {
            try ClaudeTaskParser.decode(Self.messagesResponse(text: #"[{"name":"untitled"}]"#))
        }
    }

    @Test func parseReturnsTasksOnSuccess() async throws {
        let parser = ClaudeTaskParser(apiKey: "ok", session: stubSession)
        let tasks = try await parser.parse("оплатить интернет до 16")
        #expect(tasks.map(\.title) == ["Оплатить интернет"])
        #expect(tasks.first?.dueMinutes == 960)
    }

    @Test func httpErrorsBecomeTypedErrors() async {
        let unauthorized = ClaudeTaskParser(apiKey: "bad", session: stubSession)
        do { _ = try await unauthorized.parse("x"); Issue.record("expected an error") }
        catch let error as ClaudeParserError {
            guard case .http(401) = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("untyped error \(error)") }

        let overloaded = ClaudeTaskParser(apiKey: "busy", session: stubSession)
        do { _ = try await overloaded.parse("x"); Issue.record("expected an error") }
        catch let error as ClaudeParserError {
            guard case .http(529) = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("untyped error \(error)") }
    }

    @Test func timeoutBecomesTimeoutError() async {
        let parser = ClaudeTaskParser(apiKey: "slow", session: stubSession)
        do { _ = try await parser.parse("x"); Issue.record("expected an error") }
        catch let error as ClaudeParserError {
            guard case .timeout = error else { Issue.record("got \(error)"); return }
        } catch { Issue.record("untyped error \(error)") }
    }
}
