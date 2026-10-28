import Foundation
import Testing
import BubblesCore

/// Synthetic recognizer output: words with timings, as SpeechAnalyzer / SFSpeechRecognizer report them.
private func words(_ phrase: String, from start: TimeInterval, step: TimeInterval = 0.4) -> [SpokenWord] {
    phrase.split(separator: " ").enumerated().map { i, w in
        let s = start + Double(i) * step
        return SpokenWord(String(w), start: s, end: s + step * 0.8)
    }
}

/// End time of the last word, to place the next phrase after a chosen gap.
private func end(_ w: [SpokenWord]) -> TimeInterval { w.last?.end ?? 0 }

@Suite struct TranscriptTests {
    @Test func finalFragmentsAccumulateAndPausesStartNewLines() {
        var t = Transcript()
        let a = words("срочно оплатить интернет до 16", from: 0)
        let b = words("созвон с командой в 12", from: end(a) + 1.2)       // pause 1.2 s → new line
        let c = words("купить продукты", from: end(b) + 0.3)               // 0.3 s → same line
        t.commit(a)
        t.commit(b)
        t.commit(c)
        #expect(t.lines == ["срочно оплатить интернет до 16", "созвон с командой в 12 купить продукты"])
    }

    @Test func pauseThresholdIsPointEightSeconds() {
        var t = Transcript()
        let a = words("купить хлеб", from: 0)
        let b = words("забрать посылку", from: end(a) + 0.7)
        let c = words("оплатить интернет", from: end(b) + 0.9)
        t.commit(a + b + c)
        #expect(t.lines == ["купить хлеб забрать посылку", "оплатить интернет"])
    }

    @Test func volatileTailIsShownAndReplacedNotAppended() {
        var t = Transcript()
        let a = words("купить хлеб", from: 0)
        t.commit(a)
        t.update(volatile: words("записать", from: end(a) + 1))
        t.update(volatile: words("записаться к стоматологу", from: end(a) + 1))
        #expect(t.lines == ["купить хлеб", "записаться к стоматологу"])
        t.commit(words("записаться к стоматологу", from: end(a) + 1))
        #expect(t.lines == ["купить хлеб", "записаться к стоматологу"])
    }

    @Test func separatorWordsStartNewLineAndAreDropped() {
        var t = Transcript()
        t.commit(words("купить продукты дальше записаться к стоматологу следующая задача оплатить интернет ещё задача продлить загранпаспорт", from: 0))
        #expect(t.lines == ["купить продукты", "записаться к стоматологу", "оплатить интернет", "продлить загранпаспорт"])
    }

    @Test func separatorMatchingIgnoresCaseAndPunctuation() {
        var t = Transcript()
        t.commit([SpokenWord("Купить", start: 0, end: 0.3), SpokenWord("хлеб.", start: 0.4, end: 0.7),
                  SpokenWord("Дальше,", start: 0.8, end: 1.1), SpokenWord("позвонить", start: 1.2, end: 1.5),
                  SpokenWord("в", start: 1.6, end: 1.7), SpokenWord("банк.", start: 1.8, end: 2.1)])
        #expect(t.lines == ["Купить хлеб", "позвонить в банк"])
    }

    @Test func deleteLastErasesThePreviousLineAfterAPause() {
        var t = Transcript()
        let a = words("купить хлеб", from: 0)
        let b = words("позвонить не тому", from: end(a) + 1)
        let c = words("удали последнее", from: end(b) + 1)
        let d = words("позвонить в банк", from: end(c) + 1)
        let commands = t.commit(a + b + c)
        t.commit(d)
        #expect(commands == [.deleteLast])
        #expect(t.lines == ["купить хлеб", "позвонить в банк"])
    }

    @Test func deleteLastInsideALineErasesThatLine() {
        var t = Transcript()
        let a = words("купить хлеб", from: 0)
        t.commit(a + words("позвонить не тому удали последнее", from: end(a) + 1))
        #expect(t.lines == ["купить хлеб"])
    }

    @Test func doneFinishesAndIgnoresLaterSpeech() {
        var t = Transcript()
        let a = words("купить хлеб", from: 0)
        let commands = t.commit(a + words("готово", from: end(a) + 1) + words("это не задача", from: end(a) + 3))
        #expect(commands == [.finish])
        #expect(t.isFinished)
        #expect(t.lines == ["купить хлеб"])
    }

    // MARK: English voice commands

    @Test func englishSeparatorsStartNewLinesButNextWeekStays() {
        var t = Transcript()
        t.commit(words("buy groceries next book a dentist appointment next week next task pay the rent another task call mom", from: 0))
        #expect(t.lines == ["buy groceries", "book a dentist appointment next week", "pay the rent", "call mom"])
    }

    @Test func englishDeleteLastErasesTheLine() {
        var t = Transcript()
        let a = words("buy bread", from: 0)
        let b = words("call the wrong person", from: end(a) + 1)
        let c = words("delete the last one", from: end(b) + 1)
        let d = words("call the bank", from: end(c) + 1)
        let commands = t.commit(a + b + c + d)
        #expect(commands == [.deleteLast])
        #expect(t.lines == ["buy bread", "call the bank"])
        t.commit(words("scratch that", from: end(d) + 1))
        #expect(t.lines == ["buy bread"])
    }

    @Test func englishDoneFinishesOnlyOnItsOwn() {
        var t = Transcript()
        let a = words("get the report done", from: 0)
        #expect(t.commit(a).isEmpty)                               // "done" inside a task is part of it
        let commands = t.commit(words("I'm done", from: end(a) + 1) + words("not a task", from: end(a) + 3))
        #expect(commands == [.finish])
        #expect(t.isFinished)
        #expect(t.lines == ["get the report done"])
    }

    @Test func fifteenDictatedTasksGiveFifteenLines() {
        let tasks = [
            "срочно оплатить интернет до 16", "созвон с командой в 12", "купить продукты", "забрать посылку",
            "записаться к стоматологу", "продлить загранпаспорт", "отправить счёт клиенту до 18", "позвонить в банк",
            "заказать воду в офис", "ответить бухгалтеру", "забронировать столик на вечер", "починить кран на кухне",
            "оплатить штраф", "подготовить отчёт к пятнице", "купить подарок коллеге",
        ]
        var t = Transcript()
        var clock: TimeInterval = 0
        for (i, task) in tasks.enumerated() {
            // Every third task is separated by «дальше» ("next") instead of a pause; finals arrive one per phrase.
            let phrase = i % 3 == 2 ? "дальше " + task : task
            let w = words(phrase, from: clock)
            t.commit(w)
            clock = end(w) + (i % 3 == 1 ? 0.2 : 1.1)
        }
        #expect(t.lines == tasks)
    }

    // MARK: SFSpeechRecognizer-style hypotheses (the whole text since the recognizer's last reset)

    @Test func recognizerRestartAfterPauseDoesNotLoseEarlierSpeech() {
        var t = Transcript()
        let a = words("срочно оплатить интернет до 16", from: 0)
        t.receiveHypothesis(Array(a.prefix(2)), isFinal: false)
        t.receiveHypothesis(a, isFinal: false)
        // After the pause the recognizer starts a new fragment: its hypothesis no longer contains `a`.
        let b = words("созвон с командой в 12", from: end(a) + 1.5)
        t.receiveHypothesis(Array(b.prefix(1)), isFinal: false)
        t.receiveHypothesis(b, isFinal: false)
        #expect(t.lines == ["срочно оплатить интернет до 16", "созвон с командой в 12"])
        let c = words("купить продукты", from: end(b) + 1.5)
        t.receiveHypothesis(c, isFinal: true)
        #expect(t.lines == ["срочно оплатить интернет до 16", "созвон с командой в 12", "купить продукты"])
    }

    @Test func revisedHypothesisReplacesItself() {
        var t = Transcript()
        t.receiveHypothesis([SpokenWord("оплатит", start: 0, end: 0.4)], isFinal: false)
        t.receiveHypothesis([SpokenWord("оплатить", start: 0, end: 0.5), SpokenWord("интернет", start: 0.6, end: 1)], isFinal: false)
        #expect(t.lines == ["оплатить интернет"])
    }

    @Test func untimedPartialsAreStampedWithArrivalTimeSoPausesStillSplit() {
        var t = Transcript()
        var previous: [SpokenWord] = []
        func feed(_ text: String, at now: TimeInterval) {
            previous = SpokenWord.stamped(text.split(separator: " ").map(String.init), previous: previous, now: now)
            t.receiveHypothesis(previous, isFinal: false)
        }
        feed("купить", at: 0.5)
        feed("купить хлеб", at: 0.9)
        feed("купить хлеб забрать", at: 2.5)        // 1.6 s of silence before «забрать»
        feed("купить хлеб забрать посылку", at: 2.9)
        #expect(t.lines == ["купить хлеб", "забрать посылку"])
    }

    @Test func stopKeepsTheVolatileTail() {
        var t = Transcript()
        t.commit(words("купить хлеб", from: 0))
        t.update(volatile: words("забрать посылку", from: 3))
        t.commitVolatile()
        t.beginSession()
        t.commit(words("оплатить интернет", from: 0))   // a new recognizer session restarts its clock at zero
        #expect(t.lines == ["купить хлеб", "забрать посылку", "оплатить интернет"])
    }

    @Test func editedLinesReplaceTheTranscript() {
        var t = Transcript(lines: ["купить хлеб забрать посылку"])
        t.replaceLines(["купить хлеб", "  ", "забрать посылку "])
        #expect(t.lines == ["купить хлеб", "забрать посылку"])
        #expect(t.text == "купить хлеб\nзабрать посылку")
        t.removeLastLine()
        #expect(t.lines == ["купить хлеб"])
    }
}

@Suite struct TranscriptDraftStoreTests {
    private func tempURL() -> URL {
        // $TMPDIR first: inside restricted sandboxes Foundation's temporaryDirectory points at a denied folder.
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        return tmp.appendingPathComponent("bubbles-draft-\(UUID().uuidString)/draft.json")
    }

    @Test func savedLinesAreReadBackWithTheirTime() {
        let url = tempURL()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        TranscriptDraftStore(fileURL: url).save(["купить хлеб", "позвонить в банк"], at: at)
        let loaded = TranscriptDraftStore(fileURL: url).load()
        #expect(loaded == TranscriptDraft(lines: ["купить хлеб", "позвонить в банк"], savedAt: at))
    }

    @Test func emptyDraftAndClearRemoveTheFile() {
        let url = tempURL()
        let store = TranscriptDraftStore(fileURL: url)
        store.save(["купить хлеб"])
        store.save([])
        #expect(store.load() == nil)
        store.save(["купить хлеб"])
        store.clear()
        #expect(store.load() == nil)
    }

    @Test func corruptFileIsIgnored() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        #expect(TranscriptDraftStore(fileURL: url).load() == nil)
    }

    @Test func defaultLocationIsApplicationSupport() {
        #expect(TranscriptDraftStore.defaultURL.path.hasSuffix("Application Support/Bubbles/dictation-draft.json"))
    }
}
