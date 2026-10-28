import Foundation

/// Orders the day: the higher the score, the higher the task in lists and the bigger its bubble.
/// Port of `score()` / `rank()` from `prototype/index.html`.
public enum Ranker {
    /// `priority × 100 + max(0, 60 − (due − now) / 10) + (carried over ? 15 : 0)`.
    public static func score(_ t: DayTask, nowMinutes: Int) -> Double {
        var s = Double(t.priority.rawValue) * 100
        if let due = t.dueMinutes {
            s += max(0, 60 - Double(due - nowMinutes) / 10)
        }
        if t.kind == .carry { s += 15 }
        return s
    }

    /// Stable sort, highest score first; equal scores keep their input order.
    public static func rank(_ tasks: [DayTask], now: Date = Date()) -> [DayTask] {
        let minutes = minutesSinceMidnight(now)
        return tasks.enumerated()
            .map { (index: $0.offset, task: $0.element, score: score($0.element, nowMinutes: minutes)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.task)
    }

    /// Local minutes from midnight for `date`.
    public static func minutesSinceMidnight(_ date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}
