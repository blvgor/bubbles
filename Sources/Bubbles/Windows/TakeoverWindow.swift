import AppKit
import BubblesCore
import SwiftUI

/// The last ladder step: one task covers the whole main screen, above everything including full-screen
/// apps (`.screenSaver` level, all Spaces, full-screen auxiliary). It activates the app so the proof field
/// takes the keyboard. It has no close button and ignores Esc: it leaves only through the proof + hold
/// (`onDone`), "15 more minutes" once per task (`onExtend`), or "Emergency exit" → "Burn and exit" (`onBurn`).
/// The ladder also lifts it when screen sharing or a full-screen call starts, and brings it back after.
@MainActor final class TakeoverWindow {
    static let shared = TakeoverWindow()

    private var window: TakeoverNSWindow?
    private(set) var taskID: UUID?

    var isPresented: Bool { taskID != nil }

    /// `deadline`: the moment the countdown reaches zero (nil — no countdown, e.g. "End of day" is off).
    /// `onExtend`: "15 more minutes", nil when not offered.
    func present(task: DayTask, deadline: Date?, onDone: @escaping (String) -> Void, onBurn: @escaping () -> Void,
                 onExtend: (() -> Void)? = nil) {
        let window = self.window ?? makeWindow()
        self.window = window
        taskID = task.id
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        window.setFrame(frame, display: false)

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        blur.autoresizingMask = [.width, .height]
        let host = NSHostingView(rootView: TakeoverView(task: task, deadline: deadline, onDone: onDone, onBurn: onBurn,
                                                          onExtend: onExtend))
        host.frame = blur.bounds
        host.autoresizingMask = [.width, .height]
        blur.addSubview(host)
        window.contentView = blur

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func dismiss() {
        taskID = nil
        guard let window else { return }
        window.orderOut(nil)
        window.contentView = nil
    }

    private func makeWindow() -> TakeoverNSWindow {
        let window = TakeoverNSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        return window
    }
}

/// Borderless windows refuse key status by default; this one takes it so the proof field gets typing,
/// and swallows Esc / ⌘W.
final class TakeoverNSWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) {}
    override func performClose(_ sender: Any?) {}
}
