import Foundation

/// One recognised word with its place in the audio, in seconds from the start of the recognizer session.
public struct SpokenWord: Equatable, Sendable, Codable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(_ text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }

    /// For recognizers whose partial results carry no timings (all zero): words that are unchanged at the
    /// same position keep their earlier times, new or revised words get `now` (seconds since the session start).
    /// The time a word first appeared stands in for when it was said, so pauses still split lines.
    public static func stamped(_ texts: [String], previous: [SpokenWord], now: TimeInterval) -> [SpokenWord] {
        texts.enumerated().map { i, text in
            if i < previous.count, Transcript.normalized(previous[i].text) == Transcript.normalized(text) {
                var kept = previous[i]
                kept.text = text
                return kept
            }
            return SpokenWord(text, start: now, end: now)
        }
    }
}

/// A voice command heard in the dictation. `deleteLast` is already applied to the transcript when reported.
public enum TranscriptCommand: Equatable, Sendable {
    /// "delete last" / «удали последнее»
    case deleteLast
    /// "done" / «готово»: stop listening.
    case finish
}

/// The dictation as lines, one future task per line. Accumulates recognizer output so that nothing said
/// is lost when the recognizer finalises a fragment, restarts after a pause, or is stopped mid-word.
///
/// Rules of the dictation transcript:
/// Rules of the dictation transcript (Russian and English commands both work):
/// - "next (task)", "another task", «дальше», «следующая (задача)», «ещё задача» start a new line and are not
///   written; "next" followed by a word like "week" or "Monday" stays part of the task;
/// - "delete (the) last (one)", "scratch that", «удали последнее» erase the line being spoken, or the previous
///   line if the current one is empty;
/// - "done" (at the start of a line, or "all done" / "I'm done") and «готово» finish; later speech is ignored.
/// Commands are executed only in final words; the volatile tail is shown with the same rules.
public struct Transcript: Equatable, Sendable {
    public static let pauseThreshold: TimeInterval = 0.8

    /// Lines already closed.
    private var closed: [String]
    /// Words of the line being spoken.
    private var open: [String] = []
    /// End of the last final word, to measure the pause before the next one.
    private var lastEnd: TimeInterval?
    /// The recognizer's current, still revisable hypothesis.
    private var volatile: [SpokenWord] = []

    public private(set) var isFinished = false

    public init(lines: [String] = []) {
        closed = Self.clean(lines)
    }

    /// Everything heard, final and volatile, as display lines.
    public var lines: [String] {
        var preview = self
        preview.volatile = []
        preview.apply(volatile)
        return preview.closed + (preview.open.isEmpty ? [] : [Self.lineText(preview.open)])
    }

    /// Lines joined by newlines: the text handed to the parser.
    public var text: String { lines.joined(separator: "\n") }

    /// The recognizer's latest hypothesis for audio it has not finalised; replaces the previous one.
    public mutating func update(volatile words: [SpokenWord]) {
        volatile = words
    }

    /// Words the recognizer will not revise any more. Clears the volatile tail.
    @discardableResult
    public mutating func commit(_ words: [SpokenWord]) -> [TranscriptCommand] {
        volatile = []
        return apply(words)
    }

    /// Stop / pause: the volatile tail is kept as if it were final.
    @discardableResult
    public mutating func commitVolatile() -> [TranscriptCommand] {
        commit(volatile)
    }

    /// For recognizers that report the whole text since their last reset (`SFSpeechRecognizer`).
    /// A hypothesis that starts after the previous one ended means the recognizer began a new fragment:
    /// the previous hypothesis is committed instead of being overwritten.
    @discardableResult
    public mutating func receiveHypothesis(_ words: [SpokenWord], isFinal: Bool) -> [TranscriptCommand] {
        var commands: [TranscriptCommand] = []
        if let previousStart = volatile.first?.start, let previousEnd = volatile.last?.end, let first = words.first,
           first.start > previousStart + 0.01, first.start >= previousEnd - 0.01 {
            commands += commitVolatile()
        }
        if isFinal {
            commands += commit(words)
        } else {
            update(volatile: words)
        }
        return commands
    }

    /// A new recognizer session (its clock restarts at zero): the open line is closed.
    public mutating func beginSession() {
        commitVolatile()
        closeLine()
        lastEnd = nil
        isFinished = false
    }

    /// The person edited the transcript by hand.
    public mutating func replaceLines(_ lines: [String]) {
        closed = Self.clean(lines)
        open = []
        volatile = []
    }

    public mutating func removeLastLine() {
        if !open.isEmpty { open = [] } else { _ = closed.popLast() }
    }

    // MARK: - Internals

    @discardableResult
    private mutating func apply(_ words: [SpokenWord]) -> [TranscriptCommand] {
        var commands: [TranscriptCommand] = []
        var i = 0
        while i < words.count, !isFinished {
            let word = words[i]
            if let lastEnd, word.start - lastEnd > Self.pauseThreshold { closeLine() }
            lastEnd = max(word.end, word.start)

            let key = Self.normalized(word.text)
            let next = i + 1 < words.count ? Self.normalized(words[i + 1].text) : nil
            switch key {
            case "дальше":
                closeLine()
            case "next" where !Self.keptAfterNext.contains(next ?? ""):
                closeLine()
                if next == "task" || next == "one" { i += 1 }
            case "another" where next == "task":
                closeLine()
                i += 1
            case "следующая":
                closeLine()
                if next == "задача" { i += 1 }
            case "еще" where next == "задача":
                closeLine()
                i += 1
            case _ where Self.deleteWords.contains(key) && next.map(Self.lastWords.contains) == true:
                removeLastLine()
                commands.append(.deleteLast)
                i += 1
                if i + 1 < words.count, Self.deleteTrailers.contains(Self.normalized(words[i + 1].text)) { i += 1 }
            case _ where Self.deleteWords.contains(key) && next == "the" && i + 2 < words.count
                && Self.lastWords.contains(Self.normalized(words[i + 2].text)):
                removeLastLine()
                commands.append(.deleteLast)
                i += 2
                if i + 1 < words.count, Self.deleteTrailers.contains(Self.normalized(words[i + 1].text)) { i += 1 }
            case "scratch" where next == "that":
                removeLastLine()
                commands.append(.deleteLast)
                i += 1
            case "done" where open.isEmpty || (open.count == 1 && Self.beforeDone.contains(Self.normalized(open[0]))):
                open = []
                isFinished = true
                commands.append(.finish)
            case "готово":
                closeLine()
                isFinished = true
                commands.append(.finish)
            case "":
                break
            default:
                open.append(word.text)
            }
            if i < words.count { lastEnd = max(lastEnd ?? 0, words[i].end) }
            i += 1
        }
        return commands
    }

    private static let deleteWords: Set<String> = ["удали", "удалить", "сотри", "стереть", "delete", "remove", "erase"]
    private static let lastWords: Set<String> = ["последнее", "последнюю", "последний", "last"]
    private static let deleteTrailers: Set<String> = ["строку", "задачу", "one", "line", "task"]
    /// "all done", "I'm done": the word before "done" goes with it.
    private static let beforeDone: Set<String> = ["all", "i'm", "i’m", "im"]
    /// "next week", "next Monday": a task, not the separator.
    private static let keptAfterNext: Set<String> = [
        "week", "month", "year", "weekend", "time", "day", "morning", "evening", "step", "steps", "door",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    private mutating func closeLine() {
        let text = Self.lineText(open)
        if !text.isEmpty { closed.append(text) }
        open = []
    }

    private static func lineText(_ words: [String]) -> String {
        words.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…—-")))
    }

    private static func clean(_ lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Lowercased, without surrounding punctuation, «ё» as «е»: for matching command words.
    static func normalized(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols))
    }
}

/// The dictation saved while it is going on, so a closed panel or a crash does not lose it.
public struct TranscriptDraft: Codable, Equatable, Sendable {
    public var lines: [String]
    public var savedAt: Date

    public init(lines: [String], savedAt: Date) {
        self.lines = lines
        self.savedAt = savedAt
    }
}

/// `~/Library/Application Support/Bubbles/dictation-draft.json`. Saving no lines removes the file;
/// a missing or corrupt file reads as no draft.
public struct TranscriptDraftStore: Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        DataFolder.url.appendingPathComponent("dictation-draft.json")
    }

    public init(fileURL: URL = TranscriptDraftStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func save(_ lines: [String], at date: Date = Date()) {
        let kept = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !kept.isEmpty else { return clear() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(TranscriptDraft(lines: kept, savedAt: date)) else { return }
        // Temp file next to the target + rename(2): Foundation's `.atomic` stages files in a system temp
        // folder, which restricted sandboxes deny.
        let folder = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: temp)
            if rename(temp.path, fileURL.path) != 0 { try? FileManager.default.removeItem(at: temp) }
        } catch {
            // Not writable: the draft lives on in memory; the next save retries.
        }
    }

    public func load() -> TranscriptDraft? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let draft = try? decoder.decode(TranscriptDraft.self, from: data), !draft.lines.isEmpty else { return nil }
        return draft
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
