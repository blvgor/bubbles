import CoreGraphics
import Foundation

/// Rules behind the desk UI (T03 in `interfaces.md`), kept here so they are testable without a screen.

/// The first-launch example: neutral tasks, shown until the user dictates their own day.
public enum SampleDay {
    public static func tasks(now: Date = Date()) -> [DayTask] {
        [
            DayTask(title: "Pay the internet bill", priority: .urgent, createdAt: now),
            DayTask(title: "Renew passport", priority: .important, dueMinutes: 18 * 60, dueKind: .deadline, createdAt: now),
            DayTask(title: "Send the invoice to the client", priority: .important, createdAt: now),
            DayTask(title: "Book a dentist appointment", createdAt: now),
            DayTask(title: "Buy a gift", createdAt: now),
        ]
    }
}

/// "What did you do? One sentence" + "Hold for N seconds" (`BubbleSettings.holdSeconds`): shared by the detail card and the takeover.
public enum ProofHold {
    public static let minimumLength = 3
    public static let rejectedLabel = "First write what you did"

    /// At least three characters once surrounding spaces are trimmed.
    public static func isValid(_ proof: String) -> Bool {
        proof.trimmingCharacters(in: .whitespacesAndNewlines).count >= minimumLength
    }

    public static func idleLabel(seconds: Double) -> String {
        "Hold for \(Int(seconds.rounded())) \(Plural.en(Int(seconds.rounded()), "second"))"
    }

    /// The card's hint under the button: "Hold Space or the button for N seconds".
    public static func holdHint(seconds: Double) -> String {
        let n = Int(seconds.rounded())
        return "Hold Space or the button for \(n) \(Plural.en(n, "second"))"
    }

    /// 0...1 fill of the button.
    public static func progress(elapsed: Double, seconds: Double) -> Double {
        guard seconds > 0 else { return 1 }
        return min(1, max(0, elapsed / seconds))
    }

    /// "Hold… N" with the seconds left rounded up, then "Done".
    public static func holdingLabel(elapsed: Double, seconds: Double) -> String {
        let p = progress(elapsed: elapsed, seconds: seconds)
        guard p < 1 else { return "Done" }
        return "Hold… \(Int(((1 - p) * seconds).rounded(.up)))"
    }
}

/// "Hide bubbles": for an hour / until tomorrow (08:00) / until turned back on.
public enum HideOption: CaseIterable, Sendable {
    case hour, tomorrow, forever

    public var label: String {
        switch self {
        case .hour: "For an hour"
        case .tomorrow: "Until tomorrow"
        case .forever: "Until I turn them on"
        }
    }

    public func hiddenState(now: Date = Date(), calendar: Calendar = .current) -> HiddenState {
        switch self {
        case .hour:
            return .until(now.addingTimeInterval(3600))
        case .tomorrow:
            let start = calendar.startOfDay(for: now)
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            return .until(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow)
        case .forever:
            return .forever
        }
    }
}

extension HiddenState {
    /// "Hidden until 15:30", "Hidden until tomorrow 08:00", "Bubbles are off"; nil when visible.
    public func menuText(now: Date = Date(), calendar: Calendar = .current) -> String? {
        switch self {
        case .visible:
            return nil
        case .forever:
            return "Bubbles are off"
        case .until(let date):
            let c = calendar.dateComponents([.hour, .minute], from: date)
            let clock = DayTask.clock((c.hour ?? 0) * 60 + (c.minute ?? 0))
            return calendar.isDate(date, inSameDayAs: now) ? "Hidden until \(clock)" : "Hidden until tomorrow \(clock)"
        }
    }
}

/// The menu panel header.
public enum MenuStatus {
    public static let empty = "No tasks. Click the microphone"

    /// "N tasks · K done · S-day streak".
    public static func line(taskCount: Int, done: Int, streak: Int) -> String {
        guard taskCount > 0 else { return empty }
        return "\(taskCount) \(Plural.en(taskCount, "task")) · \(done) done · \(streak)-day streak"
    }
}

/// How much a bubble shows: rank ≥ 3 drops the due line and keeps two title lines; under 44 pt the pill is a dot.
public enum BubbleSizeClass: Equatable, Sendable {
    case regular, small, tiny

    public static let tinyRadius: CGFloat = 44

    public init(rank: Int, targetRadius: CGFloat) {
        if targetRadius < Self.tinyRadius { self = .tiny } else if rank >= 3 { self = .small } else { self = .regular }
    }
}

/// The desk window holds the background bubbles and the mic; the float window holds the surfaced bubble.
public enum DeskLayer: Sendable { case desk, float }

public enum DeskTarget: Equatable, Sendable { case bubble(UUID), mic }

/// What is under the cursor in one overlay window. Nil means the click belongs to whatever is below,
/// so the window should ignore the mouse this frame.
public enum DeskHit {
    public static let micRadius: CGFloat = 32

    /// `point` and `mic` are in window coordinates (bottom-left origin), like `PhysicsWorld`.
    public static func target(at point: CGPoint, world: PhysicsWorld, layer: DeskLayer, mic: CGPoint?,
                              bubblesHidden: Bool) -> DeskTarget? {
        if !bubblesHidden {
            let hit = world.bodies.first { body in
                !body.isWaiting && body.surfaced == (layer == .float)
                    && hypot(body.position.x - point.x, body.position.y - point.y) <= body.radius
            }
            if let hit { return .bubble(hit.id) }
        }
        if layer == .desk, let mic, hypot(mic.x - point.x, mic.y - point.y) <= micRadius { return .mic }
        return nil
    }
}
