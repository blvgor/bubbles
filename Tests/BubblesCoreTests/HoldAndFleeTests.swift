import CoreGraphics
import Foundation
import Testing
import BubblesCore

/// Stories 47–48: "Hold the button" 1…30 s and "Can't catch me".
@MainActor @Suite struct HoldAndFleeTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "bubbles-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: - Settings

    @Test func holdIsTenSecondsAndFleeIsOffByDefault() {
        withDefaults { defaults in
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.holdSeconds == 10)
            #expect(!s.fleeMode)
        }
    }

    @Test func holdAndFleeSurviveRestart() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.settings.holdSeconds = 3
            store.settings.fleeMode = true
            let restored = SettingsStore(defaults: defaults).settings
            #expect(restored.holdSeconds == 3)
            #expect(restored.fleeMode)
        }
    }

    @Test func olderSaveWithoutTheFieldsHoldsTenAndDoesNotFlee() throws {
        let old = Data(#"{"roundness":40,"tint":"sky","speed":100,"rotation":true,"animation":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BubbleSettings.self, from: old)
        #expect(decoded.holdSeconds == 10)
        #expect(!decoded.fleeMode)
    }

    @Test func storedHoldOutsideOneToThirtyIsClamped() throws {
        let long = try JSONDecoder().decode(BubbleSettings.self, from: Data(#"{"holdSeconds":45}"#.utf8))
        let short = try JSONDecoder().decode(BubbleSettings.self, from: Data(#"{"holdSeconds":0}"#.utf8))
        #expect(long.holdSeconds == 30)
        #expect(short.holdSeconds == 1)
    }

    @Test func holdHintSaysTheChosenSeconds() {
        #expect(ProofHold.holdHint(seconds: 1) == "Hold Space or the button for 1 second")
        #expect(ProofHold.holdHint(seconds: 3) == "Hold Space or the button for 3 seconds")
        #expect(ProofHold.holdHint(seconds: 10) == "Hold Space or the button for 10 seconds")
        #expect(ProofHold.holdHint(seconds: 21) == "Hold Space or the button for 21 seconds")
        #expect(ProofHold.idleLabel(seconds: 3) == "Hold for 3 seconds")
    }

    @Test func fleeingBubblesTakeNoClicksButTheMicDoes() {
        var settings = BubbleSettings()
        #expect(settings.bubblesTakeInput)
        settings.fleeMode = true
        #expect(!settings.bubblesTakeInput)
        settings.fleeMode = false
        settings.hidden = .forever
        #expect(!settings.bubblesTakeInput)

        var w = PhysicsWorld(bounds: bounds, seed: 3)
        w.sync(ranked: [UUID()], spawnFrom: nil)
        let centre = w.bodies[0].position
        let mic = CGPoint(x: bounds.midX, y: bounds.minY + 40)
        settings = BubbleSettings()
        settings.fleeMode = true
        let hidden = !settings.bubblesTakeInput
        #expect(DeskHit.target(at: centre, world: w, layer: .desk, mic: mic, bubblesHidden: hidden) == nil)
        #expect(DeskHit.target(at: mic, world: w, layer: .desk, mic: mic, bubblesHidden: hidden) == .mic)
    }

    // MARK: - Fleeing

    private let bounds = CGRect(x: 8, y: 8, width: 1000, height: 800)
    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// One bubble at rest in the middle of the desk.
    private func world(seed: UInt64 = 5) -> PhysicsWorld {
        var world = PhysicsWorld(bounds: bounds, seed: seed)
        world.sync(ranked: [UUID()], spawnFrom: nil)
        world.bodies[0].position = CGPoint(x: bounds.midX, y: bounds.midY)
        world.bodies[0].velocity = .zero
        return world
    }

    private func run(_ world: inout PhysicsWorld, frames: Int) {
        for _ in 0..<frames { world.step(dt: 1.0 / 60, speed: 1, animate: true, rotate: true) }
    }

    @Test func slowCursorPushesTheBubbleAway() {
        var calm = world()
        var fleeing = world()
        let start = fleeing.bodies[0].position
        let cursor = CGPoint(x: start.x - fleeing.bodies[0].radius - 40, y: start.y)
        fleeing.cursor = CursorState(position: cursor, velocity: .zero)
        run(&calm, frames: 30)
        run(&fleeing, frames: 30)
        let calmGap = distance(calm.bodies[0].position, cursor)
        let fleeGap = distance(fleeing.bodies[0].position, cursor)
        #expect(fleeGap - calmGap > 30)
        #expect(fleeing.bodies[0].position.x > start.x + 30)   // away from the cursor, to the right
    }

    @Test func fasterCursorPushesFaster() {
        var slow = world()
        var fast = world()
        let start = slow.bodies[0].position
        let cursor = CGPoint(x: start.x - slow.bodies[0].radius - 60, y: start.y)
        slow.cursor = CursorState(position: cursor, velocity: CGVector(dx: 100, dy: 0))
        fast.cursor = CursorState(position: cursor, velocity: CGVector(dx: 1200, dy: 0))
        run(&slow, frames: 10)
        run(&fast, frames: 10)
        let slowGain = slow.bodies[0].position.x - start.x
        let fastGain = fast.bodies[0].position.x - start.x
        #expect(slowGain > 0)
        #expect(fastGain > slowGain * 2)
    }

    @Test func cursorRushingAtTheBubbleNeverReachesItsCentre() {
        var w = world()
        let body = w.bodies[0]
        var cursor = CGPoint(x: body.position.x - body.radius - 300, y: body.position.y)
        let velocity = CGVector(dx: 1500, dy: 0)
        var closest = CGFloat.infinity
        // 1 s at 1500 pt/s: the cursor crosses the whole desk and runs the bubble into the right wall.
        for _ in 0..<60 {
            cursor.x += velocity.dx / 60
            w.cursor = CursorState(position: cursor, velocity: velocity)
            run(&w, frames: 1)
            closest = min(closest, distance(w.bodies[0].position, cursor))
        }
        #expect(closest > body.radius * 0.5)
    }

    @Test func pinnedToAWallTheBubbleSlipsAlongIt() {
        var w = world()
        let r = w.bodies[0].radius
        w.bodies[0].position = CGPoint(x: bounds.maxX - r, y: bounds.midY)
        let startY = w.bodies[0].position.y
        var cursor = CGPoint(x: bounds.maxX - r - r - 120, y: startY)
        let velocity = CGVector(dx: 300, dy: 0)
        var closest = CGFloat.infinity
        for _ in 0..<90 {
            cursor.x = min(bounds.maxX - 4, cursor.x + velocity.dx / 60)
            w.cursor = CursorState(position: cursor, velocity: velocity)
            run(&w, frames: 1)
            closest = min(closest, distance(w.bodies[0].position, cursor))
        }
        #expect(abs(w.bodies[0].position.y - startY) > r)   // went along the wall, not stuck in it
        #expect(closest > r)
        #expect(w.bodies[0].position.x <= bounds.maxX - r + 0.001)
    }

    @Test func fleeingBubbleStillStaysOutOfTheMic() {
        var w = world()
        let r = w.bodies[0].radius
        let mic = KeepOutZone(center: CGPoint(x: bounds.midX, y: bounds.minY + 56), radius: 32)
        w.keepOut = mic
        w.bodies[0].position = CGPoint(x: mic.center.x, y: mic.center.y + r + 60)
        var worst = CGFloat.infinity
        // Chase it from above straight down onto the mic.
        for frame in 0..<120 {
            let cursor = CGPoint(x: mic.center.x + 5, y: bounds.maxY - CGFloat(frame) * 6)
            w.cursor = CursorState(position: cursor, velocity: CGVector(dx: 0, dy: -360))
            run(&w, frames: 1)
            worst = min(worst, distance(w.bodies[0].position, mic.center) - w.bodies[0].radius - mic.radius)
        }
        #expect(worst >= 0)
    }
}
