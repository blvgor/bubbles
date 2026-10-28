import Foundation

/// When the day is already going: "Add to today" (default) keeps the desk's tasks,
/// "Replace the day" launches only what the draft adds.
public enum DraftMode: String, Codable, Sendable {
    case addToToday, replaceDay
}

/// A phrase that did not become a task ("Unparsed"): "Make a task" or "Remove".
public struct LeftoverItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    public var sourceLine: Int?

    public init(id: UUID = UUID(), text: String, sourceLine: Int?) {
        self.id = id
        self.text = text
        self.sourceLine = sourceLine
    }
}

/// The "Got it" editor's working copy (screen 4): the transcript lines, today's list with source lines and
/// manual order, "Unparsed", "Carried over and long" with checkboxes, rows moved to tomorrow, the
/// add/replace switch, and ⌘Z for every edit. Pure, so every rule of the screen is testable.
public struct DictationDraft: Equatable, Sendable {
    public struct CarryItem: Equatable, Sendable {
        public var task: DayTask
        public var included: Bool
    }

    private struct State: Equatable, Sendable {
        var lines: [String] = []
        var list = EditableTaskList()
        var carry: [CarryItem] = []
        var leftover: [LeftoverItem] = []
        var tomorrow: [DayTask] = []
        var mode: DraftMode = .addToToday
        var dismissedDuplicates: Set<UUID> = []
    }

    private var state = State()
    private var history = UndoStack<State>()
    /// The desk already had tasks of the day: the add/replace switch is shown.
    public let dayInProgress: Bool
    /// No AI key (the plain tracker): a typed line or a promoted phrase is one task exactly as written —
    /// no time, no urgency, no cutting by rules.
    public let keepsTextAsWritten: Bool

    /// `existing`: the stored day without the example tasks. "Today" tasks come into the list (marked as
    /// already on the desk, keeping their manual order from `order`); carried-over and long ones are
    /// offered checked.
    public init(existing: [DayTask], order: TaskOrder = TaskOrder(), now: Date = Date(), keepsTextAsWritten: Bool = false) {
        self.keepsTextAsWritten = keepsTextAsWritten
        let arranged = order.apply(existing, now: now)
        let today = arranged.filter { $0.kind == .today }
        var pins = TaskOrder()
        pins.reindex(today.map(\.id), pinned: Set(order.pins.keys))
        state.list = EditableTaskList(items: today.map { DraftTask(task: $0, onDesk: true) }, order: pins)
        state.carry = existing.filter { $0.kind != .today }.map { CarryItem(task: $0, included: true) }
        dayInProgress = !today.isEmpty
    }

    // MARK: - Reading

    public var lines: [String] { state.lines }
    public var list: EditableTaskList { state.list }
    public var carry: [CarryItem] { state.carry }
    public var leftover: [LeftoverItem] { state.leftover }
    public var tomorrow: [DayTask] { state.tomorrow }
    public var mode: DraftMode { state.mode }
    public var canUndo: Bool { history.canUndo }

    /// Today's tasks in storage order.
    public var today: [DayTask] { state.list.tasks }
    public func ordered(now: Date = Date()) -> [DraftTask] { state.list.ordered(now: now) }
    public func isOnDesk(_ id: UUID) -> Bool { state.list.item(id)?.onDesk ?? false }
    public func isPinned(_ id: UUID) -> Bool { state.list.isPinned(id) }
    public var emptyTitles: Set<UUID> { state.list.emptyTitles }
    public func duplicates(now: Date = Date()) -> [UUID: UUID] {
        state.list.duplicates(now: now, dismissed: state.dismissedDuplicates)
    }
    public func pastDue(now: Date = Date()) -> Set<UUID> { state.list.pastDue(now: now) }

    /// Rows found by dictation or added here (not the ones already on the desk).
    public var newCount: Int { state.list.items.filter { !$0.onDesk }.count }

    // MARK: - Parse results

    /// A parse of newly dictated `lines` ("Dictate more" appends): tasks keep their line, leftover too.
    public mutating func absorb(_ result: TaskParseResult, lines new: [String]) {
        checkpoint()
        let offset = state.lines.count
        state.lines += new
        state.list.append(result.tasks.map { DraftTask(task: $0.task, sourceLine: $0.sourceLine.map { $0 + offset }) })
        state.leftover += result.leftover.map { text in
            let line = new.firstIndex { $0.localizedCaseInsensitiveContains(text) } ?? new.firstIndex { text.localizedCaseInsensitiveContains($0) }
            return LeftoverItem(text: text, sourceLine: line.map { $0 + offset })
        }
    }

    /// The transcript was edited and parsed again: what the old lines gave (tasks not on the desk and
    /// leftover) is replaced by the new parse.
    public mutating func retranscribe(_ result: TaskParseResult, lines new: [String]) {
        checkpoint()
        state.list.removeAll { $0.sourceLine != nil && !$0.onDesk }
        state.leftover = []
        state.lines = []
        let saved = history
        absorb(result, lines: new)
        history = saved
    }

    /// Tasks without a source line (typed in elsewhere).
    public mutating func append(_ tasks: [DayTask]) {
        checkpoint()
        state.list.append(tasks.map { DraftTask(task: $0) })
    }

    /// "+ Add task": the line is parsed for time and urgency (kept as written without an AI key);
    /// a phrase the parser drops becomes a task as typed.
    @discardableResult public mutating func addTask(text: String, now: Date = Date()) -> [UUID] {
        let made = tasks(from: text, now: now)
        guard !made.isEmpty else { return [] }
        checkpoint()
        state.list.append(made.map { DraftTask(task: $0) }, now: now)
        return made.map(\.id)
    }

    /// "Make a task" on a leftover phrase.
    @discardableResult public mutating func promoteLeftover(_ id: UUID, now: Date = Date()) -> UUID? {
        guard let i = state.leftover.firstIndex(where: { $0.id == id }),
              let task = tasks(from: state.leftover[i].text, now: now).first else { return nil }
        checkpoint()
        let line = state.leftover.remove(at: i).sourceLine
        state.list.append([DraftTask(task: task, sourceLine: line)], now: now)
        return task.id
    }

    /// "Remove" on a leftover phrase.
    public mutating func dismissLeftover(_ id: UUID) {
        guard state.leftover.contains(where: { $0.id == id }) else { return }
        checkpoint()
        state.leftover.removeAll { $0.id == id }
    }

    // MARK: - Row edits

    /// Rename (commit, not every keystroke). Also renames rows of "Carried over and long".
    public mutating func setTitle(_ title: String, id: UUID) {
        edit { s in
            if !s.list.setTitle(title, id: id) { s.carry.change(id) { $0.title = title } }
        }
    }

    public mutating func setPriority(_ priority: Priority, id: UUID) {
        edit { s in
            if !s.list.setPriority(priority, id: id) { s.carry.change(id) { $0.priority = priority } }
        }
    }

    /// The pill as a quick toggle: urgent → important → normal → urgent.
    public mutating func cyclePriority(id: UUID) {
        let current = state.list.item(id)?.task.priority ?? state.carry.first { $0.task.id == id }?.task.priority
        guard let current else { return }
        setPriority(current.next, id: id)
    }

    /// Time popover; nil = "No time".
    public mutating func setDue(_ minutes: Int?, kind: DueKind?, id: UUID) {
        edit { s in
            if !s.list.setDue(minutes, kind: kind, id: id) {
                s.carry.change(id) {
                    $0.dueMinutes = minutes
                    $0.dueKind = minutes == nil ? nil : (kind ?? .deadline)
                }
            }
        }
    }

    public mutating func setLong(_ on: Bool, id: UUID) {
        edit { $0.list.setLong(on, id: id) }
    }

    @discardableResult public mutating func split(id: UUID, at offset: Int? = nil, now: Date = Date()) -> UUID? {
        edit { $0.list.split(id: id, at: offset, now: now) }
    }

    public mutating func mergeWithNext(id: UUID, now: Date = Date()) {
        edit { $0.list.mergeWithNext(id: id, now: now) }
    }

    public mutating func move(id: UUID, to index: Int, now: Date = Date()) {
        edit { $0.list.move(id: id, to: index, now: now) }
    }

    @discardableResult public mutating func remove(id: UUID, now: Date = Date()) -> RemovedTask? {
        edit { $0.list.remove(id: id, now: now) }
    }

    public mutating func restore(_ removed: RemovedTask, now: Date = Date()) {
        edit { $0.list.restore(removed, now: now) }
    }

    /// Checkbox in "Carried over and long".
    public mutating func setIncluded(_ on: Bool, id: UUID) {
        edit { s in
            guard let i = s.carry.firstIndex(where: { $0.task.id == id }) else { return }
            s.carry[i].included = on
        }
    }

    /// "Move to tomorrow" (a past time, or any row): off today's list, handed over on launch.
    public mutating func moveToTomorrow(_ id: UUID) {
        edit { s in
            if let row = s.list.item(id) {
                s.list.removeAll { $0.id == id }
                s.tomorrow.append(row.task)
            } else if let i = s.carry.firstIndex(where: { $0.task.id == id }) {
                s.tomorrow.append(s.carry.remove(at: i).task)
            }
        }
    }

    /// "Looks like “…” — merge?": the row goes into the one it looks like.
    public mutating func mergeDuplicate(_ id: UUID, now: Date = Date()) {
        guard let target = duplicates(now: now)[id] else { return }
        edit { $0.list.merge(id, into: target, now: now) }
    }

    /// The duplicate hint under the row is closed and not offered again.
    public mutating func dismissDuplicate(_ id: UUID) {
        edit { $0.dismissedDuplicates.insert(id) }
    }

    public mutating func setMode(_ mode: DraftMode) {
        edit { $0.mode = mode }
    }

    /// "Make some long" (more than 20): ordinary rows without a time beyond the first `keeping`.
    public mutating func makeTailLong(keeping: Int, now: Date = Date()) {
        edit { s in
            for row in s.list.ordered(now: now).dropFirst(keeping)
            where row.task.priority == .normal && row.task.dueMinutes == nil && row.task.kind == .today {
                s.list.setLong(true, id: row.id)
            }
        }
    }

    /// ⌘Z: the state before the last edit.
    @discardableResult public mutating func undo() -> Bool {
        guard let previous = history.pop() else { return false }
        state = previous
        return true
    }

    // MARK: - Launch

    /// "Start the day": the rows in list order (without those already on the desk when replacing the day),
    /// titles trimmed, then the checked rows of "Carried over and long".
    public func launchList(now: Date = Date()) -> [DayTask] {
        let rows = ordered(now: now).filter { state.mode == .addToToday || !$0.onDesk }
        return (rows.map(\.task) + state.carry.filter(\.included).map(\.task)).compactMap { task in
            var t = task
            t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.title.isEmpty ? nil : t
        }
    }

    /// Manual order for the launched day: pinned rows at their places in `launchList`.
    public func launchOrder(now: Date = Date()) -> TaskOrder {
        var order = TaskOrder()
        order.reindex(launchList(now: now).map(\.id), pinned: Set(state.list.order.pins.keys))
        return order
    }

    /// An empty title is highlighted and stops the launch; so does an empty day.
    public func canLaunch(now: Date = Date()) -> Bool {
        emptyTitles.isEmpty && !launchList(now: now).isEmpty
    }

    /// "Found 6 tasks · 1 phrase didn't become a task · top: Pay the internet bill".
    public func summary(now: Date = Date()) -> String {
        let found = newCount
        let left = state.leftover.count
        guard found > 0 || !state.list.isEmpty else { return "No tasks found — split the lines or add tasks by hand" }
        var parts: [String] = []
        if found > 0 {
            parts.append("Found \(found) \(Plural.en(found, "task"))")
        } else {
            parts.append("No new tasks")
        }
        if left > 0 {
            parts.append(left == 1 ? "1 phrase didn't become a task"
                : "\(left) phrases didn't become tasks")
        }
        if let top = launchList(now: now).first { parts.append("top: \(top.title)") }
        return parts.joined(separator: " · ")
    }

    /// More than 20 tasks: "8 fit on the desk, the rest wait in the “+N” queue".
    public func queueNote(now: Date = Date()) -> String? {
        let count = launchList(now: now).count
        guard count > 20 else { return nil }
        return "\(PhysicsWorld.maxVisible) fit on the desk, the rest wait in the “+\(count - PhysicsWorld.maxVisible)” queue"
    }

    // MARK: - Internals

    private mutating func checkpoint() {
        history.record(state)
    }

    /// Applies `change` to the state; records an undo step only when something changed.
    @discardableResult private mutating func edit<Result>(_ change: (inout State) -> Result) -> Result {
        let before = state
        let result = change(&state)
        if state != before { history.record(before) }
        return result
    }

    private func tasks(from text: String, now: Date) -> [DayTask] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if keepsTextAsWritten { return TaskParser.plain(lines: [trimmed], now: now).dayTasks }
        let parsed = TaskParser.parse(lines: [trimmed], now: now).dayTasks
        return parsed.isEmpty ? [DayTask(title: DraftText.capitalized(trimmed), createdAt: now)] : parsed
    }
}

private extension Array where Element == DictationDraft.CarryItem {
    mutating func change(_ id: UUID, _ edit: (inout DayTask) -> Void) {
        guard let i = firstIndex(where: { $0.task.id == id }) else { return }
        edit(&self[i].task)
    }
}

/// Text rules of the editor: splitting and merging titles, duplicates, the separator word.
public enum DraftText {
    /// First letter upper-cased.
    public static func capitalized(_ s: String) -> String {
        s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Two titles from one: at `offset` (UTF-16, the cursor), else where the parser would cut it
    /// (an infinitive, "and then" / «и», «потом», a comma), else after the middle word. nil when a part would be empty.
    public static func splitTitle(_ title: String, at offset: Int? = nil) -> (String, String)? {
        let ns = title as NSString
        var parts: (String, String)?
        if let offset, offset > 0, offset < ns.length {
            parts = (ns.substring(to: offset), ns.substring(from: offset))
        } else {
            let pieces = TaskParser.fragments(of: title)
            if pieces.count >= 2 {
                parts = (pieces[0], pieces.dropFirst().joined(separator: " "))
            } else {
                let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
                guard words.count >= 2 else { return nil }
                let half = (words.count + 1) / 2
                parts = (words[..<half].joined(separator: " "), words[half...].joined(separator: " "))
            }
        }
        guard let (a, b) = parts else { return nil }
        let left = trimJoint(a, leading: false), right = trimJoint(b, leading: true)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (capitalized(left), capitalized(right))
    }

    /// "Buy groceries" + "Pick up the parcel" → "Buy groceries and pick up the parcel"; Russian titles join with «и».
    public static func mergedTitle(_ a: String, _ b: String) -> String {
        let left = trimJoint(a, leading: false), right = trimJoint(b, leading: true)
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        let chars = Array(right)
        let lowered = chars.count > 1 && chars[0].isUppercase && chars[1].isLowercase
            ? right.prefix(1).lowercased() + right.dropFirst() : right
        let cyrillic = (left + right).unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let joint = cyrillic ? "и" : "and"
        return "\(left) \(joint) \(lowered)"
    }

    /// Same words (stems of words of 3+ letters) for the most part: equal, or 60 % of the words in common.
    public static func looksLikeDuplicate(_ a: String, _ b: String) -> Bool {
        let x = stems(a), y = stems(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        let common = x.intersection(y).count
        return common >= 2 && Double(common) / Double(x.union(y).count) >= 0.6
    }

    /// Lines cut at the settings' separator word (one or more words, any case, «ё» = «е»); the word itself
    /// is dropped. Empty lines go away.
    public static func splitLines(_ lines: [String], separator: String) -> [String] {
        let key = separator.split(whereSeparator: \.isWhitespace).map { Transcript.normalized(String($0)) }.filter { !$0.isEmpty }
        let cleaned: (String) -> String = { trimJoint($0, leading: false) }
        guard !key.isEmpty else { return lines.map(cleaned).filter { !$0.isEmpty } }
        var out: [String] = []
        for line in lines {
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            var current: [String] = []
            var i = 0
            while i < words.count {
                if i + key.count <= words.count,
                   (0..<key.count).allSatisfy({ Transcript.normalized(words[i + $0]) == key[$0] }) {
                    out.append(cleaned(current.joined(separator: " ")))
                    current = []
                    i += key.count
                    continue
                }
                current.append(words[i])
                i += 1
            }
            out.append(cleaned(current.joined(separator: " ")))
        }
        return out.filter { !$0.isEmpty }
    }

    private static func stems(_ s: String) -> Set<String> {
        Set(s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { Transcript.normalized(String($0)) }
            .filter { $0.count >= 3 }
            .map { String($0.prefix(5)) })
    }

    /// Without spaces, punctuation and a dangling "and" / "then" / «и» / «потом» at the joint.
    private static func trimJoint(_ s: String, leading: Bool) -> String {
        let junk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…—-"))
        var t = s.trimmingCharacters(in: junk)
        let joints = ["и", "а", "потом", "и потом", "ещё", "еще", "and", "then", "and then", "also"]
        for joint in joints.sorted(by: { $0.count > $1.count }) {
            if leading, t.lowercased().hasPrefix(joint + " ") { t = String(t.dropFirst(joint.count + 1)); break }
            if !leading, t.lowercased().hasSuffix(" " + joint) { t = String(t.dropLast(joint.count + 1)); break }
        }
        return t.trimmingCharacters(in: junk)
    }
}
