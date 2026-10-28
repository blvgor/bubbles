import CoreGraphics
import Foundation

/// One bubble in the simulation. Coordinates are window coordinates with a bottom-left origin.
/// A fixed circle in window coordinates that bubbles cannot enter.
public struct KeepOutZone: Equatable, Sendable {
    public var center: CGPoint
    public var radius: CGFloat
    public init(center: CGPoint, radius: CGFloat) {
        self.center = center
        self.radius = radius
    }
}

/// The mouse as the world sees it: position in window coordinates and velocity in points per second.
/// Set on `PhysicsWorld.cursor` while "Can't catch me" is on, so the bubbles flee from it.
public struct CursorState: Equatable, Sendable {
    public var position: CGPoint
    public var velocity: CGVector
    public init(position: CGPoint, velocity: CGVector = .zero) {
        self.position = position
        self.velocity = velocity
    }
}

public struct BubbleBody: Identifiable, Sendable {
    /// Equals `DayTask.id`.
    public let id: UUID
    /// Centre.
    public var position: CGPoint
    public var velocity: CGVector
    public var radius: CGFloat
    public var targetRadius: CGFloat
    public var anchor: CGPoint
    public var rank: Int
    public var surfaced: Bool
    /// Blob shape phase, wander heading (rad), spin speed (rad/s), accumulated shape rotation (rad).
    public var phase: Double, wander: Double, spin: Double, rotation: Double
    /// Jelly squash amount (±0.18), its velocity, and the impact direction (rad).
    public var squash: Double, squashVelocity: Double, squashAngle: Double
    /// Seconds before it appears (bubbles fly out of the mic one after another).
    public var spawnDelay: Double

    /// Not yet visible: waiting for its turn to fly out.
    public var isWaiting: Bool { spawnDelay > 0 }
}

/// Elastic collisions between circles (mass ~ area), a jelly squash spring on impact, a wandering force so
/// they keep drifting, and a weak pull to each bubble's rank anchor. Port of `frame()` in `prototype/index.html`.
public struct PhysicsWorld: Sendable {
    public var bodies: [BubbleBody] = []
    /// Visible area: the screen's visibleFrame inset by 8.
    public var bounds: CGRect
    /// Drives the blob shape; advances by `dt × speed` while animating.
    public private(set) var shapeTime: Double = 0
    /// Ranked tasks beyond `maxVisible`, shown as the "+N" bubble.
    public private(set) var overflowCount: Int = 0
    /// A fixed circle bubbles bounce off (the mic on the desk); nil when nothing is there.
    public var keepOut: KeepOutZone?
    /// "Shape" (0…100) of the drawn outline: contact uses the visible soap-bubble edge, not a circle.
    public var roundness: Double = 100
    /// "Can't catch me": the cursor the bubbles run from; nil turns fleeing off.
    public var cursor: CursorState?

    public static let maxVisible = 8

    private var surfacedID: UUID?
    private var rng: SplitMix64
    /// Simulation time not yet stepped (less than one substep) and the wander clock.
    private var pending: Double = 0
    private var clock: Double = 0

    /// `seed` makes the wander and spawn randomness reproducible (tests); nil seeds from the system.
    public init(bounds: CGRect, seed: UInt64? = nil) {
        self.bounds = bounds
        rng = SplitMix64(seed: seed ?? UInt64.random(in: .min ... .max))
    }

    // MARK: - Layout

    /// `clamp(64, min(w, h) × 0.15, 132)`.
    public static func baseRadius(for size: CGSize) -> CGFloat {
        max(64, min(132, min(size.width, size.height) * 0.15))
    }

    /// Rank 0 → 1.0, 1 → 0.8, 2 → 0.7, the rest → 0.5 of the base radius.
    public static func targetRadius(rank: Int, base: CGFloat) -> CGFloat {
        switch rank {
        case 0: base
        case 1: base * 0.8
        case 2: base * 0.7
        default: base * 0.5
        }
    }

    /// The three biggest near the centre, the rest evenly on an ellipse around them.
    public func anchor(rank: Int, count: Int) -> CGPoint {
        let cx = bounds.midX, cy = bounds.midY, w = bounds.width, h = bounds.height
        // Prototype offsets are in screen space (y down); flip y for the bottom-left origin.
        let big: [(x: CGFloat, y: CGFloat)] = [(0, -0.02), (-0.2, 0.14), (0.2, 0.14)]
        if rank < 3 { return CGPoint(x: cx + big[rank].x * w, y: cy - big[rank].y * h) }
        let k = max(1, count - 3)
        let a = -Double.pi / 2 + (Double(rank - 3) + 0.5) / Double(k) * Double.pi * 2
        return CGPoint(x: cx + CGFloat(cos(a)) * w * 0.38, y: cy - CGFloat(sin(a)) * h * 0.36)
    }

    /// Radius of the "+N" bubble.
    public var overflowRadius: CGFloat { max(28, Self.baseRadius(for: bounds.size) * 0.4) }

    /// Centre of the "+N" bubble: bottom-right corner of the visible area.
    /// The next ranked task emerges from here when a visible one is closed.
    public var overflowPoint: CGPoint {
        CGPoint(x: bounds.maxX - overflowRadius, y: bounds.minY + overflowRadius)
    }

    /// Adds, removes and re-ranks bodies to match `ids` (already ranked, highest first). Only the first
    /// `maxVisible` get bodies. New bodies fly out of `spawnFrom` one after another when given; without it
    /// they emerge from the "+N" bubble if there was one, otherwise appear at their anchor (first fill:
    /// full size; later: growing from a dot).
    /// Repeated ids are ignored after their first (highest-ranked) occurrence: one body per id.
    public mutating func sync(ranked ids: [UUID], spawnFrom: CGPoint?) {
        var seen = Set<UUID>()
        let unique = ids.filter { seen.insert($0).inserted }
        let visible = Array(unique.prefix(Self.maxVisible))
        let hadOverflow = overflowCount > 0
        let firstFill = bodies.isEmpty
        let source = overflowPoint
        overflowCount = max(0, unique.count - Self.maxVisible)
        if let s = surfacedID, !visible.contains(s) { surfacedID = nil }

        let base = Self.baseRadius(for: bounds.size)
        let existing = Dictionary(bodies.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [BubbleBody] = []
        var launched = 0
        for (rank, id) in visible.enumerated() {
            let anchor = anchor(rank: rank, count: visible.count)
            let surfaced = id == surfacedID
            let target = surfaced ? base * K.surfacedScale : Self.targetRadius(rank: rank, base: base)
            if var body = existing[id] {
                body.rank = rank
                body.anchor = anchor
                body.targetRadius = target
                body.surfaced = surfaced
                next.append(body)
                continue
            }
            let heading = rng.unit() * 2 * .pi
            var position = anchor
            var velocity = CGVector(dx: cos(heading) * 90, dy: sin(heading) * 90)
            var radius = target
            var delay = 0.0
            if let spawnFrom {
                position = spawnFrom
                velocity = CGVector(dx: cos(heading) * 90, dy: 220 + rng.unit() * 140)   // up, out of the mic
                radius = K.spawnRadius
                delay = Double(launched) * K.spawnStagger
                launched += 1
            } else if hadOverflow {
                position = source
                radius = K.spawnRadius
            } else if !firstFill {
                radius = K.spawnRadius
            }
            next.append(BubbleBody(
                id: id, position: position, velocity: velocity, radius: radius, targetRadius: target,
                anchor: anchor, rank: rank, surfaced: surfaced,
                phase: rng.unit() * 6.28, wander: heading, spin: (rng.unit() - 0.5) * 0.3, rotation: 0,
                squash: 0, squashVelocity: 0, squashAngle: 0, spawnDelay: delay))
        }
        bodies = next
    }

    /// Raises one bubble above the windows (or none with nil): it heads to the centre and grows ×1.35.
    public mutating func setSurfaced(_ id: UUID?) {
        surfacedID = id.flatMap { id in bodies.contains { $0.id == id } ? id : nil }
        let base = Self.baseRadius(for: bounds.size)
        for i in bodies.indices {
            let on = bodies[i].id == surfacedID
            bodies[i].surfaced = on
            bodies[i].targetRadius = on ? base * K.surfacedScale : Self.targetRadius(rank: bodies[i].rank, base: base)
        }
    }

    // MARK: - Simulation

    /// Advances the world. `speed` is a fraction (settings % / 100): 0 freezes, 2 is "racing".
    /// `animate == false` snaps bodies to their anchors at target size, with no squash.
    /// The frame is simulated in fixed 1/240-s substeps (the remainder carries over to the next frame),
    /// so a long frame lands where several short ones would and nothing tunnels or jolts.
    public mutating func step(dt rawDt: Double, speed: Double, animate: Bool, rotate: Bool) {
        let dt = min(K.maxDt, max(0, rawDt))
        let sp = max(0, speed)
        if animate && sp > 0 { shapeTime += dt * sp }
        pending += dt
        while pending >= K.substep {
            pending -= K.substep
            substep(K.substep, speed: sp, animate: animate, rotate: rotate)
        }
        if !animate { substep(0, speed: sp, animate: false, rotate: rotate) }   // snap right away
    }

    private mutating func substep(_ h: Double, speed sp: Double, animate: Bool, rotate: Bool) {
        let moving = animate && sp > 0
        if moving { clock += h * sp }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        /// Per body: the flee speed (velocity units) it is chasing this substep; 0 = not fleeing.
        var fleeSpeed = [Double](repeating: 0, count: bodies.count)
        var live: [Int] = []
        for i in bodies.indices {
            if bodies[i].spawnDelay > 0 {
                bodies[i].spawnDelay = max(0, bodies[i].spawnDelay - h)
            } else {
                live.append(i)
            }
        }

        // Forces: spring to the anchor (or the centre when surfaced) plus a wandering push whose heading
        // follows smooth noise, so the drift never changes direction abruptly.
        for i in live {
            var b = bodies[i]
            b.radius += (b.targetRadius - b.radius) * CGFloat(min(1, h * K.radiusLerp))
            if !animate {
                b.position = b.surfaced ? centre : b.anchor
                b.radius = b.targetRadius
                b.velocity = .zero
                b.squash = 0
                b.squashVelocity = 0
                bodies[i] = b
                continue
            }
            let target = b.surfaced ? centre : b.anchor
            let k = b.surfaced ? K.surfacedSpring : K.anchorSpring
            b.wander = Self.wanderHeading(phase: b.phase, clock: clock)
            let ax = Double(target.x - b.position.x) * k + cos(b.wander) * K.wander * sp
            let ay = Double(target.y - b.position.y) * k + sin(b.wander) * K.wander * sp
            b.velocity.dx += ax * h
            b.velocity.dy += ay * h
            if let cursor, let speed = flee(&b, from: cursor, h: h, speed: sp) { fleeSpeed[i] = speed }
            bodies[i] = b
        }
        guard animate else { return }

        for p in live.indices {
            for q in live.indices where q > p {
                collide(live[p], live[q])
            }
        }

        let damp = pow(K.damping, h)
        let cap = K.capBase + K.capPerSpeed * sp
        for i in live {
            var b = bodies[i]
            b.velocity.dx *= damp
            b.velocity.dy *= damp
            let fleeing = fleeSpeed[i] > 0
            // A fleeing bubble may outrun the drift cap and moves in real time even at "Frozen";
            // it does not bounce off walls back towards the cursor.
            let bodyCap = fleeing ? max(cap, fleeSpeed[i] * 1.05) : cap
            let v = hypot(b.velocity.dx, b.velocity.dy)
            if v > bodyCap {
                b.velocity.dx *= bodyCap / v
                b.velocity.dy *= bodyCap / v
            }
            let advance = h * (fleeing ? Self.fleeTimeScale(sp) : max(sp, 0.05))
            let wallRestitution = fleeing ? 0 : K.wallRestitution
            b.position.x += b.velocity.dx * advance
            b.position.y += b.velocity.dy * advance

            // Walls and the mic meet the visible edge in their direction, not the circle.
            let left = reach(b, toward: .pi), right = reach(b, toward: 0)
            let down = reach(b, toward: -.pi / 2), up = reach(b, toward: .pi / 2)
            if b.position.x < bounds.minX + left {
                Self.kick(&b, nx: 1, ny: 0, impact: abs(b.velocity.dx))
                b.position.x = bounds.minX + left
                b.velocity.dx = abs(b.velocity.dx) * wallRestitution
            }
            if b.position.x > bounds.maxX - right {
                Self.kick(&b, nx: 1, ny: 0, impact: abs(b.velocity.dx))
                b.position.x = bounds.maxX - right
                b.velocity.dx = -abs(b.velocity.dx) * wallRestitution
            }
            if b.position.y < bounds.minY + down {
                Self.kick(&b, nx: 0, ny: 1, impact: abs(b.velocity.dy))
                b.position.y = bounds.minY + down
                b.velocity.dy = abs(b.velocity.dy) * wallRestitution
            }
            if b.position.y > bounds.maxY - up {
                Self.kick(&b, nx: 0, ny: 1, impact: abs(b.velocity.dy))
                b.position.y = bounds.maxY - up
                b.velocity.dy = -abs(b.velocity.dy) * wallRestitution
            }
            if let zone = keepOut {
                // Bounce off the zone like off a wall: push out along the normal, reflect the inward speed.
                let dx = b.position.x - zone.center.x, dy = b.position.y - zone.center.y
                let d = max(hypot(dx, dy), 0.01)
                let minimum = reach(b, toward: atan2(-dy, -dx)) + zone.radius + K.keepOutGap
                if d < minimum {
                    let nx = dx / d, ny = dy / d
                    b.position.x = zone.center.x + nx * minimum
                    b.position.y = zone.center.y + ny * minimum
                    let inward = b.velocity.dx * nx + b.velocity.dy * ny
                    if inward < 0 {
                        Self.kick(&b, nx: nx, ny: ny, impact: -inward)
                        b.velocity.dx -= (1 + wallRestitution) * inward * nx
                        b.velocity.dy -= (1 + wallRestitution) * inward * ny
                    }
                }
            }

            b.squashVelocity += (-K.squashStiffness * b.squash - K.squashDamping * b.squashVelocity) * h
            b.squash = min(K.squashLimit, max(-K.squashLimit, b.squash + b.squashVelocity * h))
            if rotate && moving { b.rotation += b.spin * h * sp }
            bodies[i] = b
        }
    }

    // MARK: - "Can't catch me"

    /// Velocity is scaled by this when a fleeing body moves: real time at "Speed" ≤ 100 %, faster above.
    static func fleeTimeScale(_ speed: Double) -> Double { max(speed, 1) }

    /// Steers `b` away from the cursor. Within `K.fleeReach` of the bubble's edge the body's velocity is
    /// pulled towards a flee velocity whose size grows as the cursor comes closer and with the cursor's
    /// speed. Returns that flee speed in velocity units, or nil when the cursor is out of reach.
    private func flee(_ b: inout BubbleBody, from cursor: CursorState, h: Double, speed sp: Double) -> Double? {
        let dx = Double(b.position.x - cursor.position.x), dy = Double(b.position.y - cursor.position.y)
        let gap = max(0, hypot(dx, dy) - Double(b.radius))
        let closeness = 1 - gap / K.fleeReach
        guard closeness > 0 else { return nil }
        let cursorSpeed = hypot(Double(cursor.velocity.dx), Double(cursor.velocity.dy))
        let scale = Self.fleeTimeScale(sp)
        let target = (K.fleeBase + K.fleeSpeedGain * cursorSpeed) * closeness / scale
        let dir = Self.fleeDirection(away: CGVector(dx: dx, dy: dy), body: b.position, velocity: b.velocity,
                                     radius: b.radius, bounds: bounds)
        let rate = min(1, h * K.fleeResponse)
        b.velocity.dx += (dir.dx * target - b.velocity.dx) * rate
        b.velocity.dy += (dir.dy * target - b.velocity.dy) * rate
        return target
    }

    /// Unit direction away from the cursor (`away` = body − cursor). A component that would push into a
    /// wall the body touches is dropped; if nothing is left (cursor straight behind, or a corner), the body
    /// slips along the wall: to the side it is offset to, else the way it is already going, else towards
    /// the middle of the desk — so the choice does not flicker between substeps.
    static func fleeDirection(away: CGVector, body: CGPoint, velocity: CGVector, radius: CGFloat,
                              bounds: CGRect) -> CGVector {
        let length = hypot(away.dx, away.dy)
        var nx: Double, ny: Double
        if length > 0.01 {
            nx = Double(away.dx / length)
            ny = Double(away.dy / length)
        } else {   // cursor on the centre: head for the middle of the desk
            let mx = Double(bounds.midX - body.x), my = Double(bounds.midY - body.y)
            let m = hypot(mx, my)
            (nx, ny) = m > 0.01 ? (mx / m, my / m) : (0, 1)
        }
        let margin = K.fleeWallMargin
        let atLeft = body.x - radius <= bounds.minX + margin, atRight = body.x + radius >= bounds.maxX - margin
        let atBottom = body.y - radius <= bounds.minY + margin, atTop = body.y + radius >= bounds.maxY - margin
        let blockX = (atLeft && nx < 0) || (atRight && nx > 0)
        let blockY = (atBottom && ny < 0) || (atTop && ny > 0)
        if blockX { nx = 0 }
        if blockY { ny = 0 }
        let left = hypot(nx, ny)
        if left > 0.2 { return CGVector(dx: nx / left, dy: ny / left) }

        // Slide along a wall. One wall: along it. A corner: along the axis the cursor is less offset on.
        let alongY = blockX && !blockY ? true : (blockY && !blockX ? false : abs(away.dy) <= abs(away.dx))
        func sign(offset: CGFloat, moving: CGFloat, toMiddle: CGFloat, low: Bool, high: Bool) -> Double {
            if high { return -1 }   // the far wall of a corner: the only way out
            if low { return 1 }
            if abs(offset) > K.fleeSideOffset { return offset < 0 ? -1 : 1 }
            if abs(moving) > K.fleeSideSpeed { return moving < 0 ? -1 : 1 }
            return toMiddle < 0 ? -1 : 1
        }
        if alongY {
            return CGVector(dx: 0, dy: sign(offset: away.dy, moving: velocity.dy, toMiddle: bounds.midY - body.y,
                                            low: atBottom, high: atTop))
        }
        return CGVector(dx: sign(offset: away.dx, moving: velocity.dx, toMiddle: bounds.midX - body.x,
                                 low: atLeft, high: atRight), dy: 0)
    }

    /// Wander heading (rad): two slow incommensurate sines per bubble — smooth noise, no random jolts.
    static func wanderHeading(phase: Double, clock: Double) -> Double {
        phase * 7 + 1.6 * sin(clock * 0.21 + phase * 3) + 0.9 * sin(clock * 0.47 + phase * 5 + 1.3)
    }

    /// The visible bubble under `point`: surfaced first, then the biggest (lowest rank).
    public func body(at point: CGPoint) -> BubbleBody? {
        bodies
            .filter { !$0.isWaiting && hypot($0.position.x - point.x, $0.position.y - point.y) <= $0.radius }
            .min { ($0.surfaced ? -1 : $0.rank) < ($1.surfaced ? -1 : $1.rank) }
    }

    // MARK: - Internals

    /// Soft contact: overlap is resolved gradually (a share per substep, small slop), slow contacts
    /// just stop instead of bouncing, and real impacts bounce with a low restitution and squash the jelly.
    /// Distance from a bubble's centre to its drawn edge in a world direction: the soap-bubble outline
    /// (`BlobGeometry`, the same phase and time the canvas draws with), turned by the bubble's spin.
    public func reach(_ b: BubbleBody, toward angle: Double) -> CGFloat {
        b.radius * CGFloat(BlobGeometry.radius(at: angle - b.rotation, phase: b.phase, time: shapeTime,
                                                roundness: roundness))
    }

    private mutating func collide(_ i: Int, _ j: Int) {
        var a = bodies[i], c = bodies[j]
        let dx = Double(c.position.x - a.position.x), dy = Double(c.position.y - a.position.y)
        let d = max(hypot(dx, dy), 0.01)
        let towardC = atan2(dy, dx)
        let minDistance = Double(reach(a, toward: towardC) + reach(c, toward: towardC + .pi)) + K.contactGap
        guard d < minDistance else { return }
        let nx = dx / d, ny = dy / d
        let ma = Double(a.radius * a.radius) * (a.surfaced ? K.surfacedMass : 1)
        let mc = Double(c.radius * c.radius) * (c.surfaced ? K.surfacedMass : 1)
        let overlap = max(0, minDistance - d - K.contactSlop)
        let push = overlap * K.contactSoftness
        a.position.x -= nx * push * mc / (ma + mc)
        a.position.y -= ny * push * mc / (ma + mc)
        c.position.x += nx * push * ma / (ma + mc)
        c.position.y += ny * push * ma / (ma + mc)
        let rv = Double(c.velocity.dx - a.velocity.dx) * nx + Double(c.velocity.dy - a.velocity.dy) * ny
        if rv < 0 {
            let impact = -rv
            let e = impact > K.restingSpeed ? K.restitution : 0
            let impulse = -(1 + e) * rv / (1 / ma + 1 / mc)
            a.velocity.dx -= impulse * nx / ma
            a.velocity.dy -= impulse * ny / ma
            c.velocity.dx += impulse * nx / mc
            c.velocity.dy += impulse * ny / mc
            if impact > K.restingSpeed {
                Self.kick(&a, nx: nx, ny: ny, impact: impact)
                Self.kick(&c, nx: nx, ny: ny, impact: impact)
            }
        }
        bodies[i] = a
        bodies[j] = c
    }

    private static func kick(_ b: inout BubbleBody, nx: Double, ny: Double, impact: Double) {
        guard impact > K.restingSpeed else { return }
        b.squashAngle = atan2(ny, nx)
        b.squashVelocity -= min(K.kickLimit, impact * K.kickScale)
    }

    /// Constants: layout ones from `prototype/index.html`; motion softened after the first build (story 39).
    private enum K {
        static let maxDt = 0.05
        static let substep = 1.0 / 240
        static let anchorSpring = 0.12
        static let surfacedSpring = 2.5
        static let wander = 46.0
        static let restitution = 0.5
        static let restingSpeed = 24.0
        static let surfacedMass = 6.0
        static let contactGap = 2.0
        static let contactSlop = 0.5
        static let contactSoftness = 0.25
        static let damping = 0.45
        static let capBase = 120.0
        static let capPerSpeed = 220.0
        static let wallRestitution = 0.45
        static let keepOutGap: CGFloat = 8
        static let squashStiffness = 80.0
        static let squashDamping = 8.0
        static let squashLimit = 0.08
        static let kickLimit = 1.0
        static let kickScale = 0.0025
        static let radiusLerp = 4.0
        static let surfacedScale: CGFloat = 1.35
        static let spawnRadius: CGFloat = 4
        static let spawnStagger = 0.11
        // "Can't catch me": reach beyond the bubble's edge (pt), flee speed at the edge for a resting cursor
        // (pt/s) plus a share of the cursor's speed, how fast the velocity turns to it (1/s), wall contact.
        static let fleeReach = 180.0
        static let fleeBase = 260.0
        static let fleeSpeedGain = 1.3
        static let fleeResponse = 24.0
        static let fleeWallMargin: CGFloat = 12
        static let fleeSideOffset: CGFloat = 2
        static let fleeSideSpeed: CGFloat = 1
    }
}

/// The blob outline: 8 CSS-style corner radii, gently drifting over time.
public enum BlobGeometry {
    /// Fractions 0...1 in the prototype's `border-radius` order:
    /// horizontal top-left, top-right, bottom-right, bottom-left / vertical top-left, top-right, bottom-right, bottom-left.
    /// Amplitude is `(100 − roundness) / 100 × 30 %` around 50 %: 100 → a circle, 0 → up to ±0.3.
    public static func radii(phase: Double, time: Double, roundness: Double) -> [Double] {
        let amp = (100 - min(100, max(0, roundness))) / 100 * 30
        func w(_ i: Double, _ shift: Double) -> Double {
            50 + amp * sin(time * (0.55 + i * 0.17) + phase * (i + 1) + shift)
        }
        let h0 = w(0, 0), h1 = w(1, 2), v0 = w(2, 4), v1 = w(3, 1)
        return [h0, 100 - h0, h1, 100 - h1, v0, v1, 100 - v1, 100 - v0].map { $0 / 100 }
    }
}

extension BlobGeometry {
    /// 0 at "Shape" 100 (a circle) … 1 at "Shape" 0 (the scattered soap bubble).
    public static func chaos(roundness: Double) -> Double { 1 - min(100, max(0, roundness)) / 100 }

    /// Weight of angular harmonic `k` (2…8): the two lowest always, the higher ones fade in only as the
    /// shape gets chaotic, so folds appear near "Shape" 0 (prototype `radiusAt`).
    static func harmonicWeight(_ k: Int, chaos: Double) -> Double {
        k <= 3 ? 1 : max(0, chaos * 1.6 - Double(k - 3) * 0.18)
    }

    /// Largest radial deviation the outline can reach (at "Shape" 0): 0.32 · Σ w_k / k.
    public static let maxDeviation: Double = 0.32 * (2...8).reduce(0) { $0 + harmonicWeight($1, chaos: 1) / Double($1) }

    /// Radial factor (1 = the circle of radius r) of the soap-bubble outline at `angle` (radians,
    /// counter-clockwise from +x): the prototype's `radiusAt` — harmonics 2…8 drifting at 0.35 + 0.07·k rad/s,
    /// amplitude `chaos · 0.32`. "Shape" 100 is exactly 1 everywhere.
    public static func radius(at angle: Double, phase: Double, time: Double, roundness: Double) -> Double {
        let chaos = chaos(roundness: roundness)
        guard chaos > 0 else { return 1 }
        var s = 0.0
        for k in 2...8 {
            let w = harmonicWeight(k, chaos: chaos)
            guard w > 0 else { continue }
            let kd = Double(k)
            s += w / kd * sin(kd * angle + time * (0.35 + kd * 0.07) + phase * kd)
        }
        return 1 + chaos * 0.32 * s
    }

    /// The outline (stories 40, 50): radial factors for `count` points evenly spaced counter-clockwise from +x.
    /// 48 points resolve the 8th harmonic; the mean stays exactly 1 (harmonics only).
    public static func outline(phase: Double, time: Double, roundness: Double, count: Int = 48) -> [Double] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            radius(at: Double(i) / Double(count) * 2 * .pi, phase: phase, time: time, roundness: roundness)
        }
    }

    /// Strength of the faint inner fold of the film: 0 until chaos passes 0.25 ("Shape" < 75), then
    /// `(chaos − 0.25) · 0.5` (prototype «Inner fold»).
    public static func foldStrength(roundness: Double) -> Double {
        max(0, chaos(roundness: roundness) - 0.25) * 0.5
    }
}

/// Small deterministic generator so the simulation can be replayed in tests.
struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
