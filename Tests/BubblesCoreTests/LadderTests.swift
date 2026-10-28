import Foundation
import Testing
import BubblesCore

@Suite struct LadderTests {
    let scheduler = LadderScheduler()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
    }

    /// The old defaults (surface every 45 min, takeover 15 min before): since F2 they are the "Gentle" preset.
    private func gentle() -> BubbleSettings {
        var settings = BubbleSettings()
        LadderPreset.gentle.apply(to: &settings)
        return settings
    }

    private func next(_ ranked: [DayTask], _ settings: BubbleSettings? = nil, now: Date,
                      lastSurfaceAt: Date? = nil, snoozedUntil: Date? = nil, takenOver: Set<UUID> = []) -> LadderEvent? {
        scheduler.next(ranked: ranked, settings: settings ?? gentle(), now: now,
                       lastSurfaceAt: lastSurfaceAt ?? now, snoozedUntil: snoozedUntil, takenOver: takenOver)
    }

    @Test func deadlineTakesOverMMinutesBefore() {
        let task = DayTask(title: "Send the invoice to the client", priority: .urgent, dueMinutes: 16 * 60, dueKind: .deadline)
        #expect(next([task], now: at(15, 40)) == nil)
        #expect(next([task], now: at(15, 45)) == .takeover(task.id))
        #expect(next([task], now: at(15, 59)) == .takeover(task.id))
        #expect(next([task], now: at(16, 30)) == .takeover(task.id))   // overdue stays until closed
    }

    @Test func takeoverWindowFollowsSetting() {
        var settings = gentle()
        settings.takeoverBeforeMinutes = 30
        let task = DayTask(title: "Pay the internet bill", dueMinutes: 18 * 60, dueKind: .deadline)
        #expect(next([task], settings, now: at(17, 29)) == nil)
        #expect(next([task], settings, now: at(17, 30)) == .takeover(task.id))
    }

    @Test func tasksWithoutTimeUseEndOfDay() {
        let task = DayTask(title: "Book a dentist appointment")
        #expect(next([task], now: at(19, 0)) == nil)
        #expect(next([task], now: at(19, 50)) == .takeover(task.id))   // end of day 20:00, 15 min before

        var noEnd = gentle()
        noEnd.endOfDayMinutes = nil
        #expect(next([task], noEnd, now: at(23, 0)) == nil)
    }

    // MARK: - F2: background only by default

    @Test func freshSettingsNeverSurfaceNorTakeOver() {
        let fresh = BubbleSettings()
        let overdue = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 9 * 60, dueKind: .deadline)
        let plain = DayTask(title: "Buy bread")
        for hour in [9, 15, 19, 23] {
            #expect(scheduler.next(ranked: [overdue, plain], settings: fresh, now: at(hour), lastSurfaceAt: at(0),
                                   snoozedUntil: nil, takenOver: []) == nil)
        }
    }

    @Test func afterEndOfDayTasksWithoutTimeDoNotTakeOver() {
        let plain = DayTask(title: "Book a dentist appointment")
        let carried = DayTask(title: "Renew passport", kind: .carry, note: "from yesterday")
        #expect(next([plain, carried], now: at(19, 45)) == .takeover(plain.id))   // inside the window, as before
        #expect(next([plain, carried], now: at(20, 0)) == nil)                    // the end of the day passed
        #expect(next([plain, carried], now: at(23, 30)) == nil)
        #expect(next([plain, carried], now: at(1, 0)) == nil)                     // night
    }

    @Test func afterEndOfDayAnExplicitDeadlineStillTakesOver() {
        let task = DayTask(title: "Send the invoice to the client", dueMinutes: 18 * 60, dueKind: .deadline)
        #expect(next([task], now: at(23, 0)) == .takeover(task.id))
    }

    @Test func appointmentsNeverTakeOver() {
        let meeting = DayTask(title: "Team call", priority: .important, dueMinutes: 16 * 60, dueKind: .at)
        #expect(next([meeting], now: at(15, 55)) == nil)
        #expect(next([meeting], now: at(21, 0)) == nil)
    }

    @Test func alreadyTakenOverTaskIsSkipped() {
        let a = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 16 * 60, dueKind: .deadline)
        let b = DayTask(title: "Send the invoice to the client", dueMinutes: 16 * 60 + 5, dueKind: .deadline)
        #expect(next([a, b], now: at(15, 55), takenOver: [a.id]) == .takeover(b.id))
        #expect(next([a, b], now: at(15, 55), takenOver: [a.id, b.id]) == nil)
    }

    @Test func topTaskSurfacesEveryNMinutes() {
        let top = DayTask(title: "Renew passport", priority: .urgent)
        let other = DayTask(title: "Buy bread")
        let now = at(11)
        #expect(next([top, other], now: now, lastSurfaceAt: now.addingTimeInterval(-30 * 60)) == nil)
        #expect(next([top, other], now: now, lastSurfaceAt: now.addingTimeInterval(-45 * 60)) == .surface(top.id))
    }

    @Test func snoozePostponesSurfacing() {
        let top = DayTask(title: "Renew passport")
        let now = at(11)
        let long = now.addingTimeInterval(-90 * 60)
        #expect(next([top], now: now, lastSurfaceAt: long, snoozedUntil: now.addingTimeInterval(60)) == nil)
        #expect(next([top], now: now, lastSurfaceAt: long, snoozedUntil: now.addingTimeInterval(-60)) == .surface(top.id))
    }

    @Test func bothOffMeansBackgroundOnly() {
        var off = gentle()
        off.surfaceEveryMinutes = nil
        off.takeoverBeforeMinutes = nil
        let overdue = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 9 * 60, dueKind: .deadline)
        let now = at(21)
        #expect(next([overdue], off, now: now, lastSurfaceAt: now.addingTimeInterval(-86_400)) == nil)
    }

    @Test func hiddenBubblesDoNotSurfaceButStillTakeOver() {
        var hidden = gentle()
        hidden.hidden = .forever
        let plain = DayTask(title: "Buy bread")
        let now = at(11)
        #expect(next([plain], hidden, now: now, lastSurfaceAt: now.addingTimeInterval(-3 * 3600)) == nil)
        let due = DayTask(title: "Pay the internet bill", dueMinutes: 11 * 60 + 10, dueKind: .deadline)
        #expect(next([due], hidden, now: now) == .takeover(due.id))
    }

    @Test func emptyDayHasNoEvents() {
        #expect(next([], now: at(19, 59), lastSurfaceAt: at(6)) == nil)
    }

    // MARK: - T08: "15 more minutes", move to tomorrow, calls

    private func state(lastSurfaceAt: Date? = nil, takenOver: Set<UUID> = [], extendedUntil: [UUID: Date] = [:]) -> LadderState {
        LadderState(lastSurfaceAt: lastSurfaceAt, takenOver: takenOver, extendedUntil: extendedUntil)
    }

    @Test func oneExtensionPerTaskThenTheTakeoverComesBack() throws {
        let task = DayTask(title: "Send the invoice to the client", dueMinutes: 16 * 60, dueKind: .deadline)
        let settings = gentle()
        var s = state(lastSurfaceAt: at(15, 45), takenOver: [task.id])
        #expect(scheduler.canExtend(task.id, settings: settings, state: s))

        let back = try #require(scheduler.extend(task.id, settings: settings, now: at(15, 46), state: &s))
        #expect(back == at(16, 1))
        #expect(scheduler.next(ranked: [task], settings: settings, now: at(15, 50), state: s) == nil)
        #expect(scheduler.next(ranked: [task], settings: settings, now: at(16, 1), state: s) == .takeover(task.id))

        s.takenOver.insert(task.id)   // shown again
        #expect(!scheduler.canExtend(task.id, settings: settings, state: s))
        #expect(scheduler.extend(task.id, settings: settings, now: at(16, 2), state: &s) == nil)
        #expect(s.takenOver.contains(task.id))
    }

    @Test func extensionCanBeTurnedOff() {
        let task = DayTask(title: "Pay the internet bill", dueMinutes: 16 * 60, dueKind: .deadline)
        var settings = gentle()
        settings.allowExtension = false
        var s = state(takenOver: [task.id])
        #expect(!scheduler.canExtend(task.id, settings: settings, state: s))
        #expect(scheduler.extend(task.id, settings: settings, now: at(15, 50), state: &s) == nil)
    }

    @Test func movingToTomorrowIsAllowedOnlyBeforeTheTakeoverStarts() {
        let task = DayTask(title: "Send the invoice to the client", dueMinutes: 16 * 60, dueKind: .deadline)
        let settings = gentle()   // takeover 15 min before
        #expect(scheduler.canMoveToTomorrow(task, settings: settings, now: at(15, 44), state: state()))
        #expect(!scheduler.canMoveToTomorrow(task, settings: settings, now: at(15, 45), state: state()))
        #expect(!scheduler.canMoveToTomorrow(task, settings: settings, now: at(15, 30), state: state(takenOver: [task.id])))
        #expect(!scheduler.canMoveToTomorrow(task, settings: settings, now: at(15, 30),
                                             state: state(extendedUntil: [task.id: at(16, 1)])))

        var off = gentle()
        off.takeoverBeforeMinutes = nil
        #expect(scheduler.canMoveToTomorrow(task, settings: off, now: at(17), state: state()))
        let meeting = DayTask(title: "Team call", dueMinutes: 12 * 60, dueKind: .at)
        #expect(scheduler.canMoveToTomorrow(meeting, settings: settings, now: at(13), state: state()))
    }

    @Test func movedTaskComesBackTomorrowAsCarriedOver() throws {
        var shelf = TomorrowShelf()
        let plain = DayTask(title: "Book a dentist appointment", priority: .important)
        let long = DayTask(title: "Renew passport", kind: .long, note: "long · day 2")
        shelf.put(plain, now: at(11))
        shelf.put(long, now: at(11))
        #expect(shelf.contains(plain.id))
        #expect(shelf.takeDue(now: at(23, 59)).isEmpty)   // same day: stays on the shelf

        let back = shelf.takeDue(now: at(11).addingTimeInterval(86_400))
        #expect(back.map(\.id) == [plain.id, long.id])
        try #require(back.count == 2)
        #expect(back[0].kind == .carry && back[0].note == "from yesterday" && back[0].priority == .important)
        #expect(back[1].kind == .long && back[1].note == "long · day 2")
        #expect(shelf.items.isEmpty)
    }

    @Test func callsPostponeTheTakeoverAndItComesRightAfter() {
        let task = DayTask(title: "Pay the internet bill", priority: .urgent, dueMinutes: 16 * 60, dueKind: .deadline)
        let s = state(lastSurfaceAt: at(15))
        #expect(scheduler.next(ranked: [task], settings: gentle(), now: at(15, 50), state: s, busy: true) == nil)
        #expect(scheduler.next(ranked: [task], settings: gentle(), now: at(16, 20), state: s, busy: true) == nil)
        #expect(scheduler.next(ranked: [task], settings: gentle(), now: at(16, 20), state: s, busy: false) == .takeover(task.id))
    }

    @Test func callsPostponeSurfacingToo() {
        let top = DayTask(title: "Renew passport")
        let s = state(lastSurfaceAt: at(9))
        #expect(scheduler.next(ranked: [top], settings: gentle(), now: at(11), state: s, busy: true) == nil)
        #expect(scheduler.next(ranked: [top], settings: gentle(), now: at(11), state: s) == .surface(top.id))
    }

    @Test func pauseDuringCallsCanBeTurnedOff() {
        var settings = gentle()
        settings.pauseDuringCalls = false
        let task = DayTask(title: "Pay the internet bill", dueMinutes: 16 * 60, dueKind: .deadline)
        #expect(scheduler.next(ranked: [task], settings: settings, now: at(15, 50), state: state(lastSurfaceAt: at(15, 50)),
                               busy: true) == .takeover(task.id))
    }

    @Test func longTasksWithoutTimeDoNotTakeOverAtEndOfDay() {
        let long = DayTask(title: "Kitchen renovation", kind: .long, note: "long · day 3")
        #expect(next([long], now: at(19, 55)) == nil)
        let longWithDeadline = DayTask(title: "Hand in the report", dueMinutes: 18 * 60, dueKind: .deadline, kind: .long)
        #expect(next([longWithDeadline], now: at(17, 50)) == .takeover(longWithDeadline.id))
    }

    // MARK: - Day summary

    @Test func eveningSummaryAtEndOfDayOncePerDay() {
        #expect(!DaySummaryRule.eveningDue(now: at(19, 59), endOfDayMinutes: 20 * 60, shownDay: nil, hasOpenTasks: true))
        #expect(DaySummaryRule.eveningDue(now: at(20), endOfDayMinutes: 20 * 60, shownDay: nil, hasOpenTasks: true))
        let today = Calendar.current.startOfDay(for: at(20))
        #expect(!DaySummaryRule.eveningDue(now: at(21), endOfDayMinutes: 20 * 60, shownDay: today, hasOpenTasks: true))
        #expect(!DaySummaryRule.eveningDue(now: at(21), endOfDayMinutes: 20 * 60, shownDay: nil, hasOpenTasks: false))
        #expect(!DaySummaryRule.eveningDue(now: at(23), endOfDayMinutes: nil, shownDay: nil, hasOpenTasks: true))
    }

    @Test func daySummaryOpensItselfOnlyWhenTheLadderIsOn() {
        let fresh = BubbleSettings()
        #expect(!DaySummaryRule.opensItself(fresh))              // "Background only": a menu line instead of a window
        #expect(DaySummaryRule.opensItself(gentle()))
        var surfaceOnly = fresh
        surfaceOnly.surfaceEveryMinutes = 60
        #expect(DaySummaryRule.opensItself(surfaceOnly))
        var takeoverOnly = fresh
        takeoverOnly.takeoverBeforeMinutes = 5
        #expect(DaySummaryRule.opensItself(takeoverOnly))
        var off = gentle()
        LadderPreset.backgroundOnly.apply(to: &off)
        #expect(!DaySummaryRule.opensItself(off))
    }

    @Test func morningSummaryWhenTheEveningWasMissed() {
        let calendar = Calendar.current
        let morning = at(9)
        let today = calendar.startOfDay(for: morning)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let before = calendar.date(byAdding: .day, value: -2, to: today)!
        #expect(DaySummaryRule.morningDue(now: morning, shownDay: before, hasCarriedTasks: true))
        #expect(DaySummaryRule.morningDue(now: morning, shownDay: nil, hasCarriedTasks: true))
        #expect(!DaySummaryRule.morningDue(now: morning, shownDay: yesterday, hasCarriedTasks: true))   // seen last evening
        #expect(!DaySummaryRule.morningDue(now: morning, shownDay: before, hasCarriedTasks: false))
    }
}
