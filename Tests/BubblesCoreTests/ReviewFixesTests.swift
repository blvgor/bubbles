import Foundation
import Testing
import BubblesCore

/// The branch review's fixes: key never cached on disk, Claude failures told apart, the takeover lock,
/// the surfaced bubble's choices, an unreadable state file kept aside, "Reset data" clearing everything.
@MainActor @Suite struct ReviewFixesTests {
    let folder: URL

    init() {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        folder = tmp.appendingPathComponent("bubbles-review-\(UUID().uuidString)", isDirectory: true)
    }

    private var stateURL: URL { folder.appendingPathComponent("state.json") }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: Security

    @Test func keyRequestsGoThroughASessionWithoutDiskCache() {
        let config = ClaudeHTTP.session.configuration
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(ClaudeTaskParser(apiKey: "test-key").session === ClaudeHTTP.session)
    }

    // MARK: Claude failures

    @Test func claudeFailuresAreToldApart() {
        #expect(ClaudeFailure.classify(ClaudeParserError.http(401)) == .invalidKey)
        #expect(ClaudeFailure.classify(ClaudeParserError.http(403)) == .invalidKey)
        #expect(ClaudeFailure.classify(ClaudeParserError.http(429)) == .unavailable)
        #expect(ClaudeFailure.classify(ClaudeParserError.http(529)) == .unavailable)
        #expect(ClaudeFailure.classify(ClaudeParserError.http(503)) == .unavailable)
        #expect(ClaudeFailure.classify(ClaudeParserError.timeout) == .unavailable)
        #expect(ClaudeFailure.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(ClaudeFailure.classify(URLError(.networkConnectionLost)) == .offline)
        #expect(ClaudeFailure.classify(URLError(.cannotFindHost)) == .offline)
        #expect(ClaudeFailure.classify(ClaudeParserError.badResponse) == .other)
    }

    @Test func claudeFailureTextsAreTheSpecOnes() {
        // Spec 45: on an AI failure the lines become tasks as written, and the banner says why.
        #expect(ClaudeFailure.invalidKey.message == "The Claude key doesn't work — kept the lines as written")
        #expect(ClaudeFailure.invalidKey.actionLabel == "Change key")
        #expect(ClaudeFailure.unavailable.message == "Claude didn't answer — kept the lines as written")
        #expect(ClaudeFailure.unavailable.actionLabel == "Retry")
        #expect(ClaudeFailure.offline.message == "No internet — kept the lines as written")
        let unreadable = ClaudeFailure.keyUnreadable.message
        #expect(!unreadable.isEmpty)
        #expect(unreadable != ClaudeFailure.invalidKey.message && unreadable != ClaudeFailure.unavailable.message)
        #expect(!ClaudeFailure.keyUnreadable.actionLabel.isEmpty)
    }

    // MARK: Takeover lock

    @Test func aTaskUnderTakeoverIsNotRemoved() {
        #expect(TakeoverLock.refusal == "The takeover has started — this task can only be closed or burned")
        #expect(TakeoverLock.refuses(onDesk: true, canMoveToTomorrow: false))
        #expect(!TakeoverLock.refuses(onDesk: true, canMoveToTomorrow: true))
        // A row that came from the dictation is not on the desk yet: nothing to protect.
        #expect(!TakeoverLock.refuses(onDesk: false, canMoveToTomorrow: false))
    }

    // MARK: Surface

    @Test func surfacedBubbleOffersQuarterAndHour() {
        #expect(SurfaceSnooze.allCases.map(\.label) == ["In 15 min", "In 1 hour"])
        #expect(SurfaceSnooze.allCases.map(\.minutes) == [15, 60])
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(SurfaceSnooze.hour.until(now) == now.addingTimeInterval(3600))
        #expect(SurfaceSnooze.outsideClick.until(now) == now.addingTimeInterval(15 * 60))
    }

    // MARK: State file

    @Test func unreadableStateIsSetAsideBeforeTheFirstWrite() throws {
        let garbage = "{\"day\": not json at all"
        try write(garbage, to: stateURL)
        let store = TaskStore(fileURL: stateURL)
        #expect(store.tasks.isEmpty)
        store.add([DayTask(title: "Pay the internet bill")])
        let bad = folder.appendingPathComponent("state.json.bad")
        #expect(String(decoding: try Data(contentsOf: bad), as: UTF8.self) == garbage)
        #expect(TaskStore(fileURL: stateURL).tasks.map(\.title) == ["Pay the internet bill"])
    }

    @Test func missingFieldsReadAsDefaults() throws {
        // An older file: no `burnedToday`, no `history`.
        let id = UUID()
        let json = """
        {"day": 0, "doneToday": 2, "streak": 5,
         "tasks": [{"id": "\(id.uuidString)", "title": "Renew passport", "priority": 2, "kind": "today", "createdAt": 0}]}
        """
        try write(json, to: stateURL)
        let store = TaskStore(fileURL: stateURL)
        #expect(store.tasks.map(\.id) == [id])
        #expect(store.doneToday == 2)
        #expect(store.streak == 5)
        #expect(store.history.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("state.json.bad").path))
    }

    // MARK: Reset

    @Test func resetRemovesTheWholeDataFolder() throws {
        try write("{}", to: stateURL)
        try write("{}", to: folder.appendingPathComponent("dictation-draft.json"))
        try write("x", to: folder.appendingPathComponent("state.json.bad"))
        try TaskStore.removeAllData(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(TaskStore.dataFolder == TaskStore.defaultURL.deletingLastPathComponent())
        #expect(TranscriptDraftStore.defaultURL.deletingLastPathComponent() == TaskStore.dataFolder)
    }
}
