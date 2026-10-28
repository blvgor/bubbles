import AppKit
import SwiftUI

/// A centred key panel above normal windows that hosts one SwiftUI view at a time: the detail card,
/// and later the dictation / confirm flow. It activates the app so text fields get the keyboard.
@MainActor final class PanelWindow: NSObject, NSWindowDelegate {
    static let shared = PanelWindow()

    private var panel: KeyPanel?
    private var closesOnResign = false
    private var onDismiss: (() -> Void)?

    var isPresented: Bool { panel?.isVisible ?? false }

    /// Shows `view` centred on the main screen, replacing whatever the panel showed before.
    /// `closesOnResign`: clicking elsewhere closes it. `onDismiss` runs however it closes.
    func present<V: View>(_ view: V, closesOnResign: Bool = false, onDismiss: (() -> Void)? = nil) {
        let previous = self.onDismiss
        self.onDismiss = nil
        previous?()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        self.closesOnResign = closesOnResign
        self.onDismiss = onDismiss
        let host = FittingHostingView(rootView: AnyView(view))
        host.sizingOptions = [.intrinsicContentSize]
        host.onFittingSizeChange = { [weak self] in self?.fitToContent(centred: false) }
        panel.contentView = host
        fitToContent(centred: true)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Sizes the panel to its content, so nothing is cut when the content grows (the time picker opening,
    /// the burn confirmation, a longer title). The first fit centres it; later ones keep the top edge where it
    /// is and grow downwards, staying on the screen.
    private func fitToContent(centred: Bool) {
        guard let panel, let host = panel.contentView as? FittingHostingView<AnyView> else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = panel.frame
        if !centred, abs(frame.width - size.width) < 0.5, abs(frame.height - size.height) < 0.5 { return }
        if centred {
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        } else {
            let top = frame.maxY
            frame = NSRect(x: frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        }
        // Keep it on the screen: slide up when it would run past the bottom, down past the top.
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        panel.setFrame(frame, display: true)
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        let done = onDismiss
        onDismiss = nil
        done?()
    }

    func windowDidResignKey(_ notification: Notification) {
        if closesOnResign { dismiss() }
    }

    private func makePanel() -> KeyPanel {
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false   // would steal the hold gesture
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.dismiss() }
        return panel
    }
}

/// Borderless panels refuse key status by default; this one takes it and closes on Esc.
final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A hosting view that reports when its content's size changes, so the panel can follow it.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSizeChange: (() -> Void)?
    private var scheduled = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        guard onFittingSizeChange != nil, !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.onFittingSizeChange?()
        }
    }
}
