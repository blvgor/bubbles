import BubblesCore
import SwiftUI

/// "Recognition" as a menu chip (settings and the first-launch permissions step): Built-in Whisper /
/// ChatGPT (cloud) / macOS / Handy — Handy only once it is installed.
struct SpeechEngineMenu: View {
    @ObservedObject var store: SettingsStore
    let handyInstalled: Bool

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { engine in
                Button {
                    store.settings.speechEngine = engine
                } label: {
                    if engine == selected { Label(engine.label, systemImage: "checkmark") } else { Text(engine.label) }
                }
            }
        } label: {
            HStack(spacing: Space.xxs) {
                Text(selected.label)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(ChipButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Recognition: \(selected.label)")
    }

    private var options: [SpeechEngine] { SpeechEngine.allCases.filter { $0 != .handy || handyInstalled } }

    /// The stored choice; Handy that is no longer installed shows as the default.
    private var selected: SpeechEngine {
        let stored = store.settings.speechEngine
        return stored == .handy && !handyInstalled ? .whisper : stored
    }
}

/// The built-in Whisper's model: in the app or downloaded; otherwise "Download model" with progress.
struct WhisperModelRow: View {
    @ObservedObject var models: WhisperModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Text("Whisper model")
                Spacer(minLength: 0)
                switch models.state {
                case .ready(let bundled):
                    Text(bundled ? "in the app" : "downloaded").foregroundStyle(EditorInk.secondary)
                case .missing:
                    smallButton("Download model · 574 MB") { models.download() }
                case .downloading(let progress):
                    Text("\(Int((progress * 100).rounded())) %")
                        .font(GlassFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(EditorInk.secondary)
                    smallButton("Cancel") { models.cancel() }
                case .verifying:
                    Text("Checking the file…").foregroundStyle(EditorInk.secondary)
                case .failed:
                    smallButton("Retry") { models.download() }
                }
            }
            if case .downloading(let progress) = models.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(EditorInk.mint)
            }
            if case .failed(let message) = models.state {
                Text(message).font(GlassFont.caption).foregroundStyle(EditorInk.dangerSoft)
            }
        }
    }
}
