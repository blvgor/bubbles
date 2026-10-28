import Foundation

/// A task from the parser with the transcript line it came from.
public struct ParsedTask: Equatable, Sendable {
    public var task: DayTask
    /// Index (0-based) of the line in the `lines` handed to the parser; nil when the source is unknown.
    public var sourceLine: Int?

    public init(task: DayTask, sourceLine: Int?) {
        self.task = task
        self.sourceLine = sourceLine
    }
}

/// What a parser made of the transcript: tasks in spoken order, and everything that did not become a task
/// ("Unparsed"), so no line disappears silently.
public struct TaskParseResult: Equatable, Sendable {
    public var tasks: [ParsedTask]
    /// Lines (or parts of lines) that are not tasks, in spoken order.
    public var leftover: [String]

    public init(tasks: [ParsedTask] = [], leftover: [String] = []) {
        self.tasks = tasks
        self.leftover = leftover
    }

    public var dayTasks: [DayTask] { tasks.map(\.task) }
}

/// Local, offline parser by rules: the "All tasks" add field and rows typed into "Got it".
/// Dictation without an AI key uses `plain(lines:)` instead.
/// Started as a port of `parse()` from `prototype/index.html`; now works line by line: one transcript line
/// gives at least one task, and a line is further cut before Russian infinitives and at "(and) then", "also",
/// "secondly" (and the Russian «и потом», «ещё», «во-вторых»). Russian and English keywords are both understood;
/// a title keeps the language it was spoken in.
public enum TaskParser {
    /// No AI key (or the AI failed): every non-empty line is one task exactly as written — no time, no
    /// urgency ("Normal"), no rewording; the person sets those in the editor.
    public static func plain(lines: [String], now: Date = Date()) -> TaskParseResult {
        var result = TaskParseResult()
        for (index, line) in lines.enumerated() {
            let title = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            result.tasks.append(ParsedTask(task: DayTask(title: title, createdAt: now), sourceLine: index))
        }
        return result
    }

    /// Free text: each newline-separated line is parsed as in `parse(lines:)`.
    public static func parse(_ text: String, now: Date = Date()) -> [DayTask] {
        parse(lines: text.components(separatedBy: .newlines), now: now).dayTasks
    }

    public static func parse(lines: [String], now: Date = Date()) -> TaskParseResult {
        var result = TaskParseResult()
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var made: [DayTask] = []
            var dropped: [String] = []
            for fragment in fragments(of: spokenTimesAsDigits(trimmed)) {
                if let task = task(from: fragment, now: now) {
                    made.append(task)
                } else {
                    dropped.append(fragment.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if made.isEmpty {
                result.leftover.append(trimmed)
            } else {
                result.tasks += made.map { ParsedTask(task: $0, sourceLine: index) }
                // Fillers like "so" / «так» are dropped quietly; a phrase of two or more words is shown as leftover.
                result.leftover += dropped.filter { $0.split(separator: " ").count >= 2 }
            }
        }
        return result
    }

    // MARK: - One fragment → one task

    private static func task(from raw: String, now: Date) -> DayTask? {
        var s = " " + raw.trimmingCharacters(in: .whitespacesAndNewlines) + " "
        var priority = Priority.normal
        var kind = TaskKind.today

        if Patterns.long.matches(s) {
            kind = .long
            s = Patterns.long.replacingAll(in: s, with: " ")
        }

        if Patterns.urgent.matches(s) {
            priority = .urgent
            s = Patterns.urgent.replacingAll(in: s, with: " ")
        } else if Patterns.important.matches(s) {
            priority = .important
            s = Patterns.important.replacingAll(in: s, with: " ")
        }

        var due: Int?
        var dueKind: DueKind?
        if let hit = time(in: s, pattern: Patterns.deadline, now: now) ?? time(in: s, pattern: Patterns.at, now: now) {
            due = hit.minutes
            dueKind = hit.kind
            s = (s as NSString).replacingCharacters(in: hit.range, with: " ")
            if priority.rawValue < Priority.important.rawValue { priority = .important }
        }

        s = Patterns.spaces.replacingAll(in: s, with: " ").trimmingCharacters(in: .whitespaces)
        var previous: String
        repeat {
            previous = s
            s = Patterns.filler.replacingFirst(in: s, with: "")
        } while s != previous

        if s.count < 3 || Patterns.bare.matches(s) || isChatter(s) { return nil }
        let title = s.prefix(1).uppercased() + s.dropFirst()
        return DayTask(title: title, priority: priority, dueMinutes: due, dueKind: dueKind, kind: kind,
                       note: kind == .long ? LongTask.firstDayNote : nil, createdAt: now)
    }

    // MARK: - Cutting a line

    /// Cuts on `, ; . `, "(and) then" / «(и) потом», «и» before an infinitive (the prototype's rules), then inside
    /// each piece before a further infinitive and at "also" / «ещё», "firstly / secondly…" / «во-первых / во-вторых…».
    /// A dot between digits ("16.30") is part of a time, not a separator.
    static func fragments(of text: String) -> [String] {
        let ns = text as NSString
        var pieces: [String] = []
        var start = 0
        for match in Patterns.separator.regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces.flatMap(cutAtVerbs).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// A new fragment starts at an infinitive when the current one already has an infinitive with at least
    /// one word after it («оплатить интернет | купить продукты»), so «надо позвонить», «начать бегать» stay whole.
    /// English has no such marker, so English lines are cut only at separators and markers.
    private static func cutAtVerbs(_ piece: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var verbAt: Int?
        func close() {
            if !current.isEmpty { out.append(current.joined(separator: " ")) }
            current = []
            verbAt = nil
        }
        for word in piece.split(whereSeparator: \.isWhitespace).map(String.init) {
            let key = Transcript.normalized(word)
            if ordinalMarkers.contains(key) { close(); continue }
            if key == "еще" || key == "also" { close(); continue }
            if isInfinitive(key) {
                if let at = verbAt, current.count > at + 1 { close() }
                if verbAt == nil { verbAt = current.count }
            }
            current.append(word)
        }
        close()
        return out
    }

    private static let ordinalMarkers: Set<String> = [
        "во-первых", "во-вторых", "в-третьих", "в-четвертых", "в-пятых", "первое", "второе", "третье",
        "firstly", "secondly", "thirdly",
    ]

    /// Russian infinitive by its ending: -ть after a vowel, -ться, -ти(сь) of motion verbs, -чь of a few verbs.
    /// Nouns and numerals with the same endings are excluded.
    static func isInfinitive(_ word: String) -> Bool {
        guard word.count >= 4, !notInfinitives.contains(word), !word.hasSuffix("дцать") else { return false }
        if word.hasSuffix("ться") || word.hasSuffix("тись") { return true }
        if sibilantInfinitives.contains(word) { return true }
        if word.hasSuffix("чь") { return ["мочь", "печь", "лечь", "влечь", "беречь", "стричь", "жечь"].contains { word.hasSuffix($0) } }
        if word.hasSuffix("ти") {
            if word.hasSuffix("йти") || word.hasSuffix("зти") || word.hasSuffix("расти") { return true }
            return word.hasSuffix("сти") && !word.hasSuffix("ости") && !word.hasSuffix("асти")
        }
        guard word.hasSuffix("ть") else { return false }
        let beforeEnding = word.dropLast(2).last
        return beforeEnding.map { "аеёиоуыэюя".contains($0) } ?? false
    }

    /// -сть verbs (the general rule wants a vowel before -ть).
    private static let sibilantInfinitives: Set<String> = [
        "есть", "съесть", "поесть", "сесть", "присесть", "класть", "упасть", "попасть", "украсть",
        "прочесть", "учесть", "перечесть",
    ]

    private static let notInfinitives: Set<String> = [
        "кровать", "печать", "мать", "пять", "опять", "десять", "девять", "память", "благодать", "сеть", "треть",
        "плеть", "нить", "путь", "суть", "ртуть", "жуть", "муть", "чуть", "хоть", "плоть", "ноготь", "локоть",
        "зять", "рать", "кости", "гости", "сети", "дети", "пути",
    ]

    /// A fragment made only of chatter words ("so I guess that's all", «ну вроде всё») is not a task.
    private static func isChatter(_ s: String) -> Bool {
        s.split(whereSeparator: \.isWhitespace).allSatisfy { chatter.contains(Transcript.normalized(String($0))) }
    }

    private static let chatter: Set<String> = [
        "ну", "вроде", "все", "так", "короче", "ладно", "итак", "это", "наверное", "наверно", "пожалуй", "вот", "как",
        "бы", "типа", "да", "нет", "ага", "окей", "хорошо", "пока", "и", "а", "в", "общем", "целом", "значит", "кажется",
        "всего", "задача", "задачу", "задачи", "дальше", "следующая", "еще", "сегодня", "мне", "надо", "нужно", "вообще",
        "so", "well", "okay", "ok", "um", "uh", "yeah", "yes", "no", "right", "alright", "and", "then", "also", "next",
        "today", "i", "need", "to", "task", "basically", "like", "that's", "thats", "all", "it", "guess", "think",
        "anyway", "everything", "that", "is", "for", "now", "the", "a",
    ]

    // MARK: - Times

    /// «до шестнадцати», «в двенадцать тридцать», «к девяти» → «до 16», «в 12:30», «к 9»
    /// (Russian speech recognition often writes hours as words). Also "4 p.m." → "4 pm", so the dots do not cut it.
    static func spokenTimesAsDigits(_ text: String) -> String {
        var words = Patterns.meridiem.replacingAll(in: text, with: "$1m").split(whereSeparator: \.isWhitespace).map(String.init)
        var i = 0
        while i + 1 < words.count {
            guard ["до", "к", "в", "ко"].contains(Transcript.normalized(words[i])),
                  let (hour, used) = number(in: words, at: i + 1, table: hourWords), hour < 24 else {
                i += 1
                continue
            }
            var replacement = String(hour)
            var consumed = used
            if let (minute, more) = number(in: words, at: i + 1 + used, table: minuteWords), minute < 60 {
                replacement += String(format: ":%02d", minute)
                consumed += more
            }
            // Keep punctuation glued to the last spoken number word («шестнадцати,»).
            let last = words[i + consumed]
            let tail = String(last.reversed().prefix { !$0.isLetter }.reversed())
            words.replaceSubrange((i + 1)...(i + consumed), with: [replacement + tail])
            i += 2
        }
        return words.joined(separator: " ")
    }

    /// Longest match of one or two words in `table` starting at `index`: (value, words used).
    private static func number(in words: [String], at index: Int, table: [String: Int]) -> (Int, Int)? {
        guard index < words.count else { return nil }
        let first = Transcript.normalized(words[index])
        if index + 1 < words.count, let tens = table[first], tens >= 20, tens % 10 == 0,
           let unit = table[Transcript.normalized(words[index + 1])], unit < 10 {
            return (tens + unit, 2)
        }
        return table[first].map { ($0, 1) }
    }

    private static let hourWords: [String: Int] = {
        var table: [String: Int] = [:]
        let forms: [(Int, [String])] = [
            (1, ["один", "одного"]), (2, ["два", "двух"]), (3, ["три", "трех"]), (4, ["четыре", "четырех"]),
            (5, ["пять", "пяти"]), (6, ["шесть", "шести"]), (7, ["семь", "семи"]), (8, ["восемь", "восьми"]),
            (9, ["девять", "девяти"]), (10, ["десять", "десяти"]), (11, ["одиннадцать", "одиннадцати"]),
            (12, ["двенадцать", "двенадцати"]), (13, ["тринадцать", "тринадцати"]), (14, ["четырнадцать", "четырнадцати"]),
            (15, ["пятнадцать", "пятнадцати"]), (16, ["шестнадцать", "шестнадцати"]), (17, ["семнадцать", "семнадцати"]),
            (18, ["восемнадцать", "восемнадцати"]), (19, ["девятнадцать", "девятнадцати"]), (20, ["двадцать", "двадцати"]),
        ]
        for (value, words) in forms { for w in words { table[w] = value } }
        return table
    }()

    private static let minuteWords: [String: Int] = {
        var table: [String: Int] = [:]
        let forms: [(Int, [String])] = [
            (5, ["пять", "пяти"]), (10, ["десять", "десяти"]), (15, ["пятнадцать", "пятнадцати"]),
            (20, ["двадцать", "двадцати"]), (30, ["тридцать", "тридцати"]), (40, ["сорок", "сорока"]),
            (50, ["пятьдесят", "пятидесяти"]),
        ]
        for (value, words) in forms { for w in words { table[w] = value } }
        return table
    }()

    /// Groups of `Patterns.deadline` / `Patterns.at`: 1 keyword, 2 hour, 3 minutes, 4 am/pm.
    /// An English time without am/pm that already passed today reads as pm ("by 5" at 14:00 → 17:00).
    private static func time(in s: String, pattern: Pattern, now: Date) -> (minutes: Int, kind: DueKind, range: NSRange)? {
        let ns = s as NSString
        guard let m = pattern.regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              var hour = Int(ns.substring(with: m.range(at: 2))) else { return nil }
        let minute = m.range(at: 3).location == NSNotFound ? 0 : (Int(ns.substring(with: m.range(at: 3))) ?? 0)
        let meridiem = m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4)).lowercased()
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm", hour < 12 { hour += 12 }
            if meridiem == "am", hour == 12 { hour = 0 }
        } else if ns.substring(with: m.range(at: 1)).first?.isASCII == true, (1..<12).contains(hour), minute < 60 {
            let nowMinutes = Ranker.minutesSinceMidnight(now)
            if hour * 60 + minute <= nowMinutes, (hour + 12) * 60 + minute > nowMinutes { hour += 12 }
        }
        guard hour < 24, minute < 60 else { return nil }
        return (hour * 60 + minute, pattern === Patterns.deadline ? .deadline : .at, m.range)
    }
}

/// A compiled, case-insensitive regular expression. Immutable after init, so safe to share.
final class Pattern: Sendable {
    let regex: NSRegularExpression
    init(_ pattern: String) {
        // The patterns are literals below; a typo is a programmer error caught by the tests.
        regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    private func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: whole(s)) != nil }
    func replacingAll(in s: String, with t: String) -> String {
        regex.stringByReplacingMatches(in: s, range: whole(s), withTemplate: t)
    }
    func replacingFirst(in s: String, with t: String) -> String {
        guard let m = regex.firstMatch(in: s, range: whole(s)) else { return s }
        return (s as NSString).replacingCharacters(in: m.range, with: t)
    }
}

private enum Patterns {
    static let separator = Pattern(#"[,;\n]+|(?<!\d)\.+|\.+(?!\d)|\s(?:и\s)?потом\s|\s(?:and\s)?then\s|\sи\s(?=[а-яё]+(?:ть|ться|ти)(?:\s|$))"#)
    static let urgent = Pattern(#"\s(?:срочно|обязательно|urgent|urgently|asap|right\s+away)\s"#)
    /// «длинная / долгая (задача)», «на несколько дней», «на неделю», "long task", "for a few days",
    /// "this week" → a multi-day task.
    static let long = Pattern(#"\s(?:(?:длинная|длинную|долгая|долгую)(?:\s+задача|\s+задачу)?|на\s+несколько\s+дней|на\s+неделю|(?:a\s+)?long\s+task|multi-?day|for\s+(?:a\s+few|several)\s+days|for\s+a\s+week|this\s+week)\s"#)
    static let important = Pattern(#"\s(?:важно|главное|important|high\s+priority)\s"#)
    static let deadline = Pattern(#"\s(до|к|by|before|until|till)\s(\d{1,2})(?:[:.](\d{2}))?(?:\s?(?:час\S*|o'?clock))?(?:\s?(am|pm))?(?=\s)"#)
    static let at = Pattern(#"\s(в|at)\s(\d{1,2})(?:[:.](\d{2}))?(?:\s?(?:час\S*|o'?clock))?(?:\s?(am|pm))?(?=\s)"#)
    static let meridiem = Pattern(#"\b([ap])\.\s?m\b\.?"#)
    static let spaces = Pattern(#"\s+"#)
    static let filler = Pattern(#"^(?:так|ну|короче|ладно|сегодня|мне|надо|нужно|хочу|ещё|еще|и|а|потом|также|so|well|okay|ok|um|uh|and|then|also|today|i\s+(?:need|have|want|got)\s+to|i'?ve\s+got\s+to|i\s+gotta|gotta|i\s+(?:should|must)|need\s+to|have\s+to|don't\s+forget\s+to|remember\s+to|to)\s+"#)
    static let bare = Pattern(#"^(?:так|ну|короче|ладно|итак|so|well|okay|ok)$"#)
}

/// Note of a task made long today. Same text as `TaskStore.longNote(day: 1)`, which is main-actor isolated.
enum LongTask {
    static let firstDayNote = "long · day 1"
}

