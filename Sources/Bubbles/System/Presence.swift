import AppKit
import CoreAudio
import Intents

/// "Don't take over during screen sharing, full-screen calls and Focus".
/// macOS has no public «screen is being shared» or «in a call» signal, so this uses what is readable
/// without extra permissions:
/// - window geometry from `CGWindowListCopyWindowInfo` (owner, layer, bounds — no titles, so no
///   Screen Recording needed);
/// - whether the default microphone is running in any process (CoreAudio, no permission);
/// - Focus via `INFocusStatusCenter`, only once the bundle declares `NSFocusStatusUsageDescription`.
@MainActor final class Presence {
    static let shared = Presence()

    enum Reason: Equatable {
        case screenSharing, fullScreenCall, focus

        /// For the "Ladder" tab and the deferred-takeover toast.
        var text: String {
            switch self {
            case .screenSharing: "your screen is being shared"
            case .fullScreenCall: "you're in a full-screen call"
            case .focus: "Focus is on"
            }
        }
    }

    private var cached: (at: Date, reason: Reason?) = (.distantPast, nil)

    /// Why the ladder should wait right now, or nil. Re-read at most every 2 seconds.
    func reason(now: Date = Date()) -> Reason? {
        if now.timeIntervalSince(cached.at) < 2 { return cached.reason }
        let reason = detect()
        cached = (now, reason)
        return reason
    }

    private func detect() -> Reason? {
        let windows = Self.onScreenWindows()
        let micBusy = Self.microphoneInUse()
        if Self.sharingToolbarShown(windows, micBusy: micBusy) { return .screenSharing }
        if Self.fullScreenCall(windows, micBusy: micBusy) { return .fullScreenCall }
        if focusOn() { return .focus }
        return nil
    }

    // MARK: - Calls and sharing

    /// Apps whose floating windows (layer above normal) appear only in a meeting: the share toolbar,
    /// the meeting mini-window.
    private static let callApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager", "Cisco-Systems.Spark", "com.apple.FaceTime", "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.hnc.Discord", "com.skype.skype",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp",
    ]
    /// Browsers run web meetings; their floating windows count only while the microphone is on.
    private static let browsers: Set<String> = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    private struct WindowInfo {
        let bundleID: String?
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    private static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var bundles: [pid_t: String?] = [:]
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            if bundles[pid] == nil {
                bundles[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            }
            return WindowInfo(bundleID: bundles[pid] ?? nil, pid: pid, layer: layer, bounds: bounds)
        }
    }

    /// A floating window (above normal windows, below the menu bar) of a call app, or of a browser while
    /// the microphone is on: Zoom / Teams / Meet show one while sharing the screen.
    private static func sharingToolbarShown(_ windows: [WindowInfo], micBusy: Bool) -> Bool {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        return windows.contains { w in
            guard let id = w.bundleID, w.layer > 0, w.layer < statusLevel, w.bounds.width >= 40, w.bounds.height >= 20
            else { return false }
            return callApps.contains(id) || (micBusy && browsers.contains(id))
        }
    }

    /// The frontmost app fills a whole screen and is a call app — or any app while the microphone is on
    /// (a web call in a full-screen browser, a messenger call).
    private static func fullScreenCall(_ windows: [WindowInfo], micBusy: Bool) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let isCallApp = front.bundleIdentifier.map(callApps.contains) ?? false
        guard isCallApp || micBusy else { return false }
        // CG window bounds use a top-left origin on the primary display; sizes are what matter here.
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return windows.contains { w in
            w.pid == front.processIdentifier && w.layer == 0
                && screenSizes.contains { abs($0.width - w.bounds.width) < 1 && abs($0.height - w.bounds.height) < 1 }
        }
    }

    /// The default input device is running in some process (any app recording from the microphone).
    private static func microphoneInUse() -> Bool {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: - Focus

    private var focusAsked = false

    /// Focus is on. Needs `NSFocusStatusUsageDescription` in Info.plist (asking without it can crash) and
    /// the user's consent; until then Focus is treated as off.
    private func focusOn() -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil else { return false }
        let center = INFocusStatusCenter.default
        switch center.authorizationStatus {
        case .authorized:
            return center.focusStatus.isFocused ?? false
        case .notDetermined:
            if !focusAsked {
                focusAsked = true
                center.requestAuthorization { _ in }
            }
            return false
        default:
            return false
        }
    }
}
