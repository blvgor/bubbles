import CoreGraphics
import Foundation
import Testing
@testable import BubblesCore

@Suite struct DeskRulesTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: Sample day

    @Test func sampleDayIsNeutralAndHasThePassportDeadline() {
        let tasks = SampleDay.tasks(now: date(26, 9, 0))
        #expect(tasks.map(\.title).sorted() == [
            "Buy a gift", "Book a dentist appointment", "Pay the internet bill",
            "Send the invoice to the client", "Renew passport",
        ].sorted())
        let passport = tasks.first { $0.title == "Renew passport" }
        #expect(passport?.dueMinutes == 18 * 60)
        #expect(passport?.dueKind == .deadline)
        #expect(tasks.contains { $0.priority == .urgent })
        #expect(Set(tasks.map(\.id)).count == 5)
    }

    // MARK: Proof + hold

    @Test func proofNeedsThreeVisibleCharacters() {
        #expect(!ProofHold.isValid("  ab  "))
        #expect(!ProofHold.isValid(""))
        #expect(ProofHold.isValid("abc"))
        #expect(ProofHold.isValid(" paid "))
    }

    @Test func holdProgressAndLabels() {
        #expect(ProofHold.idleLabel(seconds: 10) == "Hold for 10 seconds")
        #expect(ProofHold.rejectedLabel == "First write what you did")
        #expect(ProofHold.progress(elapsed: 2.5, seconds: 10) == 0.25)
        #expect(ProofHold.progress(elapsed: -1, seconds: 10) == 0)
        #expect(ProofHold.progress(elapsed: 12, seconds: 10) == 1)
        #expect(ProofHold.holdingLabel(elapsed: 2.5, seconds: 10) == "Hold… 8")
        #expect(ProofHold.holdingLabel(elapsed: 10, seconds: 10) == "Done")
    }

    // MARK: Hide

    @Test func hideOptionsProduceTheRightMoments() {
        let now = date(26, 14, 30)
        #expect(HideOption.hour.hiddenState(now: now, calendar: calendar) == .until(now.addingTimeInterval(3600)))
        #expect(HideOption.tomorrow.hiddenState(now: now, calendar: calendar) == .until(date(27, 8, 0)))
        #expect(HideOption.forever.hiddenState(now: now, calendar: calendar) == .forever)
    }

    @Test func hiddenMenuText() {
        let now = date(26, 14, 30)
        #expect(HiddenState.until(date(26, 15, 30)).menuText(now: now, calendar: calendar) == "Hidden until 15:30")
        #expect(HiddenState.until(date(27, 8, 0)).menuText(now: now, calendar: calendar) == "Hidden until tomorrow 08:00")
        #expect(HiddenState.forever.menuText(now: now, calendar: calendar) == "Bubbles are off")
        #expect(HiddenState.visible.menuText(now: now, calendar: calendar) == nil)
    }

    // MARK: Menu header

    @Test func menuStatusLine() {
        #expect(MenuStatus.line(taskCount: 5, done: 2, streak: 3) == "5 tasks · 2 done · 3-day streak")
        #expect(MenuStatus.line(taskCount: 1, done: 0, streak: 0) == "1 task · 0 done · 0-day streak")
        #expect(MenuStatus.line(taskCount: 0, done: 4, streak: 1) == "No tasks. Click the microphone")
    }

    // MARK: Bubble size class

    @Test func smallestBubblesShowOnlyTheDot() {
        #expect(BubbleSizeClass(rank: 0, targetRadius: 120) == .regular)
        #expect(BubbleSizeClass(rank: 3, targetRadius: 60) == .small)
        #expect(BubbleSizeClass(rank: 4, targetRadius: 40) == .tiny)
    }

    // MARK: Desk hit target (click-through)

    private func world(surfaced: Bool) -> (PhysicsWorld, UUID) {
        var w = PhysicsWorld(bounds: CGRect(x: 0, y: 0, width: 1200, height: 800), seed: 1)
        let id = UUID()
        w.sync(ranked: [id], spawnFrom: nil)
        if surfaced { w.setSurfaced(id) }
        w.step(dt: 0.016, speed: 1, animate: false, rotate: false)
        return (w, id)
    }

    @Test func deskTargetsBubblesAndMicOnly() {
        let (w, id) = world(surfaced: false)
        let centre = w.bodies[0].position
        let mic = CGPoint(x: 600, y: 56)
        #expect(DeskHit.target(at: centre, world: w, layer: .desk, mic: mic, bubblesHidden: false) == .bubble(id))
        #expect(DeskHit.target(at: centre, world: w, layer: .float, mic: mic, bubblesHidden: false) == nil)
        #expect(DeskHit.target(at: CGPoint(x: 620, y: 70), world: w, layer: .desk, mic: mic, bubblesHidden: false) == .mic)
        #expect(DeskHit.target(at: CGPoint(x: 5, y: 795), world: w, layer: .desk, mic: mic, bubblesHidden: false) == nil)
        #expect(DeskHit.target(at: centre, world: w, layer: .desk, mic: mic, bubblesHidden: true) == nil)
    }

    @Test func surfacedBubbleBelongsToTheFloatLayer() {
        let (w, id) = world(surfaced: true)
        let centre = w.bodies[0].position
        let mic = CGPoint(x: 600, y: 56)
        #expect(DeskHit.target(at: centre, world: w, layer: .float, mic: mic, bubblesHidden: false) == .bubble(id))
        #expect(DeskHit.target(at: centre, world: w, layer: .desk, mic: mic, bubblesHidden: false) == nil)
        #expect(DeskHit.target(at: CGPoint(x: 600, y: 56), world: w, layer: .float, mic: mic, bubblesHidden: false) == nil)
    }
}
