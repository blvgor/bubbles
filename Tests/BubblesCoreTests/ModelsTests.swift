import Foundation
import Testing
import BubblesCore

@Suite struct ModelsTests {
    @Test func dueTextShowsKindAndClock() {
        #expect(DayTask(title: "a", dueMinutes: 960, dueKind: .deadline).dueText == "by 16:00")
        #expect(DayTask(title: "b", dueMinutes: 9 * 60 + 5, dueKind: .at).dueText == "at 09:05")
        #expect(DayTask(title: "c").dueText == nil)
        #expect(DayTask(title: "d", dueKind: .at).dueKind == nil)
    }

    @Test func priorityChipCyclesAndLabels() {
        #expect(Priority.urgent.next == .important)
        #expect(Priority.important.next == .normal)
        #expect(Priority.normal.next == .urgent)
        #expect(Priority.allCases.map(\.label) == ["Normal", "Important", "Urgent"])
    }

    @Test func taskRoundTripsThroughJSON() throws {
        let task = DayTask(title: "Renew passport", priority: .important, dueMinutes: 600, dueKind: .deadline,
                           kind: .long, note: "long · day 2", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        let data = try JSONEncoder().encode(task)
        #expect(try JSONDecoder().decode(DayTask.self, from: data) == task)
    }

    @Test func dueKindSavedByTheRussianInterfaceStillReads() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","title":"a","priority":1,"dueMinutes":960,"dueKind":"до","kind":"today","createdAt":0},"#
            + #"{"id":"\#(UUID().uuidString)","title":"b","priority":1,"dueMinutes":600,"dueKind":"в","kind":"today","createdAt":0}]"#
        let tasks = try JSONDecoder().decode([DayTask].self, from: Data(json.utf8))
        #expect(tasks.map(\.dueKind) == [.deadline, .at])
        #expect(tasks.map(\.dueText) == ["by 16:00", "at 10:00"])
    }
}

@Suite struct PluralTests {
    @Test func englishForms() {
        #expect([0, 1, 2, 21].map { Plural.en($0, "task") } == ["tasks", "task", "tasks", "tasks"])
        #expect(Plural.en(1, "person", "people") == "person")
        #expect(Plural.en(3, "person", "people") == "people")
    }
}
