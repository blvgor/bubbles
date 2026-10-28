import Foundation
import Testing
import BubblesCore

@Suite struct TaskParserTests {
    struct Expected { let title: String; let priority: Priority; let due: Int?; let kind: DueKind? }

    @Test func sampleDictationGivesFiveTasksLikeThePrototype() {
        let text = "Так, сегодня срочно оплатить интернет до 16, потом созвон с командой в 12, купить продукты, обязательно отправить счёт клиенту до 18 и записаться к стоматологу"
        let tasks = TaskParser.parse(text)
        // Worked out by hand from parse() in prototype/index.html.
        let expected = [
            Expected(title: "Оплатить интернет", priority: .urgent, due: 16 * 60, kind: .deadline),
            Expected(title: "Созвон с командой", priority: .important, due: 12 * 60, kind: .at),
            Expected(title: "Купить продукты", priority: .normal, due: nil, kind: nil),
            Expected(title: "Отправить счёт клиенту", priority: .urgent, due: 18 * 60, kind: .deadline),
            Expected(title: "Записаться к стоматологу", priority: .normal, due: nil, kind: nil),
        ]
        #expect(tasks.count == expected.count)
        for (task, want) in zip(tasks, expected) {
            #expect(task.title == want.title)
            #expect(task.priority == want.priority)
            #expect(task.dueMinutes == want.due)
            #expect(task.dueKind == want.kind)
            #expect(task.kind == .today)
        }
    }

    @Test func timeRaisesPriorityToImportantAndKeepsMinutes() {
        let tasks = TaskParser.parse("позвонить в банк к 11:30")
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Позвонить в банк")
        #expect(tasks.first?.priority == .important)
        #expect(tasks.first?.dueMinutes == 11 * 60 + 30)
        #expect(tasks.first?.dueKind == .deadline)
    }

    @Test func dottedTimeIsNotSplitIntoTwoTasks() {
        let tasks = TaskParser.parse("отправить счёт клиенту до 16.30")
        #expect(tasks.count == 1)
        #expect(tasks.first?.dueMinutes == 16 * 60 + 30)
    }

    @Test func importantWordAndFillersAreStripped() {
        let tasks = TaskParser.parse("ну важно продлить загранпаспорт")
        #expect(tasks.map(\.title) == ["Продлить загранпаспорт"])
        #expect(tasks.first?.priority == .important)
    }

    @Test func bareFillerFragmentsAreDropped() {
        #expect(TaskParser.parse("Ну, короче, ладно. Итак").isEmpty)
        #expect(TaskParser.parse("").isEmpty)
    }

    @Test func splitsOnAndBeforeInfinitiveOnly() {
        #expect(TaskParser.parse("купить хлеб и забрать посылку").map(\.title) == ["Купить хлеб", "Забрать посылку"])
        #expect(TaskParser.parse("купить хлеб и молоко").map(\.title) == ["Купить хлеб и молоко"])
    }

    @Test func longWordsMakeAMultiDayTask() {
        let tasks = TaskParser.parse("долгая задача сделать ремонт на балконе, купить хлеб, выучить испанский на несколько дней, длинная подготовить отчёт, переписать сайт на неделю")
        #expect(tasks.map(\.title) == ["Сделать ремонт на балконе", "Купить хлеб", "Выучить испанский", "Подготовить отчёт", "Переписать сайт"])
        #expect(tasks.map(\.kind) == [.long, .today, .long, .long, .long])
        #expect(tasks.map(\.note) == ["long · day 1", nil, "long · day 1", "long · day 1", "long · day 1"])
    }

    // MARK: Lines from the dictation transcript (one line = at least one task)

    @Test func fifteenLinesGiveFifteenTasksWithTheirSourceLine() {
        let lines = [
            "срочно оплатить интернет до 16", "созвон с командой в 12", "купить продукты", "забрать посылку",
            "записаться к стоматологу", "продлить загранпаспорт", "отправить счёт клиенту до 18", "позвонить в банк",
            "заказать воду в офис", "ответить бухгалтеру", "забронировать столик на вечер", "починить кран на кухне",
            "оплатить штраф", "подготовить отчёт к пятнице", "купить подарок коллеге",
        ]
        let result = TaskParser.parse(lines: lines)
        #expect(result.tasks.count == 15)
        #expect(result.tasks.map(\.sourceLine) == Array(0..<15).map(Optional.some))
        #expect(result.tasks.map(\.task.title) == [
            "Оплатить интернет", "Созвон с командой", "Купить продукты", "Забрать посылку",
            "Записаться к стоматологу", "Продлить загранпаспорт", "Отправить счёт клиенту", "Позвонить в банк",
            "Заказать воду в офис", "Ответить бухгалтеру", "Забронировать столик на вечер", "Починить кран на кухне",
            "Оплатить штраф", "Подготовить отчёт к пятнице", "Купить подарок коллеге",
        ])
        #expect(result.leftover.isEmpty)
    }

    @Test func lineWithoutPunctuationIsCutBeforeEachInfinitive() {
        let result = TaskParser.parse(lines: ["оплатить интернет купить продукты забрать посылку", "позвонить в банк"])
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет", "Купить продукты", "Забрать посылку", "Позвонить в банк"])
        #expect(result.tasks.map(\.sourceLine) == [0, 0, 0, 1])
    }

    @Test func lineIsCutAtThenAlsoAndSecondly() {
        let result = TaskParser.parse(lines: [
            "купить хлеб и потом забрать посылку",
            "позвонить в банк ещё оплатить штраф",
            "во-первых продлить загранпаспорт во-вторых записаться к стоматологу",
        ])
        #expect(result.tasks.map(\.task.title) == ["Купить хлеб", "Забрать посылку", "Позвонить в банк", "Оплатить штраф",
                                                   "Продлить загранпаспорт", "Записаться к стоматологу"])
        #expect(result.tasks.map(\.sourceLine) == [0, 0, 1, 1, 2, 2])
    }

    @Test func infinitivesThatBelongTogetherAreNotCut() {
        let result = TaskParser.parse(lines: ["надо позвонить маме", "хочу начать бегать", "купить новую кровать",
                                              "созвон в одиннадцать", "купить хлеб и молоко"])
        #expect(result.tasks.map(\.task.title) == ["Позвонить маме", "Начать бегать", "Купить новую кровать",
                                                   "Созвон", "Купить хлеб и молоко"])
    }

    @Test func spokenHoursBecomeTimes() {
        let tasks = TaskParser.parse(lines: ["оплатить интернет до шестнадцати", "созвон с командой в двенадцать тридцать",
                                             "отправить счёт к восемнадцати часам"]).tasks.map(\.task)
        #expect(tasks.map(\.title) == ["Оплатить интернет", "Созвон с командой", "Отправить счёт"])
        #expect(tasks.map(\.dueMinutes) == [16 * 60, 12 * 60 + 30, 18 * 60])
        #expect(tasks.map(\.dueKind) == [.deadline, .at, .deadline])
    }

    @Test func linesThatAreNotTasksGoToLeftover() {
        let result = TaskParser.parse(lines: ["купить хлеб", "ну вроде всё", "так", "забрать посылку, ну вот и всё"])
        #expect(result.tasks.map(\.task.title) == ["Купить хлеб", "Забрать посылку"])
        #expect(result.tasks.map(\.sourceLine) == [0, 3])
        #expect(result.leftover == ["ну вроде всё", "так", "ну вот и всё"])
    }

    // MARK: English dictation (titles stay in English)

    @Test func englishDictationGivesTasksWithUrgencyAndTimes() {
        let text = "So, urgent pay the internet bill by 16, then team call at 12, buy groceries, asap send the invoice to the client by 18"
        let tasks = TaskParser.parse(text)
        let expected = [
            Expected(title: "Pay the internet bill", priority: .urgent, due: 16 * 60, kind: .deadline),
            Expected(title: "Team call", priority: .important, due: 12 * 60, kind: .at),
            Expected(title: "Buy groceries", priority: .normal, due: nil, kind: nil),
            Expected(title: "Send the invoice to the client", priority: .urgent, due: 18 * 60, kind: .deadline),
        ]
        #expect(tasks.count == expected.count)
        for (task, want) in zip(tasks, expected) {
            #expect(task.title == want.title)
            #expect(task.priority == want.priority)
            #expect(task.dueMinutes == want.due)
            #expect(task.dueKind == want.kind)
        }
    }

    @Test func englishAmPmAndBeforeAreUnderstood() {
        let tasks = TaskParser.parse(lines: ["call the bank by 4 pm", "dentist at 9:30 a.m.", "important renew passport before 6pm",
                                             "lunch with Anna at 12 pm"]).tasks.map(\.task)
        #expect(tasks.map(\.title) == ["Call the bank", "Dentist", "Renew passport", "Lunch with Anna"])
        #expect(tasks.map(\.dueMinutes) == [16 * 60, 9 * 60 + 30, 18 * 60, 12 * 60])
        #expect(tasks.map(\.dueKind) == [.deadline, .at, .deadline, .at])
        #expect(tasks.map(\.priority) == [.important, .important, .important, .important])
    }

    @Test func englishHourWithoutAmPmThatAlreadyPassedMeansPm() {
        let afternoon = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let morning = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!
        #expect(TaskParser.parse("send the report by 5", now: afternoon).first?.dueMinutes == 17 * 60)
        #expect(TaskParser.parse("standup at 9", now: morning).first?.dueMinutes == 9 * 60)
        // Russian times are 24-hour: no guessing.
        #expect(TaskParser.parse("отправить отчёт до 5", now: afternoon).first?.dueMinutes == 5 * 60)
    }

    @Test func englishFillersAndLongWords() {
        let tasks = TaskParser.parse(lines: ["I need to renew my passport this week", "long task rewrite the website",
                                             "okay so learn Spanish for a few days", "remember to water the plants"]).tasks.map(\.task)
        #expect(tasks.map(\.title) == ["Renew my passport", "Rewrite the website", "Learn Spanish", "Water the plants"])
        #expect(tasks.map(\.kind) == [.long, .long, .long, .today])
        #expect(tasks.map(\.note) == ["long · day 1", "long · day 1", "long · day 1", nil])
    }

    @Test func englishLineIsCutAtThenAndAlso() {
        let result = TaskParser.parse(lines: ["buy bread and then pick up the parcel", "call the bank also pay the fine",
                                              "firstly book a table secondly buy a gift"])
        #expect(result.tasks.map(\.task.title) == ["Buy bread", "Pick up the parcel", "Call the bank", "Pay the fine",
                                                   "Book a table", "Buy a gift"])
        #expect(result.tasks.map(\.sourceLine) == [0, 0, 1, 1, 2, 2])
    }

    @Test func englishChatterGoesToLeftover() {
        let result = TaskParser.parse(lines: ["buy bread", "so I guess that's all", "okay"])
        #expect(result.tasks.map(\.task.title) == ["Buy bread"])
        #expect(result.leftover == ["so I guess that's all", "okay"])
    }

    @Test func mixedLanguagesKeepEachTitleAsSpoken() {
        let result = TaskParser.parse(lines: ["срочно оплатить интернет до 16", "urgent call mom at 18"])
        #expect(result.tasks.map(\.task.title) == ["Оплатить интернет", "Call mom"])
        #expect(result.tasks.map(\.task.priority) == [.urgent, .urgent])
    }

    @Test func stampsCreationTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(TaskParser.parse("оплатить интернет", now: now).first?.createdAt == now)
    }
}
