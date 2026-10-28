import Foundation

/// A step of the ladder: the top bubble rises above windows, or a task covers the whole screen.
public enum LadderEvent: Equatable, Sendable {
    case surface(UUID)
    case takeover(UUID)
}

/// What the ladder remembers between its once-a-second questions.
public struct LadderState: Codable, Equatable, Sendable {
    /// The last surfacing (or the app start before the first one); nil counts as «long ago».
    public var lastSurfaceAt: Date?
    /// "In 15 min" on a surfaced bubble.
    public var snoozedUntil: Date?
    /// Tasks whose takeover has started and stands until the task is closed or burned.
    public var takenOver: Set<UUID>
    /// "15 more minutes": task → the moment its takeover comes back. The entry stays after that moment,
    /// so a task gets one extension only.
    public var extendedUntil: [UUID: Date]

    public init(lastSurfaceAt: Date? = nil, snoozedUntil: Date? = nil, takenOver: Set<UUID> = [],
                extendedUntil: [UUID: Date] = [:]) {
        self.lastSurfaceAt = lastSurfaceAt
        self.snoozedUntil = snoozedUntil
        self.takenOver = takenOver
        self.extendedUntil = extendedUntil
    }

    /// The task left the day (closed, burned, moved to tomorrow): drop everything kept about it.
    public mutating func forget(_ id: UUID) {
        takenOver.remove(id)
        extendedUntil[id] = nil
    }
}

/// Decides the next ladder step. Pure: the caller keeps the state and asks once in a while.
public struct LadderScheduler: Sendable {
    /// "15 more minutes".
    public static let extensionMinutes = 15

    public init() {}

    /// - Nothing while `busy` (screen sharing, a full-screen call, Focus) and `settings.pauseDuringCalls`:
    ///   the step is only postponed — its moment stays reached, so it comes on the first question after.
    /// - Takeover (checked first, fires even while bubbles are hidden): the first ranked task, not yet in
    ///   `takenOver`, whose takeover moment has come — `takeoverBeforeMinutes` before its effective deadline
    ///   (or already past an explicit "by", since it stays until closed; a task without time that outlived
    ///   "End of day" does not take over), or the end of its "15 more minutes".
    /// - Surface: the top-ranked task once `surfaceEveryMinutes` have passed since `lastSurfaceAt`,
    ///   unless snoozed or hidden.
    public func next(ranked: [DayTask], settings: BubbleSettings, now: Date, state: LadderState,
                     busy: Bool = false) -> LadderEvent? {
        if busy && settings.pauseDuringCalls { return nil }

        for task in ranked where !state.takenOver.contains(task.id) {
            if let until = state.extendedUntil[task.id] {
                if now >= until { return .takeover(task.id) }
                continue
            }
            if takeoverMomentReached(task, settings: settings, now: now) { return .takeover(task.id) }
        }

        guard let every = settings.surfaceEveryMinutes, let top = ranked.first, !isHidden(settings.hidden, now: now) else {
            return nil
        }
        if let snoozedUntil = state.snoozedUntil, now < snoozedUntil { return nil }
        if let last = state.lastSurfaceAt, now.timeIntervalSince(last) < Double(every) * 60 { return nil }
        return .surface(top.id)
    }

    /// The pre-T08 signature, kept for callers that hold the three values separately.
    public func next(ranked: [DayTask], settings: BubbleSettings, now: Date,
                     lastSurfaceAt: Date?, snoozedUntil: Date?, takenOver: Set<UUID>) -> LadderEvent? {
        next(ranked: ranked, settings: settings, now: now,
             state: LadderState(lastSurfaceAt: lastSurfaceAt, snoozedUntil: snoozedUntil, takenOver: takenOver))
    }

    /// Whether the takeover may offer "15 more minutes": allowed in settings and not used for this task yet.
    public func canExtend(_ id: UUID, settings: BubbleSettings, state: LadderState) -> Bool {
        settings.allowExtension && state.extendedUntil[id] == nil
    }

    /// "15 more minutes": the takeover leaves and comes back in 15 minutes. Returns that moment,
    /// or nil (state untouched) when the task already used its extension or extensions are off.
    public func extend(_ id: UUID, settings: BubbleSettings, now: Date, state: inout LadderState) -> Date? {
        guard canExtend(id, settings: settings, state: state) else { return nil }
        let until = now.addingTimeInterval(Double(Self.extensionMinutes) * 60)
        state.extendedUntil[id] = until
        state.takenOver.remove(id)
        return until
    }

    /// "Move to tomorrow" keeps the streak only before the takeover starts: once its moment has come
    /// (even if a call postponed it) or it was on screen, the task can only be closed or burned.
    public func canMoveToTomorrow(_ task: DayTask, settings: BubbleSettings, now: Date, state: LadderState) -> Bool {
        if state.takenOver.contains(task.id) || state.extendedUntil[task.id] != nil { return false }
        return !takeoverMomentReached(task, settings: settings, now: now)
    }

    /// Minutes from midnight by which the task must be closed, or nil if it never takes over:
    /// "by HH:MM" → that time; "at HH:MM" (an appointment) → never; no time → "End of day",
    /// except long tasks, which live several days and have no implicit deadline.
    public func effectiveDeadline(_ task: DayTask, endOfDay: Int?) -> Int? {
        switch (task.dueMinutes, task.dueKind) {
        case (nil, _): task.kind == .long ? nil : endOfDay
        case (_, .at?): nil
        case (let due?, _): due
        }
    }

    private func takeoverMomentReached(_ task: DayTask, settings: BubbleSettings, now: Date) -> Bool {
        guard let before = settings.takeoverBeforeMinutes,
              let deadline = effectiveDeadline(task, endOfDay: settings.endOfDayMinutes) else { return false }
        let minutes = Ranker.minutesSinceMidnight(now)
        // A task without time lives until "End of day"; once that passed it goes to "Day summary" and never
        // covers the screen at night. An explicit "by" that passed still takes over (it stays until closed).
        if task.dueMinutes == nil && minutes >= deadline { return false }
        return minutes >= deadline - before
    }

    private func isHidden(_ hidden: HiddenState, now: Date) -> Bool {
        switch hidden {
        case .visible: false
        case .forever: true
        case .until(let date): now < date
        }
    }
}

// MARK: - Move to tomorrow

/// Tasks moved to tomorrow: off today's desk, back the next day as "from yesterday" (long ones stay long).
public struct TomorrowShelf: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var task: DayTask
        /// Start of the local day it was moved on.
        public var movedOn: Date
    }

    public private(set) var items: [Item] = []

    public init() {}

    public func contains(_ id: UUID) -> Bool { items.contains { $0.task.id == id } }

    public mutating func put(_ task: DayTask, now: Date, calendar: Calendar = .current) {
        items.removeAll { $0.task.id == task.id }
        items.append(Item(task: task, movedOn: calendar.startOfDay(for: now)))
    }

    /// Removes and returns the tasks moved on an earlier day, ready to join today as carried over.
    public mutating func takeDue(now: Date, calendar: Calendar = .current) -> [DayTask] {
        let today = calendar.startOfDay(for: now)
        let due = items.filter { $0.movedOn < today }
        items.removeAll { $0.movedOn < today }
        return due.map { item in
            var task = item.task
            if task.kind != .long {
                task.kind = .carry
                task.note = "from yesterday"   // == TaskStore.carryNote (main-actor isolated)
            }
            return task
        }
    }
}

// MARK: - Day summary

/// What happens to an unclosed task in "Day summary".
public enum DaySummaryChoice: String, CaseIterable, Sendable {
    case carry, long, burn

    public var label: String {
        switch self {
        case .carry: "Tomorrow"
        case .long: "Long"
        case .burn: "Burn"
        }
    }
}

/// When "Day summary" appears: at "End of day", or — if that evening passed unseen (Mac asleep or off) —
/// at the first start of a later day. `shownDay` is the start of the last day already summed up.
public enum DaySummaryRule {
    public static func eveningDue(now: Date, endOfDayMinutes: Int?, shownDay: Date?, hasOpenTasks: Bool,
                                  calendar: Calendar = .current) -> Bool {
        guard hasOpenTasks, let end = endOfDayMinutes else { return false }
        let today = calendar.startOfDay(for: now)
        if let shownDay, shownDay >= today { return false }
        return Ranker.minutesSinceMidnight(now) >= end
    }

    /// "Day summary" puts a window on the screen by itself only when the person turned the ladder on
    /// (surfacing or takeover). On "Background only" it waits in the menu instead.
    public static func opensItself(_ settings: BubbleSettings) -> Bool {
        settings.surfaceEveryMinutes != nil || settings.takeoverBeforeMinutes != nil
    }

    public static func morningDue(now: Date, shownDay: Date?, hasCarriedTasks: Bool,
                                  calendar: Calendar = .current) -> Bool {
        guard hasCarriedTasks else { return false }
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return false }
        guard let shownDay else { return true }
        return shownDay < yesterday
    }
}
