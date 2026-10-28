import AppKit
import AVFoundation
import Combine
import Speech

/// The two permissions the app uses, with their real statuses: onboarding step 2, the settings window,
/// and the «permission was revoked» check before dictation.
@MainActor final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    enum Kind: CaseIterable, Identifiable {
        case microphone, speech

        var id: Self { self }

        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .speech: "Speech Recognition"
            }
        }

        var purpose: String { "Needed for dictation" }

        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .speech: "waveform"
            }
        }

        /// System Settings → Privacy & Security, on this permission's pane.
        var settingsURL: URL {
            let anchor = switch self {
            case .microphone: "Privacy_Microphone"
            case .speech: "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
        }
    }

    enum Status: Equatable {
        case granted, denied, notAsked

        var label: String {
            switch self {
            case .granted: "Allowed"
            case .denied: "Denied"
            case .notAsked: "Not asked yet"
            }
        }
    }

    @Published private(set) var statuses: [Kind: Status] = [:]

    /// Both dictation permissions were granted the last time we looked (to notice a revocation).
    private static let dictationGrantedKey = "bubbles.permissions.dictationGranted"

    init() { refresh() }

    func refresh() {
        var next: [Kind: Status] = [:]
        for kind in Kind.allCases { next[kind] = Self.status(kind) }
        if next != statuses { statuses = next }
    }

    func status(_ kind: Kind) -> Status { statuses[kind] ?? Self.status(kind) }

    static func status(_ kind: Kind) -> Status {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    /// "Allow": the system prompt the first time, System Settings once it was answered «no».
    func request(_ kind: Kind) {
        guard status(kind) == .notAsked else {
            openSettings(kind)
            return
        }
        switch kind {
        case .microphone:
            Task {
                _ = await Self.askMicrophone()
                refresh()
            }
        case .speech:
            Task {
                _ = await Self.askSpeech()
                refresh()
            }
        }
    }

    func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// True once when dictation permissions that were granted before are now denied: dictation then opens
    /// onboarding step 2 instead. Also records the current state for next time.
    func dictationAccessWasRevoked() -> Bool {
        refresh()
        let mic = status(.microphone), speech = status(.speech)
        let grantedBefore = UserDefaults.standard.bool(forKey: Self.dictationGrantedKey)
        UserDefaults.standard.set(mic == .granted && speech == .granted, forKey: Self.dictationGrantedKey)
        return grantedBefore && (mic == .denied || speech == .denied)
    }

    nonisolated private static func askMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    nonisolated private static func askSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}
