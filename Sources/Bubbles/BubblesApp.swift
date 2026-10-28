import AppKit
import BubblesCore
import SwiftUI

/// Menu bar app: no Dock icon (`LSUIElement`), no main window — only the bubble icon in the menu bar.
@main
struct BubblesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared   // not observed here: it republishes every frame

    var body: some Scene {
        MenuBarExtra {
            SettingsMenuView(model: model, tasks: model.taskStore, store: model.settingsStore)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("Bubbles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist sets LSUIElement; this also keeps the Dock empty when the bare binary is run.
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }
}

/// The menu bar glyph from the prototype: a big bubble, a small one and a highlight, drawn as a template image.
enum MenuBarIcon {
    @MainActor static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            let big = NSBezierPath(ovalIn: NSRect(x: 8 - 6.2, y: 10 - 6.2, width: 12.4, height: 12.4))
            let small = NSBezierPath(ovalIn: NSRect(x: 15.5 - 3, y: 4.5 - 3, width: 6, height: 6))
            for path in [big, small] {
                path.lineWidth = 1.6
                path.stroke()
            }
            // Highlight arc inside the big bubble (prototype: M5.2 8.2 a3 3 0 0 1 2.2-1.8).
            let gloss = NSBezierPath()
            gloss.appendArc(withCenter: NSPoint(x: 8, y: 10), radius: 3.1, startAngle: 205, endAngle: 255)
            gloss.lineWidth = 1.6
            gloss.lineCapStyle = .round
            gloss.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
