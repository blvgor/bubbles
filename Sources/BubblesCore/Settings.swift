import Combine
import Foundation

/// A light tint for the bubble glass.
public enum GlassTint: String, Codable, CaseIterable, Sendable {
    case clear, pink, lilac, sky, mint, amber

    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .clear: (1, 1, 1)
        case .pink: (1, 0.47, 0.71)
        case .lilac: (0.63, 0.51, 1)
        case .sky: (0.47, 0.78, 1)
        case .mint: (0.47, 0.94, 0.75)
        case .amber: (1, 0.75, 0.35)
        }
    }

    public var label: String {
        switch self {
        case .clear: "Clear"
        case .pink: "Pink"
        case .lilac: "Lilac"
        case .sky: "Sky"
        case .mint: "Mint"
        case .amber: "Amber"
        }
    }
}

/// "Hide bubbles": visible, hidden until a moment (an hour / tomorrow 08:00), or until shown again.
public enum HiddenState: Codable, Equatable, Sendable {
    case visible, until(Date), forever
}

public struct BubbleSettings: Codable, Equatable, Sendable {
    /// "Shape" 0...100: 100 is a perfect circle, 0 is maximum wobble.
    public var roundness: Double = 70
    public var tint: GlassTint = .clear
    /// "Speed" 0...200 (%). Physics takes `speed / 100`.
    public var speed: Double = 100
    /// "Rotate and tilt text".
    public var rotation: Bool = true
    /// "Animation": off → bubbles sit on their anchors and the shape freezes.
    public var animation: Bool = true
    /// "Surface": nil = off; allowed 15 / 30 / 45 / 60 / 90. Off by default: the bubbles live on the desk
    /// until the person turns the ladder on.
    public var surfaceEveryMinutes: Int? = nil
    /// "Takeover before deadline": nil = off; allowed 5 / 15 / 30. Off by default, like the surfacing.
    public var takeoverBeforeMinutes: Int? = nil
    /// "End of day", minutes from midnight: nil = off; allowed 18:00…22:00 hourly.
    /// The implicit deadline for tasks without "by".
    public var endOfDayMinutes: Int? = 1200
    public var hidden: HiddenState = .visible
    /// The menu has already suggested "Open at login" once.
    public var launchAtLoginOffered: Bool = false
    /// "Microphone on the desk": the glass mic circle at the bottom of the desk.
    public var micOnDesk: Bool = true
    /// "Don't take over during screen sharing, full-screen calls and Focus": the ladder waits.
    public var pauseDuringCalls: Bool = true
    /// "15 more minutes" in the takeover, once per task.
    public var allowExtension: Bool = true
    /// Starts and stops dictation from any app; nil = off.
    public var hotkey: GlobalHotkey? = .optionSpace
    /// The word that starts a new task line while dictating.
    public var separatorWord: String = "next"
    /// Show the live transcript while dictating.
    public var showTranscript: Bool = true
    /// Who parses the dictation when both keys are stored (see `ParserProvider.active`).
    public var provider: ParserProvider = .claude
    /// Model fields; empty means the provider's default (`model(for:)`).
    public var claudeModel: String = ParserProvider.claude.defaultModel
    public var openAIModel: String = ParserProvider.openAI.defaultModel
    /// The one-time reset of the old 45 / 15 defaults to "Background only" has been looked at (see `SettingsStore`).
    /// True on a fresh install; a save from before the flag existed decodes as false.
    public var ladderDefaultsMigrated: Bool = true
    /// "Hold the button", seconds the hold-to-complete button needs (card, takeover, hints): 1…30, step 1.
    public var holdSeconds: Double = BubbleSettings.defaultHoldSeconds
    /// "Can't catch me": the bubbles flee from the cursor and ignore clicks, right clicks and drags;
    /// the ladder never takes the screen over. Only this switch turns it off.
    public var fleeMode: Bool = false
    /// "Recognition" (F6, F7): the built-in Whisper by default; a save that already says `system` stays so.
    /// What actually runs depends on what is available (`SpeechEngine.effective`).
    public var speechEngine: SpeechEngine = .whisper
    /// The ChatGPT transcription model for "ChatGPT (cloud)".
    public var transcriptionModel: String = OpenAITranscriber.defaultModel

    public static let surfaceChoices = [15, 30, 45, 60, 90]
    public static let takeoverChoices = [5, 15, 30]
    public static let endOfDayChoices = [18, 19, 20, 21, 22].map { $0 * 60 }
    public static let holdRange: ClosedRange<Double> = 1...30
    public static let defaultHoldSeconds: Double = 10

    public init() {}

    /// Bubbles answer clicks, right clicks and drags: they are on the desk and "Can't catch me" is off.
    /// The mic, "+N" and the menu are not affected.
    public var bubblesTakeInput: Bool { hidden == .visible && !fleeMode }

    /// Whole seconds within `holdRange`.
    public static func clampHold(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return defaultHoldSeconds }
        return min(holdRange.upperBound, max(holdRange.lowerBound, seconds.rounded()))
    }

    private enum CodingKeys: String, CodingKey {
        case roundness, tint, speed, rotation, animation, surfaceEveryMinutes, takeoverBeforeMinutes,
             endOfDayMinutes, hidden, launchAtLoginOffered, micOnDesk, pauseDuringCalls, allowExtension, hotkey,
             separatorWord, showTranscript, provider, claudeModel, openAIModel, ladderDefaultsMigrated,
             holdSeconds, fleeMode, speechEngine, transcriptionModel
    }

    // Missing keys take defaults (older saves keep working); an explicit null means "off".
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BubbleSettings()
        roundness = try c.decodeIfPresent(Double.self, forKey: .roundness) ?? d.roundness
        tint = try c.decodeIfPresent(GlassTint.self, forKey: .tint) ?? d.tint
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        rotation = try c.decodeIfPresent(Bool.self, forKey: .rotation) ?? d.rotation
        animation = try c.decodeIfPresent(Bool.self, forKey: .animation) ?? d.animation
        surfaceEveryMinutes = c.contains(.surfaceEveryMinutes)
            ? try c.decodeIfPresent(Int.self, forKey: .surfaceEveryMinutes) : d.surfaceEveryMinutes
        takeoverBeforeMinutes = c.contains(.takeoverBeforeMinutes)
            ? try c.decodeIfPresent(Int.self, forKey: .takeoverBeforeMinutes) : d.takeoverBeforeMinutes
        endOfDayMinutes = c.contains(.endOfDayMinutes)
            ? try c.decodeIfPresent(Int.self, forKey: .endOfDayMinutes) : d.endOfDayMinutes
        hidden = try c.decodeIfPresent(HiddenState.self, forKey: .hidden) ?? d.hidden
        launchAtLoginOffered = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginOffered) ?? d.launchAtLoginOffered
        micOnDesk = try c.decodeIfPresent(Bool.self, forKey: .micOnDesk) ?? d.micOnDesk
        pauseDuringCalls = try c.decodeIfPresent(Bool.self, forKey: .pauseDuringCalls) ?? d.pauseDuringCalls
        allowExtension = try c.decodeIfPresent(Bool.self, forKey: .allowExtension) ?? d.allowExtension
        hotkey = c.contains(.hotkey) ? try c.decodeIfPresent(GlobalHotkey.self, forKey: .hotkey) : d.hotkey
        separatorWord = try c.decodeIfPresent(String.self, forKey: .separatorWord) ?? d.separatorWord
        showTranscript = try c.decodeIfPresent(Bool.self, forKey: .showTranscript) ?? d.showTranscript
        provider = (try? c.decodeIfPresent(ParserProvider.self, forKey: .provider)) ?? d.provider
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? d.claudeModel
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        ladderDefaultsMigrated = try c.decodeIfPresent(Bool.self, forKey: .ladderDefaultsMigrated) ?? false
        holdSeconds = Self.clampHold((try? c.decodeIfPresent(Double.self, forKey: .holdSeconds)) ?? d.holdSeconds)
        fleeMode = try c.decodeIfPresent(Bool.self, forKey: .fleeMode) ?? d.fleeMode
        speechEngine = (try? c.decodeIfPresent(SpeechEngine.self, forKey: .speechEngine)) ?? d.speechEngine
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? d.transcriptionModel
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(roundness, forKey: .roundness)
        try c.encode(tint, forKey: .tint)
        try c.encode(speed, forKey: .speed)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(animation, forKey: .animation)
        try c.encode(surfaceEveryMinutes, forKey: .surfaceEveryMinutes)   // nil → null, not omitted
        try c.encode(takeoverBeforeMinutes, forKey: .takeoverBeforeMinutes)
        try c.encode(endOfDayMinutes, forKey: .endOfDayMinutes)
        try c.encode(hidden, forKey: .hidden)
        try c.encode(launchAtLoginOffered, forKey: .launchAtLoginOffered)
        try c.encode(micOnDesk, forKey: .micOnDesk)
        try c.encode(pauseDuringCalls, forKey: .pauseDuringCalls)
        try c.encode(allowExtension, forKey: .allowExtension)
        try c.encode(hotkey, forKey: .hotkey)   // nil → null ("off")
        try c.encode(separatorWord, forKey: .separatorWord)
        try c.encode(showTranscript, forKey: .showTranscript)
        try c.encode(provider, forKey: .provider)
        try c.encode(claudeModel, forKey: .claudeModel)
        try c.encode(openAIModel, forKey: .openAIModel)
        try c.encode(ladderDefaultsMigrated, forKey: .ladderDefaultsMigrated)
        try c.encode(holdSeconds, forKey: .holdSeconds)
        try c.encode(fleeMode, forKey: .fleeMode)
        try c.encode(speechEngine, forKey: .speechEngine)
        try c.encode(transcriptionModel, forKey: .transcriptionModel)
    }
}

/// Bubble settings persisted in `UserDefaults` under `bubbles.settings` (JSON).
@MainActor public final class SettingsStore: ObservableObject {
    public static let defaultsKey = "bubbles.settings"

    @Published public var settings: BubbleSettings {
        didSet { if settings != oldValue { save() } }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(BubbleSettings.self, from: data) {
            settings = stored
            migrateLadderDefaultsIfNeeded()
        } else {
            settings = BubbleSettings()
        }
    }

    /// F2, once: a save from before "Background only" became the default still holds the old 45 / 15 that nobody
    /// chose — turn both off. Any other pair was set by hand (the preset or a segment) and stays.
    private func migrateLadderDefaultsIfNeeded() {
        guard !settings.ladderDefaultsMigrated else { return }
        if settings.surfaceEveryMinutes == 45 && settings.takeoverBeforeMinutes == 15 {
            settings.surfaceEveryMinutes = nil
            settings.takeoverBeforeMinutes = nil
        }
        settings.ladderDefaultsMigrated = true
        save()
    }

    /// Lifts "Hidden until …" once that moment has passed.
    public func expireHiddenIfNeeded(now: Date = Date()) {
        if case .until(let date) = settings.hidden, now >= date {
            settings.hidden = .visible
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Ladder presets

/// Onboarding step 4 "How hard to push" and the "Ladder" tab.
public enum LadderPreset: CaseIterable, Sendable {
    case backgroundOnly, gentle, strict

    public var label: String {
        switch self {
        case .backgroundOnly: "Background only"
        case .gentle: "Gentle"
        case .strict: "Strict"
        }
    }

    public var detail: String {
        switch self {
        case .backgroundOnly: "Bubbles just live on the desk"
        case .gentle: "Surface every 45 min, takeover 15 min before"
        case .strict: "Surface every 30 min, takeover 30 min before"
        }
    }

    /// (surfaceEveryMinutes, takeoverBeforeMinutes).
    private var values: (surface: Int?, takeover: Int?) {
        switch self {
        case .backgroundOnly: (nil, nil)
        case .gentle: (45, 15)
        case .strict: (30, 30)
        }
    }

    public func apply(to settings: inout BubbleSettings) {
        settings.surfaceEveryMinutes = values.surface
        settings.takeoverBeforeMinutes = values.takeover
    }

    /// The preset the current ladder values equal, if any.
    public static func matching(_ settings: BubbleSettings) -> LadderPreset? {
        allCases.first { $0.values.surface == settings.surfaceEveryMinutes && $0.values.takeover == settings.takeoverBeforeMinutes }
    }
}

// MARK: - Global hotkey

/// A global shortcut as Carbon `RegisterEventHotKey` takes it.
public struct GlobalHotkey: Codable, Equatable, Sendable {
    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt32
    /// Carbon modifier mask: cmdKey 0x100, shiftKey 0x200, optionKey 0x800, controlKey 0x1000.
    public var modifiers: UInt32
    /// The key's printed name: «Space», «D», «F5».
    public var key: String

    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public static let optionSpace = GlobalHotkey(keyCode: 49, modifiers: option, key: "Space")

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// At least one of ⌘ ⌥ ⌃: a bare key or ⇧+key would swallow ordinary typing everywhere.
    public var isValid: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// «⌥Space», «⌃⌥⇧⌘D»: modifiers in the macOS menu order.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + key
    }
}

// MARK: - Claude key check

public enum ClaudeKeyStatus: Equatable, Sendable {
    case valid
    case invalid
    /// The key could not be checked right now; the text says why.
    case unavailable(String)

    public var message: String {
        switch self {
        case .valid: "The key works — Claude parses your tasks"
        case .invalid: "The key doesn't work. Check that you copied all of it"
        case .unavailable(let why): why
        }
    }
}

/// "Check": one free request (the models list) that needs a valid key.
public enum ClaudeKeyCheck {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
    public static let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
    public static let timeout: TimeInterval = 15

    public static func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    public static func status(httpCode: Int) -> ClaudeKeyStatus {
        switch httpCode {
        case 200..<300: .valid
        case 401, 403: .invalid
        case 429, 500...: .unavailable("Claude is overloaded right now — the key is saved, we'll check later")
        default: .unavailable("Claude returned error \(httpCode) — try again")
        }
    }

    /// Never throws and never echoes the key: network trouble becomes `.unavailable`.
    public static func verify(apiKey: String, session: URLSession = ClaudeHTTP.session) async -> ClaudeKeyStatus {
        do {
            let (_, response) = try await session.data(for: request(apiKey: apiKey))
            guard let http = response as? HTTPURLResponse else { return .unavailable("Claude didn't answer — try again") }
            return status(httpCode: http.statusCode)
        } catch let error as URLError where error.code == .timedOut {
            return .unavailable("Claude didn't answer within 15 seconds — try again")
        } catch {
            return .unavailable("No internet — we'll check the key once you're online")
        }
    }
}

// MARK: - Surface

/// The surfaced bubble's toast: "In 15 min" · "In 1 hour"; a click past the bubble and the toast
/// sends it back to the desk with the short snooze.
public enum SurfaceSnooze: Int, CaseIterable, Sendable {
    case quarter = 15
    case hour = 60

    public var minutes: Int { rawValue }
    public var label: String {
        switch self {
        case .quarter: "In 15 min"
        case .hour: "In 1 hour"
        }
    }
    public static var outsideClick: SurfaceSnooze { .quarter }
    public func until(_ now: Date) -> Date { now.addingTimeInterval(Double(minutes) * 60) }
}

// MARK: - Speech engine (F6, F7)

/// "Recognition": the built-in Whisper (on this Mac, no internet), ChatGPT in the cloud (the person's key),
/// the macOS recognizer, or Handy (a separate local dictation app that types the text into the focused field
/// while its key is held).
public enum SpeechEngine: String, Codable, CaseIterable, Sendable {
    case whisper, openAI, system, handy

    public var label: String {
        switch self {
        case .whisper: "Built-in Whisper"
        case .openAI: "ChatGPT (cloud)"
        case .system: "macOS"
        case .handy: "Handy"
        }
    }

    /// What runs for the chosen engine: Handy only while it is installed, the cloud only with a ChatGPT key,
    /// otherwise the built-in Whisper; without its model, the macOS recognizer.
    public static func effective(selected: SpeechEngine, handyInstalled: Bool, whisperReady: Bool = true,
                                 openAIKey: Bool = false) -> SpeechEngine {
        let local: SpeechEngine = whisperReady ? .whisper : .system
        switch selected {
        case .whisper: return local
        case .openAI: return openAIKey ? .openAI : local
        case .system: return .system
        case .handy: return handyInstalled ? .handy : local
        }
    }
}

/// Handy's push-to-talk key, as its `settings_store.json` stores it («fn», «option+space»).
public enum HandyShortcut {
    /// `settings.bindings.transcribe.current_binding`; nothing else in the file is read.
    /// A missing, broken or empty value gives nil.
    public static func binding(fromSettingsJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = root["settings"] as? [String: Any],
              let bindings = settings["bindings"] as? [String: Any],
              let transcribe = bindings["transcribe"] as? [String: Any],
              let binding = transcribe["current_binding"] as? String else { return nil }
        let trimmed = binding.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private enum Modifier: Int, CaseIterable { case fn, control, option, shift, command }

    private static func modifier(_ token: String) -> Modifier? {
        // «option_left», «leftalt» and the like name the same modifier.
        let base = token.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "left", with: "").replacingOccurrences(of: "right", with: "")
        switch base {
        case "fn", "function": return .fn
        case "ctrl", "control": return .control
        case "option", "alt", "opt": return .option
        case "shift": return .shift
        case "cmd", "command", "super", "meta", "win": return .command
        default: return nil
        }
    }

    /// (modifiers, key in lower case or nil).
    private static func parts(_ binding: String) -> (Set<Modifier>, String?) {
        var modifiers = Set<Modifier>()
        var key: String?
        for raw in binding.lowercased().split(separator: "+") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }
            if let m = modifier(token) { modifiers.insert(m) } else { key = token }
        }
        return (modifiers, key)
    }

    private static func keyName(_ key: String) -> String {
        switch key {
        case "space": "Space"
        case "escape", "esc": "Esc"
        case "enter", "return": "Return"
        case "tab": "Tab"
        default: key.count <= 3 ? key.uppercased() : key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    /// «fn», «⌥Space», «⌥⇧Space», «⌃D», «⇧⌘F5»: modifiers in the macOS menu order.
    public static func display(_ binding: String) -> String {
        let (modifiers, key) = parts(binding)
        var s = modifiers.contains(.fn) ? "fn" : ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        guard let key else { return s.isEmpty ? binding : s }
        return (modifiers == [.fn] ? "fn " : s) + keyName(key)
    }

    /// Our dictation shortcut is the same keys as Handy's: one of them would never get the press.
    public static func conflicts(_ binding: String, with hotkey: GlobalHotkey?) -> Bool {
        guard let hotkey else { return false }
        let (modifiers, key) = parts(binding)
        guard let key, !modifiers.contains(.fn) else { return false }
        var ours = Set<Modifier>()
        if hotkey.modifiers & GlobalHotkey.control != 0 { ours.insert(.control) }
        if hotkey.modifiers & GlobalHotkey.option != 0 { ours.insert(.option) }
        if hotkey.modifiers & GlobalHotkey.shift != 0 { ours.insert(.shift) }
        if hotkey.modifiers & GlobalHotkey.command != 0 { ours.insert(.command) }
        return ours == modifiers && hotkey.key.lowercased() == key
    }

    /// The hint in the dictation panel; without a readable key it stays generic.
    public static func hint(binding: String?) -> String {
        let key = binding.map(display) ?? "the Handy key"
        return "Hold \(key) and speak — Handy will type the text"
    }
}

/// «One insertion = one task»: a paste or a programmatic insertion longer than one character starts its own
/// line when the cursor's line already has text; typing letter by letter never breaks the line.
public enum InsertionLines {
    /// Pieces of one insertion that arrive this close together (a typed-in phrase comes in chunks) continue
    /// the same line.
    public static let burstWindow: TimeInterval = 0.5

    /// What to insert instead of `inserted` at `range` (UTF-16, as `NSTextView` counts) of `text`, or nil to
    /// insert it unchanged. `sincePreviousInsertion`: seconds since the previous multi-character insertion.
    public static func text(inserting inserted: String, into text: String, range: NSRange,
                            sincePreviousInsertion: TimeInterval? = nil) -> String? {
        guard inserted.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 else { return nil }
        if let since = sincePreviousInsertion, since >= 0, since < burstWindow { return nil }
        let ns = text as NSString
        let start = min(max(0, range.location), ns.length)
        let end = min(ns.length, start + max(0, range.length))
        let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let before = ns.substring(with: NSRange(location: lineStart, length: start - lineStart))
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: end, length: 0))
        let after = contentsEnd > end ? ns.substring(with: NSRange(location: end, length: contentsEnd - end)) : ""
        let breakBefore = !before.trimmingCharacters(in: .whitespaces).isEmpty
        let breakAfter = !after.trimmingCharacters(in: .whitespaces).isEmpty
        guard breakBefore || breakAfter else { return nil }
        var piece = inserted
        if breakBefore {
            piece = "\n" + String(piece.drop(while: { $0.isWhitespace }))
        }
        if breakAfter, !piece.hasSuffix("\n") { piece += "\n" }
        return piece
    }
}
