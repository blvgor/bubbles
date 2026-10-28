import Combine
import Foundation

/// One closed task: what it was and the phrase the user wrote as proof.
public struct CompletionRecord: Codable, Equatable, Sendable {
    public var title: String
    public var proof: String
    public var completedAt: Date
}

/// The day's tasks, the "K done" counter and the streak, persisted to a JSON file after every mutation.
/// A missing or corrupt file yields an empty day, never a crash.
@MainActor public final class TaskStore: ObservableObject {
    @Published public private(set) var tasks: [DayTask] = []
    @Published public private(set) var doneToday: Int = 0
    @Published public private(set) var streak: Int = 0
    /// Closed tasks with their proof phrases, newest last (capped).
    public private(set) var history: [CompletionRecord] = []

    public nonisolated static var defaultURL: URL {
        DataFolder.url.appendingPathComponent("state.json")
    }

    /// `~/Library/Application Support/Bubbles` (or `BUBBLES_DATA_DIR`): the state, the dictation draft and
    /// anything set aside.
    public nonisolated static var dataFolder: URL { defaultURL.deletingLastPathComponent() }

    /// "Reset data": the whole folder goes.
    public nonisolated static func removeAllData(in folder: URL = dataFolder) throws {
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    static let historyLimit = 500

    private let fileURL: URL
    private let now: () -> Date
    private let calendar = Calendar.current
    /// Start of the local day the counters belong to.
    private var day: Date
    private var burnedToday = false

    public init(fileURL: URL = TaskStore.defaultURL, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        day = calendar.startOfDay(for: now())
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            tasks = state.tasks.map { var t = $0; t.note = Self.englishNote(t.note); return t }
            doneToday = state.doneToday
            streak = state.streak
            history = state.history
            day = state.day ?? day
            burnedToday = state.burnedToday
        } else {
            // Unreadable (damaged, or written by something else): set it aside before the first save
            // overwrites it, so it can still be recovered by hand.
            let bad = fileURL.appendingPathExtension("bad")
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.moveItem(at: fileURL, to: bad)
        }
    }

    /// Carried-over and long tasks, offered in the "Carried over and long" block of the confirm sheet.
    public func carryOverCandidates() -> [DayTask] {
        tasks.filter { $0.kind == .carry || $0.kind == .long }
    }

    /// "Looks good, launch": the confirmed list becomes the whole day.
    /// Duplicate ids keep their first occurrence.
    public func replaceDay(with tasks: [DayTask]) {
        self.tasks = []
        merge(tasks)
        save()
    }

    /// A task whose id is already stored replaces that entry in place instead of being added twice.
    public func add(_ tasks: [DayTask]) {
        merge(tasks)
        save()
    }

    private func merge(_ incoming: [DayTask]) {
        var result = tasks
        var index = Dictionary(result.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for task in incoming {
            if let i = index[task.id] {
                if tasks.contains(where: { $0.id == task.id }) { result[i] = task }   // replace a stored one
            } else {
                index[task.id] = result.count
                result.append(task)
            }
        }
        tasks = result
    }

    public func update(_ task: DayTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        save()
    }

    /// Closed with a proof phrase and the 10-second hold.
    public func complete(id: UUID, proof: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks.remove(at: index)
        doneToday += 1
        history.append(CompletionRecord(title: task.title, proof: proof, completedAt: now()))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        save()
    }

    /// "Burn and exit": the task is gone and the streak resets.
    public func burn(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks.remove(at: index)
        streak = 0
        burnedToday = true
        save()
    }

    /// On launch and when the date changes: unfinished "today" tasks become "from yesterday", long tasks count
    /// one more day, the daily counter resets. Streak: +1 if the previous day closed at least one task
    /// and burned none; otherwise (a burn, nothing closed, or days skipped) it resets to 0.
    public func rolloverIfNeeded() {
        let today = calendar.startOfDay(for: now())
        guard today > day else { return }
        let days = max(1, calendar.dateComponents([.day], from: day, to: today).day ?? 1)

        streak = (days == 1 && doneToday > 0 && !burnedToday) ? streak + 1 : 0
        tasks = tasks.map { task in
            var t = task
            switch t.kind {
            case .today:
                t.kind = .carry
                t.note = Self.carryNote
            case .carry:
                if t.note == nil { t.note = Self.carryNote }
            case .long:
                t.note = Self.longNote(day: Self.longDay(from: t.note) + days)
            }
            return t
        }
        doneToday = 0
        burnedToday = false
        day = today
        save()
    }

    // MARK: - Notes

    public static let carryNote = "from yesterday"

    /// "long · day N".
    public static func longNote(day: Int) -> String { "long · day \(day)" }

    /// Notes saved while the interface was Russian read in English: "from yesterday" → "from yesterday",
    /// «длинная · 6-й день» → "long · day 6". Anything else stays as it was.
    nonisolated static func englishNote(_ note: String?) -> String? {
        guard let note else { return nil }
        if note == "со вчера" { return "from yesterday" }
        if note.hasPrefix("длинная") { return "long · day \(longDay(from: note))" }
        return note
    }

    nonisolated static func longDay(from note: String?) -> Int {
        guard let note, let range = note.range(of: #"\d+"#, options: .regularExpression) else { return 1 }
        return Int(note[range]) ?? 1
    }

    // MARK: - Persistence

    /// Every field is optional on read: a file from an older (or newer) build loads with defaults for
    /// what it lacks instead of being dropped.
    private struct PersistedState: Codable {
        var day: Date?
        var tasks: [DayTask]
        var doneToday: Int
        var burnedToday: Bool
        var streak: Int
        var history: [CompletionRecord]

        init(day: Date, tasks: [DayTask], doneToday: Int, burnedToday: Bool, streak: Int, history: [CompletionRecord]) {
            self.day = day
            self.tasks = tasks
            self.doneToday = doneToday
            self.burnedToday = burnedToday
            self.streak = streak
            self.history = history
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decodeIfPresent(Date.self, forKey: .day)
            tasks = try c.decodeIfPresent([DayTask].self, forKey: .tasks) ?? []
            doneToday = try c.decodeIfPresent(Int.self, forKey: .doneToday) ?? 0
            burnedToday = try c.decodeIfPresent(Bool.self, forKey: .burnedToday) ?? false
            streak = try c.decodeIfPresent(Int.self, forKey: .streak) ?? 0
            history = try c.decodeIfPresent([CompletionRecord].self, forKey: .history) ?? []
        }
    }

    /// Atomic replace: write a temp file next to the target, then rename(2) over it.
    /// (Foundation's `.atomic` stages files in a system temp folder, which restricted sandboxes deny.)
    private func save() {
        let state = PersistedState(day: day, tasks: tasks, doneToday: doneToday, burnedToday: burnedToday,
                                   streak: streak, history: history)
        do {
            let data = try JSONEncoder().encode(state)
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temp = folder.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
            try data.write(to: temp)
            if rename(temp.path, fileURL.path) != 0 {
                try? FileManager.default.removeItem(at: temp)
            }
        } catch {
            // Disk full or folder not writable: keep the in-memory day; the next mutation retries.
        }
    }
}

/// A task whose takeover has started can only be closed or burned: it is not removed, moved to tomorrow
/// or merged away (the spec: "moving happens before the takeover").
public enum TakeoverLock {
    public static let refusal = "The takeover has started — this task can only be closed or burned"

    /// `onDesk`: the row is a task already on the desk (always true in "All tasks").
    public static func refuses(onDesk: Bool, canMoveToTomorrow: Bool) -> Bool { onDesk && !canMoveToTomorrow }
}
