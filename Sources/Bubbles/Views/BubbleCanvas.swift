import AppKit
import BubblesCore
import QuartzCore
import SwiftUI

/// Draws one overlay window's bubbles with Core Animation (stories 39–41). Per display frame only layer
/// positions, paths and a few filter values change; SwiftUI content is a cached image. Coordinates are
/// the window's, bottom-left origin — the same as `PhysicsWorld`.
/// Desk: background soap bubbles, the "+N" bubble, the mic and desk pops.
/// Float: the surfaced bubble (soap film over the system blur), and its pop.
@MainActor final class BubbleCanvas: NSView {
    let deskLayer: DeskLayer
    private weak var model: AppModel?
    private let root = CALayer()
    private var nodes: [UUID: BubbleNode] = [:]
    private var overflow: BubbleNode?
    private var mic: BubbleNode?
    private var micScale: CGFloat = 1
    private var shownPops: Set<UUID> = []
    /// Full title above a hovered bubble whose title is cut.
    private let tooltip = CALayer()
    private var tooltipKey: String?

    init(deskLayer: DeskLayer, model: AppModel) {
        self.deskLayer = deskLayer
        self.model = model
        super.init(frame: .zero)
        layer = root          // layer-hosting: we own the tree
        wantsLayer = true
        root.masksToBounds = false
        tooltip.zPosition = 400
        tooltip.contentsGravity = .resizeAspect
        tooltip.isHidden = true
        root.addSublayer(tooltip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // the window routes clicks

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: - Frame

    func render(now: CFTimeInterval) {
        guard let model else { return }
        let settings = model.settingsStore.settings
        let world = model.world
        let visible = settings.hidden == .visible
        let style = NodeStyle(tint: settings.tint, animate: settings.animation, now: now,
                              systemGlass: deskLayer == .float, scale: scale,
                              colorSpace: window?.colorSpace?.cgColorSpace)
        let filmTime = settings.animation ? world.shapeTime : 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        model.setHover(visible ? hoveredBody(model: model, world: world) : nil, layer: deskLayer)
        let hovered = model.hoveredBubble
        var tip: (task: DayTask, center: CGPoint, radius: CGFloat)?

        var alive = Set<UUID>()
        if visible {
            let tasks = Dictionary(model.taskStore.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for body in world.bodies where !body.isWaiting && body.surfaced == (deskLayer == .float) {
                guard let task = tasks[body.id] else { continue }
                alive.insert(body.id)
                let node = nodes[body.id] ?? addNode { nodes[body.id] = $0 }
                node.container.zPosition = CGFloat(100 - body.rank)   // lowest rank on top, like the prototype
                let sizeClass = BubbleSizeClass(rank: body.rank, targetRadius: body.targetRadius)
                let key = "\(task.title)|\(task.priority.rawValue)|\(task.dueText ?? task.note ?? "")|\(sizeClass)|\(Int(body.targetRadius.rounded()))"
                node.setContent(key: key, radius: body.targetRadius, scale: scale) {
                    BubbleContent(task: task, radius: body.targetRadius, sizeClass: sizeClass)
                }
                let swaying = settings.rotation && settings.animation
                let t = world.shapeTime
                // Hover: a little bigger (and slower, see `AppModel.advanceFrame`); held: bigger still.
                let grow: CGFloat = model.draggedBubble == body.id ? 1.12 : (hovered == body.id ? 1.08 : 1)
                node.hoverScale += (grow - node.hoverScale) * (settings.animation ? 0.25 : 1)
                let radius = body.radius * node.hoverScale
                if hovered == body.id, Self.titleIsCut(task, radius: body.targetRadius, sizeClass: sizeClass) {
                    tip = (task, body.position, radius)
                }
                node.update(
                    center: body.position, radius: radius,
                    outline: BlobGeometry.outline(phase: body.phase, time: filmTime, roundness: settings.roundness),
                    shape: FilmShape(phase: body.phase, time: filmTime, roundness: settings.roundness),
                    squash: settings.animation ? body.squash : 0, squashAngle: body.squashAngle,
                    rotation: settings.rotation ? body.rotation : 0,
                    tilt: swaying ? sin(t * 0.8 + body.phase) * 12 : 0,
                    sway: swaying ? CGFloat(sin(t * 0.6 + body.phase * 2)) * body.radius * 0.04 : 0,
                    pulse: body.surfaced ? .hot : (body.rank == 0 ? .top : .none),
                    style: style)
            }
        }
        for (id, node) in nodes where !alive.contains(id) {
            node.remove()
            nodes[id] = nil
        }

        renderTooltip(tip, bounds: world.bounds)
        renderOverflow(world: world, visible: visible && deskLayer == .desk, style: style)
        renderMic(model: model, visible: deskLayer == .desk && settings.micOnDesk, style: style)
        renderPops(model.pops.filter { $0.layer == deskLayer }, settings: settings, style: style)
    }

    /// The bubble under the cursor in this window, if this window is the topmost one there.
    private func hoveredBody(model: AppModel, world: PhysicsWorld) -> UUID? {
        guard let window else { return nil }
        let mouse = NSEvent.mouseLocation
        guard window.frame.contains(mouse),
              NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0) == window.windowNumber else { return nil }
        let point = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        guard case .bubble(let id)? = model.target(at: point, layer: deskLayer), id != AppModel.overflowTargetID else { return nil }
        return id
    }

    /// Whether the title does not fit the bubble (`BubbleContent`: bold system font, 3 or 2 lines,
    /// shrinks to 0.8 before truncating). Only then does hovering show the full title.
    static func titleIsCut(_ task: DayTask, radius: CGFloat, sizeClass: BubbleSizeClass) -> Bool {
        let size = min(22, max(11, radius * 0.155)) * 0.8
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let width = 2 * radius * (1 - 2 * 0.24)
        let measure = { (text: String) in
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]).height
        }
        let used = measure(task.title)
        // One line measured the same way: Cyrillic (titles may be Russian) falls back to a font with taller
        // lines than `font`, so the sample is the Cyrillic "Pr".
        let lineHeight = measure("\u{41F}\u{440}")
        let lines = sizeClass == .regular ? 3 : 2
        // SwiftUI fits a little more than this estimate (tracking, scaling), so allow one extra line:
        // the tooltip is for titles that are visibly cut with «…», not for ones that only look long.
        return used > lineHeight * CGFloat(lines + 1) + 1
    }

    private func renderTooltip(_ tip: (task: DayTask, center: CGPoint, radius: CGFloat)?, bounds: CGRect) {
        guard let tip else {
            tooltip.isHidden = true
            return
        }
        let key = "\(tip.task.title)|\(tip.task.dueText ?? "")"
        if key != tooltipKey {
            tooltipKey = key
            let view = BubbleTooltip(task: tip.task)
            let image = BubbleArt.image(view, scale: scale)
            tooltip.contents = image
            tooltip.contentsScale = scale
            if let image {
                tooltip.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
            }
        }
        let size = tooltip.bounds.size
        var position = CGPoint(x: tip.center.x, y: tip.center.y + tip.radius + 12 + size.height / 2)
        if position.y + size.height / 2 > bounds.maxY { position.y = tip.center.y - tip.radius - 12 - size.height / 2 }
        position.x = min(max(position.x, bounds.minX + size.width / 2), bounds.maxX - size.width / 2)
        tooltip.position = position
        tooltip.isHidden = false
    }

    private func addNode(_ store: (BubbleNode) -> Void) -> BubbleNode {
        let node = BubbleNode(canvas: self)
        root.addSublayer(node.container)
        store(node)
        return node
    }

    private func renderOverflow(world: PhysicsWorld, visible: Bool, style: NodeStyle) {
        guard visible, world.overflowCount > 0 else {
            overflow?.remove()
            overflow = nil
            return
        }
        let node = overflow ?? addNode { overflow = $0 }
        let r = world.overflowRadius, count = world.overflowCount
        node.container.zPosition = 1
        node.setContent(key: "+\(count)|\(Int(r))", radius: r, scale: style.scale) {
            BubbleArt.overflowLabel(count: count, radius: r)
        }
        node.update(center: world.overflowPoint, radius: r, outline: Self.circle,
                    shape: FilmShape(phase: 2.1, time: style.animate ? world.shapeTime : 0, roundness: 100),
                    squash: 0, squashAngle: 0, rotation: 0, tilt: 0, sway: 0, pulse: .none, style: style)
    }

    private func renderMic(model: AppModel, visible: Bool, style: NodeStyle) {
        guard visible else {
            mic?.remove()
            mic = nil
            return
        }
        let node = mic ?? addNode { mic = $0 }
        node.container.zPosition = 200
        node.setContent(key: "mic", radius: DeskHit.micRadius, scale: style.scale) { BubbleArt.micGlyph }
        micScale += ((model.micHovered ? 1.06 : 1) - micScale) * 0.25
        node.update(center: model.micCenter, radius: DeskHit.micRadius * micScale, outline: Self.circle,
                    shape: FilmShape(phase: 4.0, time: style.animate ? model.world.shapeTime : 0, roundness: 100),
                    squash: 0, squashAngle: 0, rotation: 0, tilt: 0, sway: 0, pulse: .none, style: style)
    }

    /// A closed bubble grows ×1.5 while fading out (0.45 s), with 14 mint sparks flying off.
    private func renderPops(_ pops: [PopEffect], settings: BubbleSettings, style: NodeStyle) {
        shownPops.formIntersection(pops.map(\.id))
        for pop in pops where !shownPops.contains(pop.id) {
            shownPops.insert(pop.id)
            let body = pop.body
            let node = BubbleNode(canvas: self)
            node.container.zPosition = 300
            root.addSublayer(node.container)
            let sizeClass = BubbleSizeClass(rank: body.rank, targetRadius: body.targetRadius)
            node.setContent(key: "pop", radius: body.radius, scale: style.scale) {
                BubbleContent(task: pop.task, radius: body.radius, sizeClass: sizeClass)
            }
            node.update(center: body.position, radius: body.radius,
                        outline: BlobGeometry.outline(phase: body.phase, time: 0, roundness: settings.roundness),
                        shape: FilmShape(phase: body.phase, time: 0, roundness: settings.roundness),
                        squash: 0, squashAngle: 0, rotation: 0, tilt: 0, sway: 0, pulse: .none,
                        style: style.withoutSystemGlass)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 1.5
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(name: .easeIn)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            node.container.add(group, forKey: "pop")

            var sparks: [CALayer] = []
            let mint = CGColor(red: 0x86 / 255, green: 0xF5 / 255, blue: 0xB8 / 255, alpha: 1)
            for spark in pop.sparks {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
                dot.cornerRadius = 4
                dot.backgroundColor = mint
                dot.zPosition = 301
                let from = CGPoint(x: body.position.x + cos(spark.angle) * body.radius * 0.7,
                                   y: body.position.y + sin(spark.angle) * body.radius * 0.7)
                let to = CGPoint(x: body.position.x + cos(spark.angle) * body.radius * spark.reach,
                                 y: body.position.y + sin(spark.angle) * body.radius * spark.reach)
                dot.position = to
                dot.opacity = 0
                root.addSublayer(dot)
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: from)
                move.toValue = NSValue(point: to)
                let shrink = CABasicAnimation(keyPath: "transform.scale")
                shrink.fromValue = 1
                shrink.toValue = 0.01
                let vanish = CABasicAnimation(keyPath: "opacity")
                vanish.fromValue = 1
                vanish.toValue = 0
                let flight = CAAnimationGroup()
                flight.animations = [move, shrink, vanish]
                flight.duration = spark.duration
                flight.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                dot.add(flight, forKey: "spark")
                sparks.append(dot)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                node.remove()
                sparks.forEach { $0.removeFromSuperlayer() }
            }
        }
    }

    // MARK: - System glass views

    /// Effect views sit right under the canvas in the window's root view.
    func attach(_ view: BlobEffectView) {
        guard let superview else { return }
        superview.addSubview(view, positioned: .below, relativeTo: self)
    }

    static let circle = Array(repeating: 1.0, count: 10)
}

@MainActor struct NodeStyle {
    var tint: GlassTint
    var animate: Bool
    var now: CFTimeInterval
    /// The system's behind-window blur under the film: only the surfaced bubble, above windows, so its text
    /// stays readable on any window. Desk bubbles are clear soap film (story 50), whatever the old glass
    /// setting says.
    var systemGlass: Bool
    var scale: CGFloat
    var colorSpace: CGColorSpace?

    /// Pops are short-lived: film only.
    var withoutSystemGlass: NodeStyle {
        var s = self
        s.systemGlass = false
        return s
    }
}

/// What the soap film of a node follows: the same outline parameters as `BlobGeometry.outline`.
struct FilmShape {
    var phase: Double
    var time: Double
    var roundness: Double

    static let circle = FilmShape(phase: 0, time: 0, roundness: 100)
}

enum Pulse { case none, top, hot }

/// One bubble's layer tree, centred on `container.position` (story 50, the soap bubble):
/// hot glow (outside the outline only) · pulse halo · optional system blur (an `NSVisualEffectView` below the
/// canvas) · a whisper of radial darkening for the text · the soap film picture (`SoapFilm`, refreshed about
/// 5 times a second with a cross-fade, squashed and spun by the layer transform) · a thin light edge ·
/// content image (tilts and sways).
@MainActor final class BubbleNode {
    let container = CALayer()
    private weak var canvas: BubbleCanvas?

    private let glow = CALayer()
    private let glowMask = CAShapeLayer()
    private let ring = CALayer()
    private let ringMask = CAShapeLayer()
    private let darken = CAGradientLayer()
    private let film = CALayer()
    private let rim = CAShapeLayer()
    private let content = CALayer()
    private var effect: BlobEffectView?

    private var side: CGFloat = 0
    /// Eased size change while hovered or held.
    var hoverScale: CGFloat = 1
    private var contentKey: String?
    private var contentRadius: CGFloat = 1

    private var filmExtent: CGFloat = 1
    private var filmAt: CFTimeInterval
    private var filmInput: SoapFilm.Input?

    /// Film refresh rate while animating; the cross-fade between pictures hides the steps.
    private static let filmInterval: CFTimeInterval = 1.0 / 5

    init(canvas: BubbleCanvas) {
        self.canvas = canvas
        // Spread the film refreshes of different bubbles over the interval.
        filmAt = CACurrentMediaTime() - Double.random(in: 0..<Self.filmInterval)
        container.masksToBounds = false
        for layer in [glow, ring, darken, film, rim, content] as [CALayer] { container.addSublayer(layer) }

        glow.shadowColor = CGColor(red: 1, green: 45 / 255, blue: 85 / 255, alpha: 1)
        glow.shadowOpacity = 0
        glow.shadowRadius = 30
        glow.shadowOffset = .zero
        glowMask.fillRule = .evenOdd
        glow.mask = glowMask

        // The pulse is a soft halo (a blurred shadow of the outline, outside only): no second contour.
        ring.shadowOffset = .zero
        ring.shadowOpacity = 0
        ringMask.fillRule = .evenOdd
        ring.mask = ringMask

        // Interior: clear, with a whisper of darkening so the text reads on bright wallpaper (prototype).
        darken.type = .radial
        darken.startPoint = CGPoint(x: 0.5, y: 0.5)
        darken.endPoint = CGPoint(x: 1, y: 1)
        let ink = { (a: Double) in CGColor(srgbRed: 8 / 255, green: 4 / 255, blue: 20 / 255, alpha: a) }
        darken.colors = [ink(0.32), ink(0.12), ink(0)]
        darken.locations = [0, 0.75, 1]

        film.contentsGravity = .resize
        film.magnificationFilter = .linear
        film.minificationFilter = .linear

        rim.fillColor = nil
        rim.strokeColor = white(0.22)
        rim.lineJoin = .round

        content.contentsGravity = .resizeAspect
    }

    func remove() {
        container.removeFromSuperlayer()
        effect?.removeFromSuperview()
        effect = nil
    }

    /// Re-renders the SwiftUI content only when `key` changes.
    func setContent<V: View>(key: String, radius: CGFloat, scale: CGFloat, @ViewBuilder _ view: () -> V) {
        guard key != contentKey else { return }
        contentKey = key
        contentRadius = max(1, radius)
        content.contents = BubbleArt.image(view(), scale: scale)
        content.contentsScale = scale
        content.bounds = CGRect(x: 0, y: 0, width: 2 * contentRadius, height: 2 * contentRadius)
    }

    func update(center: CGPoint, radius: CGFloat, outline: [Double], shape: FilmShape, squash: Double,
                squashAngle: Double, rotation: Double, tilt: Double, sway: CGFloat, pulse: Pulse, style: NodeStyle) {
        let r = max(1, radius)
        let reach = BlobPath.reach(outline: outline, squash: squash)
        // Room for the outline at its widest, the pulse ring and the glow: nothing is cut by a frame.
        let needed = ceil((r * reach + 48) * 2 / 16) * 16
        if needed > side || needed < side - 64 { resize(to: needed) }
        container.position = center
        let mid = CGPoint(x: side / 2, y: side / 2)
        let outlinePath = BlobPath.make(outline: outline, center: mid, radius: r, squash: squash,
                                        squashAngle: squashAngle, rotation: rotation)
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        // The same squash and spin as `BlobPath`, for the layers drawn in the bubble's own space.
        let skin = CGAffineTransform(rotationAngle: squashAngle)
            .scaledBy(x: 1 + squash, y: 1 - squash)
            .rotated(by: -squashAngle + rotation)

        rim.path = outlinePath
        rim.lineWidth = max(1, r * 0.006)

        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -64, dy: -64))
        outside.addPath(outlinePath)

        updatePulse(pulse, outline: outline, mid: mid, r: r, squash: squash, squashAngle: squashAngle,
                    rotation: rotation, outlinePath: outlinePath, outside: outside, style: style)

        let inner = CGFloat(min(1, outline.min() ?? 1))
        darken.bounds = CGRect(x: 0, y: 0, width: 2 * r * inner, height: 2 * r * inner)
        darken.position = mid
        darken.setAffineTransform(skin)

        updateFilm(r: r, shape: shape, rotation: rotation, style: style)
        film.bounds = CGRect(x: 0, y: 0, width: 2 * r * filmExtent, height: 2 * r * filmExtent)
        film.position = mid
        film.setAffineTransform(skin)

        updateSystemGlass(style.systemGlass, center: center, outline: outline, r: r, squash: squash,
                          squashAngle: squashAngle, rotation: rotation)

        content.position = CGPoint(x: mid.x + sway, y: mid.y)
        let s = r / contentRadius
        // SwiftUI's positive tilt is clockwise; this layer space is y-up.
        content.setAffineTransform(CGAffineTransform(rotationAngle: -tilt * .pi / 180).scaledBy(x: s, y: s))
    }

    private func resize(to newSide: CGFloat) {
        side = newSide
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        container.bounds = bounds
        for layer in [glow, ring, rim, glowMask, ringMask] as [CALayer] { layer.frame = bounds }
    }

    /// A new film picture when the shape, tint or size changed, or — while animating — at most
    /// `filmInterval` after the last one; the old picture cross-fades into the new one.
    private func updateFilm(r: CGFloat, shape: FilmShape, rotation: Double, style: NodeStyle) {
        let input = SoapFilm.Input(radius: r, phase: shape.phase, time: shape.time, roundness: shape.roundness,
                                   tint: style.tint, rotation: rotation, colorSpace: style.colorSpace)
        let due: Bool
        if let last = filmInput {
            let changed = last.roundness != input.roundness || last.tint != input.tint || last.phase != input.phase
                || last.colorSpace?.name != input.colorSpace?.name
                || abs(last.radius - input.radius) > last.radius * 0.15
            let moved = last.time != input.time || abs(last.rotation - input.rotation) > 0.02
            due = changed || (moved && style.now - filmAt >= Self.filmInterval)
        } else {
            due = true
        }
        guard due, let picture = SoapFilm.render(input) else { return }
        let fading = filmInput != nil && style.animate
        filmInput = input
        filmAt = style.now
        filmExtent = picture.extent
        if fading {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.filmInterval
            film.add(fade, forKey: "film")
        }
        film.contents = picture.image
    }

    private func updatePulse(_ pulse: Pulse, outline: [Double], mid: CGPoint, r: CGFloat, squash: Double,
                             squashAngle: Double, rotation: Double, outlinePath: CGPath, outside: CGPath,
                             style: NodeStyle) {
        let hot = pulse == .hot
        glow.shadowOpacity = hot ? 0.75 : 0
        if hot {
            glow.shadowPath = outlinePath
            glowMask.path = outside
        }
        // A halo that leaves the outline and fades (CSS box-shadow spread, but blurred), off without animation.
        guard pulse != .none, style.animate else {
            ring.shadowOpacity = 0
            return
        }
        let period = hot ? 1.4 : 3.0
        let reach: CGFloat = hot ? 18 : 14
        let t = CGFloat(style.now.truncatingRemainder(dividingBy: period) / period)
        let eased = 1 - (1 - t) * (1 - t)
        ring.shadowPath = BlobPath.make(outline: outline, center: mid, radius: r, squash: squash,
                                        squashAngle: squashAngle, rotation: rotation,
                                        scale: 1 + reach * 0.5 * eased / r)
        ring.shadowRadius = 3 + reach * 0.6 * eased
        ring.shadowColor = hot ? CGColor(red: 1, green: 45 / 255, blue: 85 / 255, alpha: 1) : white(1)
        ring.shadowOpacity = Float((hot ? 0.8 : 0.55) * (1 - t))
        ringMask.path = outside
    }

    private func updateSystemGlass(_ on: Bool, center: CGPoint, outline: [Double], r: CGFloat, squash: Double,
                                   squashAngle: Double, rotation: Double) {
        guard on else {
            effect?.removeFromSuperview()
            effect = nil
            return
        }
        if effect == nil, let canvas {
            let view = BlobEffectView(frame: .zero)
            canvas.attach(view)
            effect = view
        }
        guard let effect else { return }
        let frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        if effect.frame != frame { effect.frame = frame }
        effect.setOutline(BlobPath.make(outline: outline, center: CGPoint(x: side / 2, y: side / 2), radius: r,
                                        squash: squash, squashAngle: squashAngle, rotation: rotation))
    }
}

private func white(_ alpha: Double) -> CGColor { CGColor(gray: 1, alpha: alpha) }

/// The full title of a hovered bubble: a dark pill with the title and the time.
struct BubbleTooltip: View {
    let task: DayTask

    var body: some View {
        // ImageRenderer proposes no size, so the text gets an explicit width and grows down from it;
        // otherwise the box was sized for two lines while the text ran past its top and bottom.
        VStack(alignment: .leading, spacing: 4) {
            Text(task.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(5)
                .truncationMode(.tail)
            if let due = task.dueText ?? task.note {
                Text(due)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.76))
            }
        }
        .frame(width: Self.textWidth(for: task.title), alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 20 / 255, green: 8 / 255, blue: 28 / 255).opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .padding(8)
    }

    /// Short titles get a snug box, long ones wrap at 280 pt.
    static func textWidth(for title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let natural = (title as NSString).size(withAttributes: [.font: font]).width
        return min(280, ceil(natural) + 2)
    }
}

/// Mouse gestures on the bubbles that the overlay windows do not route themselves (screen 5):
/// right click (or control-click) opens the bubble's menu; press and drag picks a bubble up, letting go
/// throws it; a click on "+N" opens "All tasks". A local event monitor sees the events before the
/// overlay's root view; a drag swallows its mouse-up so the card does not open.
@MainActor final class BubbleGestures {
    private weak var model: AppModel?
    private var monitor: Any?
    private var press: (id: UUID, start: CGPoint)?
    private var dragging = false

    /// Below this many points of travel a press is still a click.
    static let dragThreshold: CGFloat = 4

    init(model: AppModel) {
        self.model = model
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    /// True when the event is handled here and must not reach the window.
    private func handle(_ event: NSEvent) -> Bool {
        guard let model, let root = event.window?.contentView as? OverlayRootView else { return false }
        let point = root.convert(event.locationInWindow, from: nil)
        let hit: UUID? = {
            if case .bubble(let id)? = model.target(at: point, layer: root.deskLayer) { return id }
            return nil
        }()
        switch event.type {
        case .rightMouseDown:
            return showMenu(hit, event: event, in: root)
        case .leftMouseDown:
            press = nil
            dragging = false
            if event.modifierFlags.contains(.control) { return showMenu(hit, event: event, in: root) }
            guard let hit else { return false }
            press = (hit, point)
            return hit == AppModel.overflowTargetID
        case .leftMouseDragged:
            guard let press, press.id != AppModel.overflowTargetID else { return false }
            if !dragging, hypot(point.x - press.start.x, point.y - press.start.y) > Self.dragThreshold {
                dragging = true
                model.beginDrag(press.id, at: point, time: event.timestamp)
            }
            guard dragging else { return false }
            model.dragMoved(to: point, time: event.timestamp)
            return true
        case .leftMouseUp:
            guard let press else { return false }
            self.press = nil
            if press.id == AppModel.overflowTargetID {
                if hit == AppModel.overflowTargetID { model.openAllTasks() }
                return true
            }
            if dragging {
                dragging = false
                model.dragMoved(to: point, time: event.timestamp)
                model.endDrag()
                return true
            }
            return false
        default:
            return false
        }
    }

    private func showMenu(_ id: UUID?, event: NSEvent, in view: NSView) -> Bool {
        guard let model, let id, id != AppModel.overflowTargetID, let menu = model.bubbleMenu(for: id) else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return true
    }
}
