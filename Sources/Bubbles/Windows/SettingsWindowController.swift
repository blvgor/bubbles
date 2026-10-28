import AppKit
import BubblesCore
import SwiftUI

/// "Settings…": an ordinary titled window with four tabs. One instance; showing it again brings it forward.
@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    let recorder = HotkeyRecorder()

    var isShown: Bool { window?.isVisible ?? false }

    func show(model: AppModel, tab: SettingsTab = .ladder) {
        let window = self.window ?? makeWindow()
        self.window = window
        let view = SettingsWindowView(model: model, store: model.settingsStore, permissions: PermissionCenter.shared,
                                      recorder: recorder, initialTab: tab)
        window.contentView = GlassWindowBackground.wrap(NSHostingView(rootView: view))
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        recorder.cancel()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "Bubbles Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
        window.delegate = self
        return window
    }
}

/// Records a new global shortcut in "General": the current one is suspended while recording, so pressing it
/// records instead of starting dictation. Esc cancels.
@MainActor final class HotkeyRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published var message: String?

    private var monitor: Any?
    private var onRecord: ((GlobalHotkey) -> Void)?
    private var onCancel: (() -> Void)?

    func start(onRecord: @escaping (GlobalHotkey) -> Void, onCancel: @escaping () -> Void) {
        cancel()
        self.onRecord = onRecord
        self.onCancel = onCancel
        message = nil
        isRecording = true
        HotkeyCenter.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return nil
        }
    }

    func cancel() {
        guard isRecording else { return }
        stopMonitor()
        let done = onCancel
        onCancel = nil
        onRecord = nil
        done?()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            cancel()
            return
        }
        guard let hotkey = HotkeyCenter.hotkey(from: event) else { return }
        guard hotkey.isValid else {
            message = "Use ⌘, ⌥ or ⌃ together with a key"
            return
        }
        stopMonitor()
        let done = onRecord
        onRecord = nil
        onCancel = nil
        done?(hotkey)
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
