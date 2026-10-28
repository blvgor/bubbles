import AppKit
import BubblesCore
import SwiftUI

/// "All tasks" (screen 7): an ordinary window for calm editing. Opens from the menu (⌘L), "Add task…"
/// and the "+N" bubble. One instance; showing it again brings it forward.
@MainActor final class AllTasksWindow: NSObject, NSWindowDelegate {
    static let shared = AllTasksWindow()

    private var window: NSWindow?
    private let state = AllTasksState()

    var isShown: Bool { window?.isVisible ?? false }

    /// `focusAdd`: the cursor goes into "Add task".
    func show(model: AppModel, focusAdd: Bool = false) {
        let window = self.window ?? makeWindow()
        if self.window == nil {
            self.window = window
            let host = NSHostingView(rootView: AllTasksView(model: model, store: model.taskStore,
                                                            editing: model.editing, state: state))
            window.contentView = GlassWindowBackground.wrap(host)
            window.center()
        }
        model.refreshEditing()
        if focusAdd { state.addFocusRequest += 1 }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        state.selectedID = nil
        state.removed = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = "All tasks"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 560, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.delegate = self
        return window
    }
}

/// The frosted backdrop of the ordinary windows ("All tasks", "Settings"): the desktop shows through,
/// blurred; the SwiftUI content adds the violet tint the panels' glass has.
enum GlassWindowBackground {
    @MainActor static func wrap(_ content: NSView) -> NSView {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        content.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            content.topAnchor.constraint(equalTo: blur.topAnchor),
            content.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        return blur
    }
}
