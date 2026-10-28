import Foundation
import Testing
import BubblesCore

/// A clock the test can move forward.
final class TestClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    func advance(days: Int) { date = Calendar.current.date(byAdding: .day, value: days, to: date)! }
}

@MainActor @Suite struct TaskStoreTests {
    let fileURL: URL
    let clock: TestClock

    init() {
        // $TMPDIR first: inside restricted sandboxes Foundation's temporaryDirectory points at a denied folder.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        fileURL = tmp
            .appendingPathComponent("bubbles-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        clock = TestClock(noon)
    }

    private func makeStore() -> TaskStore {
        let clock = self.clock
        return TaskStore(fileURL: fileURL, now: { clock.date })
    }

    @Test func mutationsPersistAcrossInstances() {
        let store = makeStore()
        let a = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 960, dueKind: .deadline)
        let b = DayTask(title: "Book a dentist appointment")
        store.add([a, b])
        var edited = b
        edited.title = "Book a dentist appointment for Friday"
        store.update(edited)

        let reloaded = makeStore()
        #expect(reloaded.tasks == [a, edited])
    }

    @Test func addingAnExistingIdReplacesInsteadOfDuplicating() {
        let store = makeStore()
        var task = DayTask(title: "Pay the internet bill")
        let other = DayTask(title: "Book a dentist appointment")
        store.add([task, other])
        task.title = "Pay the internet bill by Friday"
        store.add([task])
        store.add([other, other])
        #expect(store.tasks == [task, other])
        #expect(makeStore().tasks == [task, other])
        store.replaceDay(with: [other, task, other])
        #expect(store.tasks == [other, task])
    }

    @Test func completeRemovesTaskAndCountsIt() {
        let store = makeStore()
        let a = DayTask(title: "Pay the internet bill")
        let b = DayTask(title: "Renew passport")
        store.add([a, b])
        store.complete(id: a.id, proof: "paid in the bank app")
        #expect(store.tasks == [b])
        #expect(store.doneToday == 1)

        let reloaded = makeStore()
        #expect(reloaded.tasks == [b])
        #expect(reloaded.doneToday == 1)
    }

    @Test func replaceDayReplacesAllTasks() {
        let store = makeStore()
        store.add([DayTask(title: "Old task")])
        let fresh = [DayTask(title: "New 1"), DayTask(title: "New 2")]
        store.replaceDay(with: fresh)
        #expect(store.tasks == fresh)
        #expect(makeStore().tasks == fresh)
    }

    @Test func carryOverCandidatesAreCarryAndLongOnly() {
        let store = makeStore()
        let today = DayTask(title: "Today")
        let carry = DayTask(title: "From yesterday", kind: .carry, note: "from yesterday")
        let long = DayTask(title: "Long", kind: .long, note: "long · day 2")
        store.add([today, carry, long])
        #expect(store.carryOverCandidates() == [carry, long])
    }

    @Test func notesSavedByTheRussianInterfaceReadInEnglish() {
        let carry = DayTask(title: "Оплатить интернет", kind: .carry, note: "со вчера")
        let long = DayTask(title: "Выучить испанский", kind: .long, note: "длинная · 6-й день")
        let other = DayTask(title: "Task", note: "something else")
        makeStore().add([carry, long, other])
        let loaded = makeStore().tasks
        #expect(loaded.map(\.note) == ["from yesterday", "long · day 6", "something else"])
        #expect(loaded.first?.title == "Оплатить интернет")   // titles are the person's words: untouched
    }

    @Test func corruptFileGivesEmptyStateAndRecovers() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: fileURL)
        let store = makeStore()
        #expect(store.tasks.isEmpty)
        #expect(store.doneToday == 0)
        #expect(store.streak == 0)
        store.add([DayTask(title: "Pay the internet bill")])
        #expect(makeStore().tasks.count == 1)
    }

    @Test func missingDirectoryIsCreatedOnFirstWrite() {
        let store = makeStore()
        #expect(store.tasks.isEmpty)
        store.add([DayTask(title: "Pay the internet bill")])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func rolloverCarriesTodayAndAgesLongTasks() {
        let store = makeStore()
        let today = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 960, dueKind: .deadline)
        let long = DayTask(title: "Learn Spanish", kind: .long, note: "long · day 6")
        let done = DayTask(title: "Send the invoice to the client")
        store.add([today, long, done])
        store.complete(id: done.id, proof: "sent by email")

        clock.advance(days: 1)
        let next = makeStore()
        next.rolloverIfNeeded()

        let carried = next.tasks.first { $0.id == today.id }
        #expect(carried?.kind == .carry)
        #expect(carried?.note == "from yesterday")
        #expect(carried?.title == "Pay the internet bill")
        #expect(next.tasks.first { $0.id == long.id }?.note == "long · day 7")
        #expect(next.tasks.first { $0.id == long.id }?.kind == .long)
        #expect(next.doneToday == 0)
        #expect(next.streak == 1)   // yesterday: one closed, nothing burned

        next.rolloverIfNeeded()     // same day again: no double counting
        #expect(next.streak == 1)
        #expect(next.tasks.first { $0.id == long.id }?.note == "long · day 7")
        #expect(makeStore().streak == 1)
    }

    @Test func rolloverInsideOneRunningInstance() {
        let store = makeStore()
        let task = DayTask(title: "Renew passport")
        store.add([task])
        clock.advance(days: 1)
        store.rolloverIfNeeded()
        #expect(store.tasks.first?.kind == .carry)
        #expect(store.streak == 0)  // nothing was closed yesterday
    }

    @Test func burnResetsStreakAndBlocksNextIncrement() {
        let store = makeStore()
        let a = DayTask(title: "Pay the internet bill"), b = DayTask(title: "Send the invoice to the client")
        store.add([a, b])
        store.complete(id: a.id, proof: "paid")
        clock.advance(days: 1)
        store.rolloverIfNeeded()
        #expect(store.streak == 1)

        let c = DayTask(title: "Book a dentist appointment")
        store.add([c])
        store.complete(id: c.id, proof: "booked for Friday")
        store.burn(id: b.id)
        #expect(store.streak == 0)
        #expect(!store.tasks.contains { $0.id == b.id })
        #expect(makeStore().streak == 0)

        clock.advance(days: 1)
        store.rolloverIfNeeded()
        #expect(store.streak == 0)  // something burned yesterday → no +1
    }

    @Test func streakResetsAfterADayWithNothingClosed() {
        let store = makeStore()
        let a = DayTask(title: "Pay the internet bill")
        store.add([a])
        store.complete(id: a.id, proof: "paid")
        clock.advance(days: 1)
        store.rolloverIfNeeded()
        #expect(store.streak == 1)
        clock.advance(days: 1)
        store.rolloverIfNeeded()
        #expect(store.streak == 0)
    }
}
