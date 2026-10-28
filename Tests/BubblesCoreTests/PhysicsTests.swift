import CoreGraphics
import Foundation
import Testing
import BubblesCore

@Suite struct PhysicsTests {
    let bounds = CGRect(x: 8, y: 8, width: 1000, height: 800)

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test func baseAndTargetRadii() {
        #expect(PhysicsWorld.baseRadius(for: CGSize(width: 1000, height: 800)) == 120)
        #expect(PhysicsWorld.baseRadius(for: CGSize(width: 300, height: 300)) == 64)
        #expect(PhysicsWorld.baseRadius(for: CGSize(width: 3000, height: 2000)) == 132)
        let factors = (0..<5).map { PhysicsWorld.targetRadius(rank: $0, base: 100) }
        #expect(factors == [100, 80, 70, 50, 50])
    }

    @Test func syncKeepsAtMostEightBodiesAndCountsOverflow() {
        var world = PhysicsWorld(bounds: bounds, seed: 1)
        let all = ids(12)
        world.sync(ranked: all, spawnFrom: nil)
        #expect(world.bodies.count == PhysicsWorld.maxVisible)
        #expect(world.overflowCount == 4)
        #expect(Set(world.bodies.map(\.id)) == Set(all.prefix(8)))
        for body in world.bodies { #expect(body.rank == all.firstIndex(of: body.id)) }
    }

    @Test func scatteredBubblesTouchAtTheirVisibleEdges() {
        var world = PhysicsWorld(bounds: CGRect(x: 0, y: 0, width: 2000, height: 1400), seed: 33)
        world.roundness = 0
        world.sync(ranked: ids(2), spawnFrom: nil)
        // Fly the two bubbles head-on and watch the gap between their drawn outlines.
        world.bodies[0].position = CGPoint(x: 600, y: 700)
        world.bodies[1].position = CGPoint(x: 1400, y: 700)
        world.bodies[0].velocity = CGVector(dx: 300, dy: 0)
        world.bodies[1].velocity = CGVector(dx: -300, dy: 0)
        var deepest: CGFloat = .infinity
        var touched = false
        for _ in 0..<360 {
            world.step(dt: 1.0 / 60, speed: 1, animate: true, rotate: true)
            let a = world.bodies[0], c = world.bodies[1]
            let angle = atan2(Double(c.position.y - a.position.y), Double(c.position.x - a.position.x))
            let gap = distance(a.position, c.position) - world.reach(a, toward: angle) - world.reach(c, toward: angle + .pi)
            deepest = min(deepest, gap)
            if gap < 20 { touched = true }
        }
        #expect(touched)
        // Outlines may squash into each other a little on impact, never pass through.
        #expect(deepest > -0.1 * world.bodies[0].radius)
    }

    @Test func bubblesStayOutOfTheMicZone() {
        var world = PhysicsWorld(bounds: bounds, seed: 21)
        world.sync(ranked: ids(6), spawnFrom: nil)
        let mic = KeepOutZone(center: CGPoint(x: bounds.midX, y: bounds.minY + 56), radius: 32)
        world.keepOut = mic
        // Throw every bubble straight at the mic.
        for i in world.bodies.indices {
            world.bodies[i].position = CGPoint(x: mic.center.x + CGFloat(i * 10 - 25), y: mic.center.y + 300)
            world.bodies[i].velocity = CGVector(dx: 0, dy: -400)
        }
        var worst = CGFloat.infinity
        for _ in 0..<600 {
            world.step(dt: 1.0 / 60, speed: 1, animate: true, rotate: true)
            for b in world.bodies { worst = min(worst, distance(b.position, mic.center) - b.radius - mic.radius) }
        }
        #expect(worst >= 0)
    }

    @Test func duplicateIdsGiveOneBodyEachAndDoNotCrash() {
        var world = PhysicsWorld(bounds: bounds, seed: 10)
        let a = UUID(), b = UUID()
        world.sync(ranked: [a, a, b, a], spawnFrom: nil)
        #expect(world.bodies.map(\.id) == [a, b])
        #expect(world.overflowCount == 0)
        world.sync(ranked: [b, a, b], spawnFrom: CGPoint(x: 100, y: 100))   // used to trap on the second sync
        #expect(world.bodies.map(\.id) == [b, a])
        #expect(world.bodies.map(\.rank) == [0, 1])
        let many = ids(10)
        world.sync(ranked: many + many, spawnFrom: nil)
        #expect(world.bodies.count == 8)
        #expect(world.overflowCount == 2)
    }

    @Test func nextRankedTaskEmergesFromOverflowBubble() {
        var world = PhysicsWorld(bounds: bounds, seed: 2)
        let all = ids(12)
        world.sync(ranked: all, spawnFrom: nil)
        let source = world.overflowPoint
        world.sync(ranked: Array(all.dropFirst()), spawnFrom: nil)   // the top task was closed
        #expect(world.bodies.count == 8)
        #expect(world.overflowCount == 3)
        #expect(!world.bodies.contains { $0.id == all[0] })
        let newcomer = try! #require(world.bodies.first { $0.id == all[8] })
        #expect(newcomer.position == source)
        #expect(newcomer.radius < newcomer.targetRadius)
        #expect(newcomer.rank == 7)
        #expect(bounds.contains(source))
    }

    @Test func dictatedTasksFlyOutOfTheMicOneAfterAnother() {
        var world = PhysicsWorld(bounds: bounds, seed: 3)
        let mic = CGPoint(x: 508, y: 40)
        world.sync(ranked: ids(3), spawnFrom: mic)
        #expect(world.bodies.allSatisfy { $0.position == mic })
        let delays = world.bodies.sorted { $0.rank < $1.rank }.map(\.spawnDelay)
        #expect(delays == delays.sorted() && delays.first == 0 && delays.last! > 0)
    }

    @Test func withoutAnimationBodiesSitExactlyOnAnchors() {
        var world = PhysicsWorld(bounds: bounds, seed: 4)
        world.sync(ranked: ids(6), spawnFrom: nil)
        for i in world.bodies.indices { world.bodies[i].velocity = CGVector(dx: 300, dy: -200) }
        for _ in 0..<30 { world.step(dt: 1.0 / 60, speed: 1, animate: false, rotate: true) }
        for body in world.bodies {
            #expect(body.position == body.anchor)
            #expect(body.position == world.anchor(rank: body.rank, count: 6))
            #expect(body.radius == body.targetRadius)
            #expect(body.squash == 0)
        }
    }

    @Test func headOnCollisionBouncesApartWithoutOverlap() {
        var world = PhysicsWorld(bounds: bounds, seed: 5)
        let pair = ids(2)
        world.sync(ranked: pair, spawnFrom: nil)
        let y = bounds.midY
        for i in world.bodies.indices {
            world.bodies[i].radius = world.bodies[i].targetRadius
            world.bodies[i].spawnDelay = 0
        }
        world.bodies[0].position = CGPoint(x: bounds.midX - 120, y: y)
        world.bodies[0].velocity = CGVector(dx: 320, dy: 0)
        world.bodies[1].position = CGPoint(x: bounds.midX + 120, y: y)
        world.bodies[1].velocity = CGVector(dx: -320, dy: 0)
        let reach = world.bodies[0].radius + world.bodies[1].radius

        var touched = false
        for _ in 0..<20 {
            world.step(dt: 1.0 / 60, speed: 1, animate: true, rotate: true)
            // Contact starts at reach + 2 (gap); substeps resolve it before deep overlap, so allow one substep of travel.
            if distance(world.bodies[0].position, world.bodies[1].position) <= reach + 5 { touched = true }
        }
        #expect(touched)
        let a = world.bodies[0], b = world.bodies[1]
        #expect(distance(a.position, b.position) >= reach)
        #expect(a.velocity.dx < b.velocity.dx)          // moving apart
        #expect(a.squash != 0 || a.squashVelocity != 0) // the impact squashed the jelly
    }

    @Test func bodiesNeverLeaveTheBounds() {
        var world = PhysicsWorld(bounds: bounds, seed: 6)
        world.sync(ranked: ids(8), spawnFrom: nil)
        for i in world.bodies.indices {
            world.bodies[i].velocity = CGVector(dx: i.isMultiple(of: 2) ? 2000 : -2000, dy: i % 3 == 0 ? 2000 : -1500)
        }
        for _ in 0..<600 {
            world.step(dt: 1.0 / 60, speed: 2, animate: true, rotate: true)
            for body in world.bodies {
                #expect(body.position.x - body.radius >= bounds.minX - 0.001)
                #expect(body.position.x + body.radius <= bounds.maxX + 0.001)
                #expect(body.position.y - body.radius >= bounds.minY - 0.001)
                #expect(body.position.y + body.radius <= bounds.maxY + 0.001)
            }
        }
    }

    @Test func atMostOneSurfacedBodyAndItGrows() {
        var world = PhysicsWorld(bounds: bounds, seed: 7)
        let all = ids(4)
        world.sync(ranked: all, spawnFrom: nil)
        world.setSurfaced(all[2])
        world.setSurfaced(all[0])
        #expect(world.bodies.filter(\.surfaced).map(\.id) == [all[0]])
        let base = PhysicsWorld.baseRadius(for: bounds.size)
        #expect(world.bodies.first { $0.id == all[0] }!.targetRadius == base * 1.35)
        world.setSurfaced(nil)
        #expect(world.bodies.allSatisfy { !$0.surfaced })
        #expect(world.bodies.first { $0.id == all[0] }!.targetRadius == base)
    }

    @Test func hitTestFindsBodyUnderPoint() {
        var world = PhysicsWorld(bounds: bounds, seed: 8)
        world.sync(ranked: ids(3), spawnFrom: nil)
        let body = world.bodies[1]
        #expect(world.body(at: body.position)?.id == body.id)
        #expect(world.body(at: CGPoint(x: -500, y: -500)) == nil)
    }

    @Test func shapeTimeAdvancesOnlyWhileAnimating() {
        var world = PhysicsWorld(bounds: bounds, seed: 9)
        world.step(dt: 0.02, speed: 1.5, animate: true, rotate: true)
        #expect(abs(world.shapeTime - 0.03) < 1e-9)
        world.step(dt: 0.02, speed: 1.5, animate: false, rotate: true)
        world.step(dt: 0.02, speed: 0, animate: true, rotate: true)
        #expect(abs(world.shapeTime - 0.03) < 1e-9)
    }

    /// Story 39: collisions are soft — the bubbles part noticeably slower than they met.
    @Test func headOnBounceIsSoft() {
        var world = PhysicsWorld(bounds: bounds, seed: 11)
        world.sync(ranked: ids(2), spawnFrom: nil)
        for i in world.bodies.indices {
            world.bodies[i].radius = 80
            world.bodies[i].targetRadius = 80
            world.bodies[i].spawnDelay = 0
            world.bodies[i].anchor = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        world.bodies[0].position = CGPoint(x: bounds.midX - 90, y: bounds.midY)
        world.bodies[0].velocity = CGVector(dx: 320, dy: 0)
        world.bodies[1].position = CGPoint(x: bounds.midX + 90, y: bounds.midY)
        world.bodies[1].velocity = CGVector(dx: -320, dy: 0)
        for _ in 0..<10 { world.step(dt: 1.0 / 60, speed: 1, animate: true, rotate: true) }
        let separating = world.bodies[1].velocity.dx - world.bodies[0].velocity.dx
        #expect(separating > 0)
        #expect(separating < 0.7 * 640)   // was ~0.92 × 640 with the prototype's restitution
    }

    /// Story 39: bubbles pressed together by their anchors settle instead of trembling.
    @Test func crowdedBubblesSettleWithoutTrembling() {
        var world = PhysicsWorld(bounds: bounds, seed: 12)
        world.sync(ranked: ids(4), spawnFrom: nil)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        for i in world.bodies.indices {
            world.bodies[i].spawnDelay = 0
            world.bodies[i].radius = world.bodies[i].targetRadius
            world.bodies[i].anchor = centre
            world.bodies[i].position = CGPoint(x: centre.x + CGFloat(i) * 3, y: centre.y + CGFloat(i % 2) * 3)
            world.bodies[i].velocity = .zero
        }
        for _ in 0..<1200 {
            world.step(dt: 1.0 / 60, speed: 0.05, animate: true, rotate: false)
            for i in world.bodies.indices { world.bodies[i].anchor = centre }
        }
        var worstJolt: CGFloat = 0
        var previous = world.bodies.map(\.velocity)
        for _ in 0..<120 {
            world.step(dt: 1.0 / 60, speed: 0.05, animate: true, rotate: false)
            for i in world.bodies.indices { world.bodies[i].anchor = centre }
            for (i, body) in world.bodies.enumerated() {
                worstJolt = max(worstJolt, hypot(body.velocity.dx - previous[i].dx, body.velocity.dy - previous[i].dy))
            }
            previous = world.bodies.map(\.velocity)
        }
        #expect(worstJolt < 3)   // pt/s change per frame
    }

    /// Story 39: one long frame is simulated in small substeps, so it lands where several short frames would.
    @Test func longFrameMatchesShortFrames() {
        func run(_ frames: Int, dt: Double) -> [CGPoint] {
            var world = PhysicsWorld(bounds: bounds, seed: 13)
            world.sync(ranked: ids(2), spawnFrom: nil)
            for i in world.bodies.indices {
                world.bodies[i].radius = 60
                world.bodies[i].targetRadius = 60
                world.bodies[i].spawnDelay = 0
            }
            world.bodies[0].position = CGPoint(x: bounds.midX - 70, y: bounds.midY)
            world.bodies[0].velocity = CGVector(dx: 600, dy: 0)
            world.bodies[1].position = CGPoint(x: bounds.midX + 70, y: bounds.midY)
            world.bodies[1].velocity = CGVector(dx: -600, dy: 0)
            for _ in 0..<frames { world.step(dt: dt, speed: 1, animate: true, rotate: true) }
            return world.bodies.map(\.position)
        }
        let long = run(1, dt: 0.04)
        let short = run(4, dt: 0.01)
        for (a, b) in zip(long, short) { #expect(hypot(a.x - b.x, a.y - b.y) < 1) }
    }
}

@Suite struct BlobGeometryTests {
    @Test func fullRoundnessIsAPerfectCircle() {
        for phase in stride(from: 0.0, to: 6.0, by: 0.7) {
            for time in [0.0, 1.3, 42.0] {
                #expect(BlobGeometry.radii(phase: phase, time: time, roundness: 100) == Array(repeating: 0.5, count: 8))
            }
        }
    }

    @Test func zeroRoundnessWobblesUpToThirtyPercent() {
        var maxDeviation = 0.0
        for phase in stride(from: 0.0, to: 6.3, by: 0.3) {
            for time in stride(from: 0.0, to: 20.0, by: 0.5) {
                let r = BlobGeometry.radii(phase: phase, time: time, roundness: 0)
                #expect(r.count == 8)
                for value in r {
                    #expect(value >= 0.2 - 1e-9 && value <= 0.8 + 1e-9)
                    maxDeviation = max(maxDeviation, abs(value - 0.5))
                }
                // Opposite corners share an edge: horizontal radii on top and bottom edges sum to 1.
                #expect(abs(r[0] + r[1] - 1) < 1e-9)
                #expect(abs(r[2] + r[3] - 1) < 1e-9)
                #expect(abs(r[4] + r[7] - 1) < 1e-9)
                #expect(abs(r[5] + r[6] - 1) < 1e-9)
            }
        }
        #expect(maxDeviation > 0.28)
    }

    @Test func halfRoundnessHalvesTheAmplitude() {
        for time in stride(from: 0.0, to: 10.0, by: 0.25) {
            for value in BlobGeometry.radii(phase: 1.1, time: time, roundness: 50) {
                #expect(value >= 0.35 - 1e-9 && value <= 0.65 + 1e-9)
            }
        }
    }

    /// Story 40: the smooth outline — radial factors for evenly spaced points, a circle at "Shape" 100.
    @Test func outlineIsACircleAtFullRoundness() {
        let o = BlobGeometry.outline(phase: 1.7, time: 12, roundness: 100, count: 10)
        #expect(o == Array(repeating: 1.0, count: 10))
        #expect(BlobGeometry.outline(phase: 0, time: 0, roundness: 50, count: 12).count == 12)
    }

    /// Story 50: the soap-bubble outline is the prototype's `radiusAt` — harmonics 2…8, the higher ones only
    /// when the shape gets chaotic. Expected values worked out by hand from the prototype formula at a = π/2,
    /// phase 0, time 0, where only the odd harmonics count (sin 3π/2 = −1, sin 5π/2 = 1, sin 7π/2 = −1):
    /// "Shape" 0: s = −1/3 + 1.24/5 − 0.88/7 = −0.211048 → 1 + 0.32·s = 0.932465;
    /// "Shape" 50: s = −1/3 + 0.44/5 − 0.08/7 = −0.256762 → 1 + 0.5·0.32·s = 0.958918.
    @Test func outlineFollowsThePrototypeHarmonics() {
        #expect(abs(BlobGeometry.outline(phase: 0, time: 0, roundness: 0, count: 4)[1] - 0.932465) < 1e-5)
        #expect(abs(BlobGeometry.outline(phase: 0, time: 0, roundness: 50, count: 4)[1] - 0.958918) < 1e-5)
        #expect(abs(BlobGeometry.radius(at: .pi / 2, phase: 0, time: 0, roundness: 0) - 0.932465) < 1e-5)
    }

    /// "Shape" 0 is the scattered bubble: a large spread and more lobes than the two or three of a soft drop.
    @Test func zeroRoundnessIsScattered() {
        var widest = 0.0, mostLobes = 0
        for phase in stride(from: 0.0, to: 6.3, by: 0.5) {
            for time in stride(from: 0.0, to: 30.0, by: 0.9) {
                let o = BlobGeometry.outline(phase: phase, time: time, roundness: 0, count: 96)
                widest = max(widest, (o.max() ?? 1) - (o.min() ?? 1))
                let lobes = o.indices.filter { i in
                    o[i] > o[(i + 95) % 96] && o[i] >= o[(i + 1) % 96]
                }.count
                mostLobes = max(mostLobes, lobes)
            }
        }
        #expect(widest > 0.6)
        #expect(mostLobes >= 5)
    }

    @Test func outlineStaysInsideItsMarginAndKeepsItsSize() {
        var widest = 0.0
        for phase in stride(from: 0.0, to: 6.3, by: 0.4) {
            for time in stride(from: 0.0, to: 30.0, by: 0.7) {
                let o = BlobGeometry.outline(phase: phase, time: time, roundness: 0, count: 48)
                for value in o {
                    #expect(value >= 1 - BlobGeometry.maxDeviation - 1e-9 && value <= 1 + BlobGeometry.maxDeviation + 1e-9)
                    widest = max(widest, abs(value - 1))
                }
                #expect(abs(o.reduce(0, +) / Double(o.count) - 1) < 1e-9)   // harmonics only: the mean is the circle
            }
        }
        #expect(widest > BlobGeometry.maxDeviation * 0.5)
        // Default "Shape" 70: a gentle drop.
        for time in stride(from: 0.0, to: 30.0, by: 0.5) {
            for value in BlobGeometry.outline(phase: 2.2, time: time, roundness: 70, count: 48) {
                #expect(abs(value - 1) <= 0.1)
            }
        }
    }

    /// Inner folds of the film show only when the shape is chaotic (chaos > 0.25, i.e. "Shape" < 75).
    @Test func foldsAppearOnlyWhenChaotic() {
        #expect(BlobGeometry.foldStrength(roundness: 100) == 0)
        #expect(BlobGeometry.foldStrength(roundness: 75) == 0)
        #expect(abs(BlobGeometry.foldStrength(roundness: 0) - 0.375) < 1e-12)
    }

    /// Prototype speeds (0.35 + 0.07·k rad/s per harmonic) move the scattered outline at most ~0.37 r/s,
    /// about 0.006 r per 60 Hz frame — still no visible jump.
    @Test func outlineChangesSlowly() {
        for time in stride(from: 0.0, to: 20.0, by: 0.37) {
            let a = BlobGeometry.outline(phase: 0.9, time: time, roundness: 0, count: 48)
            let b = BlobGeometry.outline(phase: 0.9, time: time + 1.0 / 60, roundness: 0, count: 48)
            for (x, y) in zip(a, b) { #expect(abs(x - y) < 0.0075) }
        }
    }
}
