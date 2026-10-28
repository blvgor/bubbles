import Foundation
import Testing
import BubblesCore

@Suite struct RankerTests {
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    @Test func scoreFollowsPrototypeFormula() {
        let urgentSoon = DayTask(title: "a", priority: .urgent, dueMinutes: 630, dueKind: .deadline)
        // 3*100 + max(0, 60 - 30/10) = 357
        #expect(Ranker.score(urgentSoon, nowMinutes: 600) == 357)
        let carried = DayTask(title: "b", priority: .normal, kind: .carry)
        #expect(Ranker.score(carried, nowMinutes: 600) == 115)
        let far = DayTask(title: "c", priority: .important, dueMinutes: 1400, dueKind: .at)
        #expect(Ranker.score(far, nowMinutes: 600) == 200)
    }

    @Test func urgentWithNearestDeadlineComesFirst() {
        let a = DayTask(title: "Important, no time", priority: .important)
        let b = DayTask(title: "Urgent by 18", priority: .urgent, dueMinutes: 18 * 60, dueKind: .deadline)
        let c = DayTask(title: "Urgent by 16", priority: .urgent, dueMinutes: 16 * 60, dueKind: .deadline)
        let d = DayTask(title: "From yesterday", priority: .normal, kind: .carry)
        let ranked = Ranker.rank([a, b, c, d], now: at(12))
        #expect(ranked.map(\.title) == ["Urgent by 16", "Urgent by 18", "Important, no time", "From yesterday"])
    }

    @Test func equalScoresKeepInputOrder() {
        let tasks = (1...6).map { DayTask(title: "Task \($0)") }
        #expect(Ranker.rank(tasks, now: at(9)).map(\.id) == tasks.map(\.id))
        let reversed = Array(tasks.reversed())
        #expect(Ranker.rank(reversed, now: at(9)).map(\.id) == reversed.map(\.id))
    }
}
