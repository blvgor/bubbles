import AppKit
import BubblesCore
import Foundation

/// Handy (github.com/cjpais/Handy), a separate open-source app that recognises speech locally and types the text into
/// the focused field while its key is held. Bubbles only looks for it, reads its push-to-talk key and opens it
/// on a click; it never controls Handy.
@MainActor enum HandyApp {
    static let bundleID = "com.pais.handy"
    static let projectURL = URL(string: "https://github.com/cjpais/Handy")!

    /// Handy's settings file; only `settings.bindings.transcribe.current_binding` is read from it.
    static var settingsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(bundleID)/settings_store.json")
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { appURL != nil }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// Handy's key as stored («fn», «option+space»); nil when the file is missing or unreadable.
    static func binding() -> String? {
        guard let data = try? Data(contentsOf: settingsFile) else { return nil }
        return HandyShortcut.binding(fromSettingsJSON: data)
    }

    /// The engine the dictation panel uses now.
    static func engine(for settings: BubbleSettings) -> SpeechEngine {
        SpeechEngine.effective(selected: settings.speechEngine, handyInstalled: settings.speechEngine == .handy && isInstalled)
    }

    /// "Open Handy" — only on the person's click. Bubbles stays frontmost so the text lands in its field.
    static func open() {
        guard let url = appURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }
}
