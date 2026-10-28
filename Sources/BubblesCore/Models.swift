import Foundation

/// How urgent a task is. The raw value is the weight used by `Ranker` (×100).
public enum Priority: Int, Codable, CaseIterable, Sendable {
    case normal = 1, important = 2, urgent = 3

    /// User-facing label on the priority pill.
    public var label: String {
        switch self {
        case .normal: "Normal"
        case .important: "Important"
        case .urgent: "Urgent"
        }
    }

    /// Next value when the pill is clicked in the confirm sheet: urgent → important → normal → urgent.
    public var next: Priority {
        switch self {
        case .urgent: .important
        case .important: .normal
        case .normal: .urgent
        }
    }
}

/// "by 16:00" is a deadline, "at 12:00" is an appointment. The raw value is the word shown before the time.
public enum DueKind: String, Codable, Sendable {
    case deadline = "by"
    case at = "at"

    /// Saves from the Russian-interface days stored the Russian words for "by" and "at"; they still read.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "by", "до": self = .deadline
        case "at", "в": self = .at
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown due kind \(raw)"))
        }
    }
}

/// Where a task came from: dictated today, carried over from yesterday, or a long multi-day task.
public enum TaskKind: String, Codable, Sendable {
    case today, carry, long
}

public struct DayTask: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var priority: Priority
    /// Minutes from local midnight, 0..<1440.
    public var dueMinutes: Int?
    /// nil when `dueMinutes == nil`.
    public var dueKind: DueKind?
    public var kind: TaskKind
    /// Secondary line, e.g. "from yesterday", "long · day 6".
    public var note: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, priority: Priority = .normal, dueMinutes: Int? = nil,
                dueKind: DueKind? = nil, kind: TaskKind = .today, note: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.priority = priority
        self.dueMinutes = dueMinutes
        self.dueKind = dueMinutes == nil ? nil : (dueKind ?? .deadline)
        self.kind = kind
        self.note = note
        self.createdAt = createdAt
    }

    /// "by 16:00" / "at 12:00"; nil when the task has no time.
    public var dueText: String? {
        guard let dueMinutes else { return nil }
        return "\((dueKind ?? .deadline).rawValue) \(Self.clock(dueMinutes))"
    }

    /// "HH:MM" for minutes from midnight.
    public static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

/// English singular / plural: `Plural.en(5, "task")` → "tasks", `Plural.en(1, "task")` → "task".
public enum Plural {
    public static func en(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        abs(n) == 1 ? one : (many ?? one + "s")
    }
}
