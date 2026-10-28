import Foundation

/// Where Bubbles keeps its files: `~/Library/Application Support/Bubbles` (the state, the dictation draft, a
/// downloaded Whisper model). The `BUBBLES_DATA_DIR` environment variable points it elsewhere, so headless test runs
/// never touch the real data.
public enum DataFolder {
    public static let environmentKey = "BUBBLES_DATA_DIR"

    /// The folder for this process.
    public static var url: URL { resolve(environment: ProcessInfo.processInfo.environment) }

    /// `BUBBLES_DATA_DIR` when it is set and not blank (`~` expanded), else Application Support/Bubbles.
    public static func resolve(environment: [String: String]) -> URL {
        if let custom = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Bubbles", isDirectory: true)
    }
}
