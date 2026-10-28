import AppKit
import BubblesCore
import QuartzCore
import SwiftUI

/// The two transparent full-screen windows on the main screen:
/// - desk: right above the desktop icons and under every normal window (`desktopIconWindow + 1`),
///   holds the background bubbles, the "+N" bubble and the mic; ordered out while bubbles are hidden;
/// - float: `.floating`, holds the surfaced bubble and the toast.
/// Frames come from the main screen's display link (story 39): each one steps the physics, then moves the
/// bubble layers. Windows ignore the mouse unless the cursor is over something of theirs; that is
/// re-checked every frame from `NSEvent.mouseLocation`, so clicks elsewhere reach the desktop.
@MainActor final class OverlayWindows {
    private let model: AppModel
    private let desk: OverlayWindow
    private let float: OverlayWindow
    private let deskCanvas: BubbleCanvas
    private let floatCanvas: BubbleCanvas
    private let driver = FrameDriver()
    private var link: CADisplayLink?
    private var fallbackTimer: Timer?
    private var deskVisible = true

    init(model: AppModel) {
        self.model = model
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        desk = OverlayWindow(frame: frame,
                             level: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1))
        float = OverlayWindow(frame: frame, level: .floating)
        deskCanvas = BubbleCanvas(deskLayer: .desk, model: model)
        floatCanvas = BubbleCanvas(deskLayer: .float, model: model)
        desk.contentView = OverlayRootView(layer: .desk, model: model, canvas: deskCanvas, overlay: nil)
        float.contentView = OverlayRootView(layer: .float, model: model, canvas: floatCanvas,
                                            overlay: NSHostingView(rootView: BubbleScene(model: model)))
    }

    /// Starts the frame loop; `onFrame` gets the time to simulate (s) before the layers are drawn.
    func startFrames(_ onFrame: @escaping (Double) -> Void) {
        driver.onFrame = { [weak self] dt in
            onFrame(dt)
            self?.drawFrame()
        }
        attachDisplayLink()
    }

    func show() {
        if deskVisible { desk.orderFront(nil) }
        float.orderFront(nil)
    }

    func hide() {
        desk.orderOut(nil)
        float.orderOut(nil)
    }

    /// "Hide bubbles": the desk window (bubbles and the mic) goes away; the float window stays for toasts.
    func setDeskVisible(_ on: Bool) {
        guard on != deskVisible else { return }
        deskVisible = on
        if on { desk.orderFront(nil) } else { desk.orderOut(nil) }
    }

    /// Follows the main screen when displays change.
    func screenChanged() {
        guard let frame = NSScreen.main?.frame else { return }
        desk.setFrame(frame, display: true)
        float.setFrame(frame, display: true)
        attachDisplayLink()
    }

    private func drawFrame() {
        let now = CACurrentMediaTime()
        if deskVisible { deskCanvas.render(now: now) }
        floatCanvas.render(now: now)
        updateMousePassthrough()
    }

    private func attachDisplayLink() {
        link?.invalidate()
        fallbackTimer?.invalidate()
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: driver, selector: #selector(FrameDriver.step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [driver] _ in
                MainActor.assumeIsolated { driver.advance(to: CACurrentMediaTime()) }
            }
            RunLoop.main.add(timer, forMode: .common)
            fallbackTimer = timer
        }
    }

    /// Per frame: a window takes the mouse only while the cursor is over one of its bubbles, the mic or the toast.
    private func updateMousePassthrough() {
        // Mid-click the state stays as it was: bubbles move, and the mouse-up must reach the same window.
        if NSEvent.pressedMouseButtons != 0 { return }
        let screenPoint = NSEvent.mouseLocation
        let origin = desk.frame.origin
        let point = CGPoint(x: screenPoint.x - origin.x, y: screenPoint.y - origin.y)
        let deskTarget = deskVisible ? model.target(at: point, layer: .desk) : nil
        setIgnores(desk, deskTarget == nil)
        model.setMicHovered(deskTarget == .mic)

        var floatHit = model.target(at: point, layer: .float) != nil
        if !floatHit, model.toast != nil {
            // Toast frame is in the hosting view's top-left space.
            let flipped = CGPoint(x: point.x, y: float.frame.height - point.y)
            floatHit = model.toastFrame.insetBy(dx: -4, dy: -4).contains(flipped)
        }
        setIgnores(float, !floatHit)
    }

    private func setIgnores(_ window: NSWindow, _ ignores: Bool) {
        if window.ignoresMouseEvents != ignores { window.ignoresMouseEvents = ignores }
    }
}

/// Display-link target. Time to simulate is measured between the frames' target presentation times, so
/// positions match the moment the frame is on screen.
@MainActor final class FrameDriver: NSObject {
    var onFrame: ((Double) -> Void)?
    private var last: CFTimeInterval?

    @objc func step(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }

    func advance(to time: CFTimeInterval) {
        let dt = last.map { min(0.05, max(0, time - $0)) } ?? 1.0 / 60
        last = time
        onFrame?(dt)
    }
}

/// Borderless, transparent, shadowless, on every Space, not in the window cycle, never key.
final class OverlayWindow: NSWindow {
    init(frame: NSRect, level: NSWindow.Level) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The window's content: system-glass views (added by the canvas), the bubble canvas, and on the float
/// window the SwiftUI toast on top. Routes clicks on bubbles (circle hit test against the physics world)
/// and on the mic itself; everything else (toast buttons) goes to SwiftUI. Takes the first click without
/// activating the app.
final class OverlayRootView: NSView {
    let deskLayer: DeskLayer
    weak var model: AppModel?
    private var pressed: DeskTarget?

    init(layer: DeskLayer, model: AppModel, canvas: BubbleCanvas, overlay: NSView?) {
        deskLayer = layer
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        for view in [canvas, overlay].compactMap({ $0 }) {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Bubbles and the mic are handled here, above whatever SwiftUI or AppKit put under them.
        let local = convert(point, from: superview)
        if let model, model.target(at: local, layer: deskLayer) != nil { return self }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        if let target = target(for: event) {
            pressed = target
        } else {
            super.mouseDown(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed else { return super.mouseUp(with: event) }
        self.pressed = nil
        // A bubble may drift during the click; it still opens if it is still on the desk.
        switch pressed {
        case .bubble(let id) where model?.world.bodies.contains(where: { $0.id == id }) == true:
            model?.activate(pressed)
        case .mic where target(for: event) == .mic:
            model?.activate(pressed)
        default:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if pressed == nil { super.mouseDragged(with: event) }
    }

    /// World coordinates have a bottom-left origin, like this view.
    private func target(for event: NSEvent) -> DeskTarget? {
        model?.target(at: convert(event.locationInWindow, from: nil), layer: deskLayer)
    }
}
