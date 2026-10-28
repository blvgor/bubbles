import Foundation

/// A task in an editable list, with the transcript line it came from.
public struct DraftTask: Equatable, Sendable, Identifiable {
    public var task: DayTask
    /// Index (0-based) of the transcript line the task came from; nil when typed or unknown.
    public var sourceLine: Int?
    /// The task was already on the desk when the draft opened.
    public var onDesk: Bool

    public var id: UUID { task.id }

    public init(task: DayTask, sourceLine: Int? = nil, onDesk: Bool = false) {
        self.task = task
        self.sourceLine = sourceLine
        self.onDesk = onDesk
    }
}

/// Manual order on top of `Ranker`: a task dragged to a place is pinned there ("manual order beats
/// automatic"); the rest fill the free slots by rank. Persisted with the day.
public struct TaskOrder: Codable, Equatable, Sendable {
    /// Pinned task → its slot in the list.
    public private(set) var pins: [UUID: Int]

    public init(pins: [UUID: Int] = [:]) {
        self.pins = pins
    }

    public func isPinned(_ id: UUID) -> Bool { pins[id] != nil }

    public func apply(_ tasks: [DayTask], now: Date = Date()) -> [DayTask] {
        arrange(tasks, task: { $0 }, now: now)
    }

    /// Pinned items go to their slots (clamped to the list; a taken slot moves them to the next free one),
    /// the others fill the free slots highest score first, equal scores in input order.
    public func arrange<Item>(_ items: [Item], task: (Item) -> DayTask, now: Date) -> [Item] {
        let n = items.count
        guard n > 0 else { return [] }
        var slots = [Int?](repeating: nil, count: n)   // item index per slot
        let pinned = items.indices
            .compactMap { i in pins[task(items[i]).id].map { (index: i, slot: $0) } }
            .sorted { $0.slot != $1.slot ? $0.slot < $1.slot : $0.index < $1.index }
        var placed = Set<Int>()
        for (index, slot) in pinned {
            var at = min(max(0, slot), n - 1)
            if slots[at] != nil {
                if let free = (at..<n).first(where: { slots[$0] == nil }) ?? (0..<at).last(where: { slots[$0] == nil }) {
                    at = free
                }
            }
            slots[at] = index
            placed.insert(index)
        }
        let minutes = Ranker.minutesSinceMidnight(now)
        var rest = items.indices.filter { !placed.contains($0) }
            .map { (index: $0, score: Ranker.score(task(items[$0]), nowMinutes: minutes)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.index)
            .makeIterator()
        for slot in 0..<n where slots[slot] == nil { slots[slot] = rest.next() }
        return slots.compactMap { $0.map { items[$0] } }
    }

    public mutating func unpin(_ id: UUID) { pins[id] = nil }

    /// After the list changed: the ids in `pinned` are pinned at their positions in `list`; nothing else is.
    public mutating func reindex(_ list: [UUID], pinned: Set<UUID>) {
        var next: [UUID: Int] = [:]
        for (i, id) in list.enumerated() where pinned.contains(id) { next[id] = i }
        pins = next
    }
}

/// A row taken out with "Delete", kept for "Undo".
public struct RemovedTask: Equatable, Sendable {
    public let item: DraftTask
    /// Position in the ordered list it was removed from.
    public let index: Int
    public let pinned: Bool
}

/// The editable list behind "Got it", "All tasks", the card and the bubble's context menu.
/// Pure value type; every structural change keeps pinned rows where they are on screen.
public struct EditableTaskList: Equatable, Sendable {
    /// Storage order (ties of equal score follow it).
    public private(set) var items: [DraftTask]
    public private(set) var order: TaskOrder

    public init(items: [DraftTask] = [], order: TaskOrder = TaskOrder()) {
        self.items = items
        self.order = order
    }

    public var tasks: [DayTask] { items.map(\.task) }
    public var isEmpty: Bool { items.isEmpty }

    /// The list as it is shown: pinned rows at their slots, the rest by rank.
    public func ordered(now: Date = Date()) -> [DraftTask] {
        order.arrange(items, task: \.task, now: now)
    }

    public func item(_ id: UUID) -> DraftTask? { items.first { $0.id == id } }
    public func contains(_ id: UUID) -> Bool { items.contains { $0.id == id } }
    public func isPinned(_ id: UUID) -> Bool { order.isPinned(id) }

    // MARK: - Field edits

    /// Keeps the text as typed (trimmed on launch). Returns whether anything changed.
    @discardableResult public mutating func setTitle(_ title: String, id: UUID) -> Bool {
        change(id) { $0.task.title = title }
    }

    @discardableResult public mutating func setPriority(_ priority: Priority, id: UUID) -> Bool {
        change(id) { $0.task.priority = priority }
    }

    /// nil minutes = "No time".
    @discardableResult public mutating func setDue(_ minutes: Int?, kind: DueKind?, id: UUID) -> Bool {
        change(id) {
            $0.task.dueMinutes = minutes.map { (($0 % 1440) + 1440) % 1440 }
            $0.task.dueKind = minutes == nil ? nil : (kind ?? .deadline)
        }
    }

    /// "Make long" / back to a task of the day.
    @discardableResult public mutating func setLong(_ on: Bool, id: UUID) -> Bool {
        change(id) {
            guard on != ($0.task.kind == .long) else { return }
            $0.task.kind = on ? .long : .today
            $0.task.note = on ? LongTask.firstDayNote : nil
        }
    }

    /// Replaces a task's fields (same id), e.g. after the store changed it.
    @discardableResult public mutating func replace(_ task: DayTask) -> Bool {
        change(task.id) { $0.task = task }
    }

    // MARK: - Structure

    /// "Split": at `offset` (UTF-16, the cursor) or, without one, where the title reads as two tasks.
    /// The new task gets the same time, urgency, kind and source line, right after the original.
    @discardableResult public mutating func split(id: UUID, at offset: Int? = nil, now: Date = Date()) -> UUID? {
        var list = ordered(now: now)
        guard let i = list.firstIndex(where: { $0.id == id }),
              let (first, second) = DraftText.splitTitle(list[i].task.title, at: offset) else { return nil }
        var pinned = Set(order.pins.keys)
        list[i].task.title = first
        var other = list[i]
        other.task.id = UUID()
        other.task.title = second
        other.onDesk = false
        list.insert(other, at: i + 1)
        if pinned.contains(id) { pinned.insert(other.id) }
        rebuild(list, pinned: pinned)
        return other.id
    }

    /// "Merge with next": the next row's words join this one; the higher urgency and the first time win.
    @discardableResult public mutating func mergeWithNext(id: UUID, now: Date = Date()) -> Bool {
        let list = ordered(now: now)
        guard let i = list.firstIndex(where: { $0.id == id }), i + 1 < list.count else { return false }
        let next = list[i + 1]
        return absorb(next.id, into: id, title: DraftText.mergedTitle(list[i].task.title, next.task.title), now: now)
    }

    /// "Looks like … — merge?": `id` goes away, `target` keeps its title and takes the higher urgency.
    @discardableResult public mutating func merge(_ id: UUID, into target: UUID, now: Date = Date()) -> Bool {
        guard let kept = item(target) else { return false }
        return absorb(id, into: target, title: kept.task.title, now: now)
    }

    private mutating func absorb(_ id: UUID, into target: UUID, title: String, now: Date) -> Bool {
        var list = ordered(now: now)
        guard id != target, let t = list.firstIndex(where: { $0.id == target }),
              let g = list.firstIndex(where: { $0.id == id }) else { return false }
        let gone = list[g]
        list[t].task.title = title
        if gone.task.priority.rawValue > list[t].task.priority.rawValue { list[t].task.priority = gone.task.priority }
        if list[t].task.dueMinutes == nil, let due = gone.task.dueMinutes {
            list[t].task.dueMinutes = due
            list[t].task.dueKind = gone.task.dueKind
        }
        if list[t].sourceLine == nil { list[t].sourceLine = gone.sourceLine }
        list.remove(at: g)
        rebuild(list, pinned: Set(order.pins.keys).subtracting([id]))
        return true
    }

    /// Drag by ⋮⋮: the row goes to `index` of the ordered list and stays pinned there.
    @discardableResult public mutating func move(id: UUID, to index: Int, now: Date = Date()) -> Bool {
        var list = ordered(now: now)
        guard let from = list.firstIndex(where: { $0.id == id }) else { return false }
        let row = list.remove(at: from)
        list.insert(row, at: min(max(0, index), list.count))
        let before = self
        rebuild(list, pinned: Set(order.pins.keys).union([id]))
        return self != before
    }

    @discardableResult public mutating func remove(id: UUID, now: Date = Date()) -> RemovedTask? {
        var list = ordered(now: now)
        guard let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = RemovedTask(item: list.remove(at: i), index: i, pinned: order.isPinned(id))
        rebuild(list, pinned: Set(order.pins.keys).subtracting([id]))
        return removed
    }

    /// "Undo": back at its old place (and pin), if it is not in the list already.
    public mutating func restore(_ removed: RemovedTask, now: Date = Date()) {
        guard !contains(removed.item.id) else { return }
        var list = ordered(now: now)
        list.insert(removed.item, at: min(removed.index, list.count))
        var pinned = Set(order.pins.keys)
        if removed.pinned { pinned.insert(removed.item.id) }
        rebuild(list, pinned: pinned)
    }

    /// New rows at the end of the storage order (they find their place by rank). Known ids are skipped.
    public mutating func append(_ new: [DraftTask], now: Date = Date()) {
        let known = Set(items.map(\.id))
        let fresh = new.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        rebuild(ordered(now: now) + fresh, pinned: Set(order.pins.keys))
    }

    /// Keeps only rows passing `keep` (pins of the others are dropped).
    public mutating func removeAll(where drop: (DraftTask) -> Bool, now: Date = Date()) {
        let list = ordered(now: now).filter { !drop($0) }
        rebuild(list, pinned: Set(order.pins.keys))
    }

    // MARK: - Hints

    /// Row → the earlier row (in list order) it looks like: "Looks like “Buy groceries” — merge?".
    public func duplicates(now: Date = Date(), dismissed: Set<UUID> = []) -> [UUID: UUID] {
        let list = ordered(now: now)
        var result: [UUID: UUID] = [:]
        for j in list.indices where !dismissed.contains(list[j].id) {
            if let i = list[..<j].firstIndex(where: { DraftText.looksLikeDuplicate($0.task.title, list[j].task.title) }) {
                result[list[j].id] = list[i].id
            }
        }
        return result
    }

    /// Rows whose time today has already passed: "16:00 has passed".
    public func pastDue(now: Date = Date()) -> Set<UUID> {
        let minutes = Ranker.minutesSinceMidnight(now)
        return Set(items.filter { $0.task.kind != .long && ($0.task.dueMinutes ?? Int.max) < minutes }.map(\.id))
    }

    /// Rows with an empty title: highlighted, and they block "Start the day".
    public var emptyTitles: Set<UUID> {
        Set(items.filter { $0.task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.id))
    }

    // MARK: - Internals

    private mutating func change(_ id: UUID, _ edit: (inout DraftTask) -> Void) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return false }
        let before = items[i]
        edit(&items[i])
        return items[i] != before
    }

    /// `list` becomes the storage order; `pinned` ids keep their positions in it.
    private mutating func rebuild(_ list: [DraftTask], pinned: Set<UUID>) {
        items = list
        order.reindex(list.map(\.id), pinned: pinned)
    }
}

/// Bounded undo history of whole states (⌘Z).
public struct UndoStack<State: Equatable & Sendable>: Equatable, Sendable {
    public private(set) var states: [State] = []
    public var limit: Int { 100 }

    public init() {}

    public var canUndo: Bool { !states.isEmpty }

    public mutating func record(_ state: State) {
        states.append(state)
        if states.count > limit { states.removeFirst(states.count - limit) }
    }

    public mutating func pop() -> State? { states.popLast() }
    public mutating func clear() { states = [] }
}

/// The desk's tasks as an editable list with ⌘Z, for "All tasks", the card and the bubble's menu.
/// The owner writes `tasks` and `order` back to the store after each edit.
public struct DeskTaskEditor: Equatable, Sendable {
    public private(set) var list: EditableTaskList
    private var history = UndoStack<EditableTaskList>()

    public init(tasks: [DayTask] = [], order: TaskOrder = TaskOrder()) {
        list = EditableTaskList(items: tasks.map { DraftTask(task: $0, onDesk: true) }, order: order)
    }

    public var tasks: [DayTask] { list.tasks }
    public var order: TaskOrder { list.order }
    public var canUndo: Bool { history.canUndo }

    public func ordered(now: Date = Date()) -> [DayTask] { list.ordered(now: now).map(\.task) }

    /// Applies `change`; an edit that changed something becomes one undo step.
    @discardableResult public mutating func edit<Result>(_ change: (inout EditableTaskList) -> Result) -> Result {
        let before = list
        let result = change(&list)
        if list != before { history.record(before) }
        return result
    }

    @discardableResult public mutating func undo() -> Bool {
        guard let previous = history.pop() else { return false }
        list = previous
        return true
    }

    /// The store changed outside the editor (a task closed, burned, moved, rolled over, dictated):
    /// known rows take the stored fields, new ones are added, gone ones dropped with their pins.
    /// Undo history is cleared then, so ⌘Z never brings back a closed task.
    public mutating func sync(_ stored: [DayTask]) {
        guard stored != list.tasks else { return }
        let byID = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rows = list.items.compactMap { row -> DraftTask? in
            guard let task = byID[row.id] else { return nil }
            var r = row
            r.task = task
            return r
        }
        let known = Set(rows.map(\.id))
        rows += stored.filter { !known.contains($0.id) }.map { DraftTask(task: $0, onDesk: true) }
        let pinned = Set(list.order.pins.keys)
        let kept = list.ordered().filter { byID[$0.id] != nil }.map(\.id)
        var order = list.order
        order.reindex(kept, pinned: pinned)
        list = EditableTaskList(items: rows, order: order)
        history.clear()
    }
}

/// What the card says about a task's day: where it came from and how often it surfaced or was put off.
public struct TaskTrail: Codable, Equatable, Sendable {
    public var surfaced: Int = 0
    /// Each "Snooze" in minutes.
    public var snoozedMinutes: [Int] = []
    /// The transcript line the task came from.
    public var sourceLine: String?
    public var dictatedAt: Date?

    public init(surfaced: Int = 0, snoozedMinutes: [Int] = [], sourceLine: String? = nil, dictatedAt: Date? = nil) {
        self.surfaced = surfaced
        self.snoozedMinutes = snoozedMinutes
        self.sourceLine = sourceLine
        self.dictatedAt = dictatedAt
    }

    /// "Surfaced 2 times · snoozed for 15 min".
    public var historyLine: String {
        var parts = [surfaced == 0
            ? "Not surfaced yet"
            : surfaced == 1 ? "Surfaced once" : "Surfaced \(surfaced) times"]
        switch snoozedMinutes.count {
        case 0: break
        case 1: parts.append("snoozed for \(Self.duration(snoozedMinutes[0]))")
        case let n: parts.append("snoozed \(n) times")
        }
        return parts.joined(separator: " · ")
    }

    /// "dictated at 09:12".
    public var originLine: String? {
        dictatedAt.map { "dictated at \(DayTask.clock(Ranker.minutesSinceMidnight($0)))" }
    }

    /// "15 min", "1 h", "1 h 30 min".
    public static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
