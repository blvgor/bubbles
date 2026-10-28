import BubblesCore
import Foundation

/// Keeps the dictation lines safe while the panel is open: saved every 5 seconds (and when the panel closes)
/// to Application Support, read back the next time the microphone opens. Cleared once the day is launched.
@MainActor final class DictationLinesDraft {
    static let interval: TimeInterval = 5

    private let store: TranscriptDraftStore
    private let lines: () -> [String]
    private var timer: Timer?
    private var lastSaved: [String]?

    init(store: TranscriptDraftStore = TranscriptDraftStore(), lines: @escaping () -> [String]) {
        self.store = store
        self.lines = lines
    }

    func load() -> TranscriptDraft? { store.load() }

    func startAutosave() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    func saveNow() {
        let current = lines().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard current != lastSaved else { return }
        // An empty panel does not wipe a draft saved earlier (e.g. the restore was not taken up yet).
        guard !current.isEmpty else { return }
        store.save(current)
        lastSaved = current
    }

    func stopAutosave() {
        timer?.invalidate()
        timer = nil
        saveNow()
    }

    func clear() {
        timer?.invalidate()
        timer = nil
        store.clear()
        lastSaved = nil
    }
}
