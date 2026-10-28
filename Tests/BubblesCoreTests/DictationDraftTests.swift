import Foundation
import Testing
import BubblesCore

/// 10:00 today, local time: tasks "by 9:00" are in the past, "by 16:00" are not.
private let morning = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!

private func task(_ title: String, _ priority: Priority = .normal, due: Int? = nil, kind: DueKind? = nil) -> DayTask {
    DayTask(title: title, priority: priority, dueMinutes: due, dueKind: kind, createdAt: morning)
}

private func titles(_ draft: DictationDraft) -> [String] { draft.ordered(now: morning).map(\.task.title) }

@Suite struct DictationDraftTests {
    private let today = DayTask(title: "Позвонить в банк", priority: .important)
    private let carried = DayTask(title: "Ответить бухгалтеру", kind: .carry, note: "from yesterday")
    private let long = DayTask(title: "Выучить испанский", kind: .long, note: "long · day 6")

    // MARK: Existing day

    @Test func existingTasksAreKeptAndCarryIsOfferedChecked() {
        let draft = DictationDraft(existing: [today, carried, long])
        #expect(draft.today.map(\.id) == [today.id])
        #expect(draft.carry.map(\.task.id) == [carried.id, long.id])
        #expect(draft.carry.allSatisfy { $0.included })
        #expect(draft.isOnDesk(today.id))
        #expect(draft.dayInProgress)
        #expect(draft.mode == .addToToday)
    }

    @Test func onlyCarriedTasksIsNotADayInProgress() {
        #expect(!DictationDraft(existing: [carried, long]).dayInProgress)
    }

    @Test func launchListHasTodayAndCheckedCarryOnly() {
        var draft = DictationDraft(existing: [carried, long])
        let parsed = TaskParser.parse("оплатить интернет, записаться к стоматологу")
        draft.append(parsed)
        draft.setIncluded(false, id: carried.id)
        draft.remove(id: parsed[1].id)
        draft.setTitle("  Оплатить интернет за месяц ", id: parsed[0].id)
        #expect(draft.launchList(now: morning).map(\.title) == ["Оплатить интернет за месяц", "Выучить испанский"])
        #expect(draft.launchList(now: morning).map(\.kind) == [.today, .long])
    }

    @Test func replaceDayDropsTasksAlreadyOnTheDeskAddKeepsThem() {
        var draft = DictationDraft(existing: [today])
        draft.append([task("Купить хлеб")])
        #expect(Set(draft.launchList(now: morning).map(\.title)) == ["Позвонить в банк", "Купить хлеб"])
        draft.setMode(.replaceDay)
        #expect(draft.launchList(now: morning).map(\.title) == ["Купить хлеб"])
    }

    @Test func storedManualOrderComesIntoTheDraft() {
        let a = task("Купить хлеб"), b = task("Оплатить интернет", .urgent)
        let order = TaskOrder(pins: [a.id: 0])
        let draft = DictationDraft(existing: [a, b], order: order)
        #expect(titles(draft) == ["Купить хлеб", "Оплатить интернет"])
        #expect(draft.isPinned(a.id))
    }

    // MARK: Parse results

    @Test func absorbKeepsSourceLinesAndLeftoverAcrossDictations() {
        var draft = DictationDraft(existing: [])
        let first = ["срочно оплатить интернет до шестнадцати", "ну вроде всё"]
        draft.absorb(TaskParser.parse(lines: first), lines: first)
        #expect(draft.lines == first)
        #expect(draft.ordered(now: morning).map(\.sourceLine) == [0])
        #expect(draft.leftover.map(\.text) == ["ну вроде всё"])
        #expect(draft.leftover.map(\.sourceLine) == [1])

        draft.absorb(TaskParser.parse(lines: ["купить хлеб"]), lines: ["купить хлеб"])
        #expect(draft.lines.count == 3)
        #expect(draft.ordered(now: morning).first { $0.task.title == "Купить хлеб" }?.sourceLine == 2)
    }

    @Test func retranscribeReplacesWhatTheOldTranscriptGave() {
        var draft = DictationDraft(existing: [today])
        draft.absorb(TaskParseResult(tasks: [], leftover: ["купить продукты забрать посылку"]),
                     lines: ["купить продукты забрать посылку"])
        let edited = ["купить продукты", "забрать посылку"]
        draft.retranscribe(TaskParser.parse(lines: edited), lines: edited)
        #expect(draft.lines == edited)
        #expect(draft.leftover.isEmpty)
        #expect(Set(titles(draft)) == ["Позвонить в банк", "Купить продукты", "Забрать посылку"])
    }

    @Test func leftoverBecomesATaskOrGoesAway() {
        var draft = DictationDraft(existing: [])
        draft.absorb(TaskParseResult(tasks: [], leftover: ["созвон в 12", "ну вроде всё"]), lines: ["созвон в 12", "ну вроде всё"])
        let id = draft.promoteLeftover(draft.leftover[0].id, now: morning)
        let made = draft.ordered(now: morning).first { $0.id == id }
        #expect(made?.task.title == "Созвон")
        #expect(made?.task.dueMinutes == 12 * 60)
        #expect(made?.sourceLine == 0)
        draft.dismissLeftover(draft.leftover[0].id)
        #expect(draft.leftover.isEmpty)
    }

    @Test func addTaskParsesTimeAndUrgencyInTheLine() {
        var draft = DictationDraft(existing: [])
        draft.addTask(text: "срочно отправить счёт до 18", now: morning)
        let added = draft.ordered(now: morning)[0].task
        #expect(added.title == "Отправить счёт")
        #expect(added.priority == .urgent)
        #expect(added.dueMinutes == 18 * 60)
        #expect(added.dueKind == .deadline)
    }

    @Test func withoutAKeyAnAddedLineStaysExactlyAsTyped() {
        // Spec 45: no AI key — a line is one task as written, no time, no urgency, no cutting by rules.
        var draft = DictationDraft(existing: [], keepsTextAsWritten: true)
        draft.addTask(text: "срочно отправить счёт до 18 и купить хлеб", now: morning)
        let rows = draft.ordered(now: morning)
        #expect(rows.map(\.task.title) == ["срочно отправить счёт до 18 и купить хлеб"])
        #expect(rows.first?.task.priority == .normal)
        #expect(rows.first?.task.dueMinutes == nil && rows.first?.task.dueKind == nil)
    }

    @Test func withoutAKeyALeftoverPhraseBecomesATaskAsWritten() {
        var draft = DictationDraft(existing: [], keepsTextAsWritten: true)
        draft.absorb(TaskParseResult(tasks: [], leftover: ["созвон с командой в 12"]), lines: ["созвон с командой в 12"])
        let made = draft.promoteLeftover(draft.leftover[0].id, now: morning)
        let row = draft.ordered(now: morning).first { $0.id == made }
        #expect(row?.task.title == "созвон с командой в 12")
        #expect(row?.task.dueMinutes == nil && row?.task.priority == .normal)
    }

    // MARK: Row actions (screen 4)

    @Test func priorityReordersUnlessTheRowIsPinned() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить хлеб"), task("Оплатить интернет", .urgent), task("Созвон", .important)])
        #expect(titles(draft) == ["Оплатить интернет", "Созвон", "Купить хлеб"])
        let bread = draft.ordered(now: morning)[2].id
        draft.move(id: bread, to: 0, now: morning)
        #expect(titles(draft) == ["Купить хлеб", "Оплатить интернет", "Созвон"])
        #expect(draft.isPinned(bread))
        let call = draft.ordered(now: morning)[2].id
        draft.setPriority(.urgent, id: call)
        draft.setPriority(.normal, id: draft.ordered(now: morning)[1].id)   // "Pay the internet bill"
        #expect(titles(draft) == ["Купить хлеб", "Созвон", "Оплатить интернет"])
    }

    @Test func pillClickCyclesPriorityInBothLists() {
        var draft = DictationDraft(existing: [carried])
        draft.append([DayTask(title: "Оплатить интернет", priority: .urgent)])
        let id = draft.today[0].id
        draft.cyclePriority(id: id)
        #expect(draft.today[0].priority == .important)
        draft.cyclePriority(id: carried.id)
        #expect(draft.carry[0].task.priority == .urgent)
    }

    @Test func timeIsSetAndCleared() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Записаться к стоматологу")])
        let id = draft.today[0].id
        draft.setDue(15 * 60, kind: .at, id: id)
        #expect(draft.today[0].dueText == "at 15:00")
        draft.setDue(nil, kind: nil, id: id)
        #expect(draft.today[0].dueMinutes == nil)
        #expect(draft.today[0].dueKind == nil)
    }

    @Test func splitMakesTwoTasksWithTheSameTimeAndUrgency() {
        var draft = DictationDraft(existing: [])
        let lines = ["важно купить продукты и забрать посылку до 18"]
        draft.absorb(TaskParser.parse(lines: ["важно купить продукты до 18"]), lines: lines)
        let id = draft.today[0].id
        draft.setTitle("Купить продукты и забрать посылку", id: id)
        let other = draft.split(id: id, now: morning)
        #expect(other != nil)
        let rows = draft.ordered(now: morning)
        #expect(rows.map(\.task.title) == ["Купить продукты", "Забрать посылку"])
        #expect(rows.map(\.task.priority) == [.important, .important])
        #expect(rows.map(\.task.dueMinutes) == [18 * 60, 18 * 60])
        #expect(rows.map(\.sourceLine) == [0, 0])
    }

    @Test func splitAtTheCursor() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Позвонить маме купить хлеб")])
        let id = draft.today[0].id
        draft.split(id: id, at: ("Позвонить маме " as NSString).length, now: morning)
        #expect(titles(draft) == ["Позвонить маме", "Купить хлеб"])
    }

    @Test func oneWordCannotBeSplit() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Йога")])
        #expect(draft.split(id: draft.today[0].id, now: morning) == nil)
        #expect(titles(draft) == ["Йога"])
        draft.undo()   // the only step is the append
        #expect(draft.today.isEmpty)
    }

    @Test func mergeWithNextJoinsTwoRows() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить продукты"), task("Забрать посылку", due: 19 * 60, kind: .deadline)])
        draft.setDue(nil, kind: nil, id: draft.today[1].id)
        draft.mergeWithNext(id: draft.today[0].id, now: morning)
        #expect(titles(draft) == ["Купить продукты и забрать посылку"])
    }

    @Test func longToggleSetsKindAndDayNote() {
        var draft = DictationDraft(existing: [])
        draft.append([DayTask(title: "Сделать ремонт")])
        let id = draft.today[0].id
        draft.setLong(true, id: id)
        #expect(draft.today[0].kind == .long)
        #expect(draft.today[0].note == "long · day 1")
        draft.setLong(false, id: id)
        #expect(draft.today[0].kind == .today)
        #expect(draft.today[0].note == nil)
    }

    @Test func removedRowComesBackToItsPlace() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить хлеб"), task("Оплатить интернет"), task("Созвон")])
        let middle = draft.ordered(now: morning)[1].id
        draft.move(id: middle, to: 1, now: morning)   // pinned in the middle
        let removed = draft.remove(id: middle, now: morning)
        #expect(titles(draft) == ["Купить хлеб", "Созвон"])
        draft.append([task("Записаться к стоматологу")])
        draft.restore(removed!, now: morning)
        #expect(titles(draft)[1] == "Оплатить интернет")
        #expect(draft.isPinned(middle))
    }

    @Test func undoRevertsEveryKindOfEdit() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить хлеб"), task("Оплатить интернет")])
        let original = draft
        let id = draft.today[0].id
        draft.setTitle("Купить батон", id: id)
        draft.setPriority(.urgent, id: id)
        draft.remove(id: draft.today[1].id, now: morning)
        draft.setMode(.replaceDay)
        let undone = (0..<4).map { _ in draft.undo() }
        #expect(undone == [true, true, true, true])
        #expect(draft == original)
    }

    @Test func titleThatDoesNotChangeIsNotAnUndoStep() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить хлеб")])
        draft.setTitle("Купить хлеб", id: draft.today[0].id)
        draft.undo()   // undoes the append, not a no-op rename
        #expect(draft.today.isEmpty)
    }

    @Test func emptyTitleBlocksTheLaunch() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить хлеб")])
        #expect(draft.canLaunch(now: morning))
        draft.setTitle("   ", id: draft.today[0].id)
        #expect(draft.emptyTitles == [draft.today[0].id])
        #expect(!draft.canLaunch(now: morning))
    }

    // MARK: Hints

    @Test func duplicatesAreOfferedToMerge() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Купить продукты"), task("Купить хлеб"), task("Купить продукты в магазине", .urgent)])
        let first = draft.today[0].id, third = draft.today[2].id
        #expect(draft.duplicates(now: morning) == [first: third])
        draft.mergeDuplicate(first, now: morning)
        #expect(titles(draft) == ["Купить продукты в магазине", "Купить хлеб"])
        #expect(draft.duplicates(now: morning).isEmpty)
    }

    @Test func dismissedDuplicateIsNotOfferedAgain() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Позвонить маме"), task("позвонить маме")])
        let second = draft.today[1].id
        #expect(draft.duplicates(now: morning).keys.contains(second))
        draft.dismissDuplicate(second)
        #expect(draft.duplicates(now: morning).isEmpty)
    }

    @Test func pastTimeIsFlaggedAndCanMoveToTomorrow() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Оплатить интернет", due: 9 * 60, kind: .deadline), task("Созвон", due: 16 * 60, kind: .at)])
        let past = draft.today[0].id
        #expect(draft.pastDue(now: morning) == [past])
        draft.moveToTomorrow(past)
        #expect(draft.tomorrow.map(\.title) == ["Оплатить интернет"])
        #expect(draft.launchList(now: morning).map(\.title) == ["Созвон"])
    }

    @Test func summaryNamesFoundLeftoverAndTopTask() {
        var draft = DictationDraft(existing: [])
        #expect(draft.summary(now: morning) == "No tasks found — split the lines or add tasks by hand")
        let lines = ["купить хлеб", "срочно оплатить интернет", "ну вроде всё"]
        draft.absorb(TaskParser.parse(lines: lines), lines: lines)
        #expect(draft.summary(now: morning) == "Found 2 tasks · 1 phrase didn't become a task · top: Оплатить интернет")
    }

    @Test func moreThanTwentyTasksWarnAboutTheQueue() {
        var draft = DictationDraft(existing: [])
        draft.append((1...20).map { task("Задача номер \($0)") })
        #expect(draft.queueNote(now: morning) == nil)
        draft.append([task("Ещё одна задача")])
        #expect(draft.queueNote(now: morning) == "8 fit on the desk, the rest wait in the “+13” queue")
        draft.makeTailLong(keeping: 8, now: morning)
        #expect(draft.ordered(now: morning).filter { $0.task.kind == .long }.count == 13)
    }

    @Test func launchOrderKeepsPinnedPositions() {
        var draft = DictationDraft(existing: [])
        draft.append([task("Оплатить интернет", .urgent), task("Купить хлеб")])
        let bread = draft.today[1].id
        draft.move(id: bread, to: 0, now: morning)
        let order = draft.launchOrder(now: morning)
        #expect(order.pins == [bread: 0])
        #expect(order.apply(draft.launchList(now: morning), now: morning).map(\.title) == ["Купить хлеб", "Оплатить интернет"])
    }
}

@Suite struct TaskOrderTests {
    @Test func pinnedTaskKeepsItsSlotOthersFollowRank() {
        let a = task("Купить хлеб"), b = task("Оплатить интернет", .urgent), c = task("Созвон", .important)
        #expect(TaskOrder().apply([a, b, c], now: morning).map(\.title) == ["Оплатить интернет", "Созвон", "Купить хлеб"])
        let order = TaskOrder(pins: [a.id: 1])
        #expect(order.apply([a, b, c], now: morning).map(\.title) == ["Оплатить интернет", "Купить хлеб", "Созвон"])
    }

    @Test func pinBeyondTheEndGoesLast() {
        let a = task("Купить хлеб", .urgent), b = task("Оплатить интернет")
        #expect(TaskOrder(pins: [a.id: 7]).apply([a, b], now: morning).map(\.title) == ["Оплатить интернет", "Купить хлеб"])
    }
}

@Suite struct DeskTaskEditorTests {
    @Test func editsAreUndoneAndClosedTasksDropOut() {
        let a = task("Купить хлеб"), b = task("Оплатить интернет", .urgent)
        var editor = DeskTaskEditor(tasks: [a, b])
        editor.edit { $0.setTitle("Купить батон", id: a.id) }
        #expect(editor.tasks.first { $0.id == a.id }?.title == "Купить батон")
        let undone = editor.undo()
        #expect(undone)
        #expect(editor.tasks.first { $0.id == a.id }?.title == "Купить хлеб")

        editor.edit { $0.move(id: a.id, to: 0, now: morning) }
        editor.sync([b])   // "Buy bread" was closed on the desk
        #expect(editor.tasks.map(\.id) == [b.id])
        #expect(editor.order.pins.isEmpty)
        #expect(!editor.canUndo)
    }

    @Test func syncPicksUpNewTasksAndKeepsPins() {
        let a = task("Купить хлеб"), b = task("Оплатить интернет", .urgent)
        var editor = DeskTaskEditor(tasks: [a, b])
        editor.edit { $0.move(id: a.id, to: 0, now: morning) }
        let c = task("Созвон", .important)
        editor.sync([a, b, c])
        #expect(editor.ordered(now: morning).map(\.title) == ["Купить хлеб", "Оплатить интернет", "Созвон"])
    }
}

@Suite struct DraftTextTests {
    @Test func customSeparatorWordSplitsLines() {
        #expect(DraftText.splitLines(["купить хлеб Следующая оплатить интернет", "созвон"], separator: "следующая")
                == ["купить хлеб", "оплатить интернет", "созвон"])
        #expect(DraftText.splitLines(["позвонить маме, ещё задача купить хлеб"], separator: "ещё задача")
                == ["позвонить маме", "купить хлеб"])
        #expect(DraftText.splitLines(["купить хлеб"], separator: "  ") == ["купить хлеб"])
        #expect(DraftText.splitLines(["buy bread Next pay the rent", "team call"], separator: "next")
                == ["buy bread", "pay the rent", "team call"])
    }

    @Test func mergedTitleReadsAsOnePhrase() {
        #expect(DraftText.mergedTitle("Купить продукты.", "Забрать посылку") == "Купить продукты и забрать посылку")
        #expect(DraftText.mergedTitle("Отправить счёт", "СДЭК забрать") == "Отправить счёт и СДЭК забрать")
        #expect(DraftText.mergedTitle("Buy groceries.", "Pick up the parcel") == "Buy groceries and pick up the parcel")
        #expect(DraftText.splitTitle("Buy bread and then call mom") ?? ("", "") == ("Buy bread", "Call mom"))
    }
}

@Suite struct TaskTrailTests {
    @Test func historyLine() {
        var trail = TaskTrail()
        #expect(trail.historyLine == "Not surfaced yet")
        trail.surfaced = 2
        trail.snoozedMinutes = [15]
        #expect(trail.historyLine == "Surfaced 2 times · snoozed for 15 min")
        trail.snoozedMinutes = [15, 60]
        #expect(trail.historyLine == "Surfaced 2 times · snoozed 2 times")
    }

    @Test func originLine() {
        var trail = TaskTrail()
        #expect(trail.originLine == nil)
        trail.dictatedAt = Calendar.current.date(bySettingHour: 9, minute: 12, second: 0, of: Date())
        #expect(trail.originLine == "dictated at 09:12")
    }
}
