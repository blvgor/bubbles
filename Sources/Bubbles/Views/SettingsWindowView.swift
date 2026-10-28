import AppKit
import BubblesCore
import Combine
import SwiftUI

enum SettingsTab: Hashable { case ladder, dictation, general }

/// The settings window (screen 11): rare settings in three tabs — "Ladder", "Dictation & AI",
/// "General". The dropdown keeps the frequent ones and the look of the bubbles.
struct SettingsWindowView: View {
    let model: AppModel   // not observed: it republishes often
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var recorder: HotkeyRecorder
    let initialTab: SettingsTab

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let tabState: State<SettingsTab>
    private var tab: SettingsTab {
        get { tabState.wrappedValue }
        nonmutating set { tabState.wrappedValue = newValue }
    }
    private let keyDraftState = State<String>(initialValue: "")
    private var keyDraft: String {
        get { keyDraftState.wrappedValue }
        nonmutating set { keyDraftState.wrappedValue = newValue }
    }
    private let keyStatusState = State<ClaudeKeyStatus?>(initialValue: nil)
    private var keyStatus: ClaudeKeyStatus? {
        get { keyStatusState.wrappedValue }
        nonmutating set { keyStatusState.wrappedValue = newValue }
    }
    private let checkingState = State<Bool>(initialValue: false)
    private var checking: Bool {
        get { checkingState.wrappedValue }
        nonmutating set { checkingState.wrappedValue = newValue }
    }
    /// Providers whose key is in the Keychain (refreshed; the values themselves are never read for display).
    private let storedKeysState = State<Set<ParserProvider>>(initialValue: APIKeyStore.storedProviders)
    private var storedKeys: Set<ParserProvider> {
        get { storedKeysState.wrappedValue }
        nonmutating set { storedKeysState.wrappedValue = newValue }
    }
    private var provider: ParserProvider { store.settings.provider }
    private var hasKey: Bool { storedKeys.contains(provider) }
    private let launchAtLoginState = State<Bool>(initialValue: LaunchAtLogin.isEnabled)
    private var launchAtLogin: Bool {
        get { launchAtLoginState.wrappedValue }
        nonmutating set { launchAtLoginState.wrappedValue = newValue }
    }
    private let loginErrorState = State<String?>(initialValue: nil)
    private var loginError: String? {
        get { loginErrorState.wrappedValue }
        nonmutating set { loginErrorState.wrappedValue = newValue }
    }
    private let presenceState = State<String?>(initialValue: nil)
    private var presence: String? {
        get { presenceState.wrappedValue }
        nonmutating set { presenceState.wrappedValue = newValue }
    }
    /// Handy: installed, running, its push-to-talk key (refreshed with the rest).
    private let handyState = State<HandyStatus>(initialValue: HandyStatus.current())
    private var handy: HandyStatus {
        get { handyState.wrappedValue }
        nonmutating set { handyState.wrappedValue = newValue }
    }
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// The built-in Whisper's model: there, or "Download model".
    @ObservedObject private var models = WhisperModelStore.shared

    init(model: AppModel, store: SettingsStore, permissions: PermissionCenter, recorder: HotkeyRecorder,
         initialTab: SettingsTab) {
        self.model = model
        self.store = store
        self.permissions = permissions
        self.recorder = recorder
        self.initialTab = initialTab
        tabState = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.block) {
                Text("Settings")
                    .font(GlassFont.display)
                    .tracking(GlassFont.displayTracking)
                tabBar
            }
            .padding(.horizontal, Space.panel)
            .padding(.top, 48)   // the panel padding plus the title bar
            .padding(.bottom, Space.block)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Space.xl) {
                    switch tab {
                    case .ladder: ladder
                    case .dictation: dictation
                    case .general: general
                    }
                }
                .font(GlassFont.callout)
                .padding(.horizontal, Space.panel)
                .padding(.bottom, Space.panel)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: 600, height: 680, alignment: .topLeading)
        .foregroundStyle(EditorInk.primary)
        .background(EditorInk.panelTint.opacity(0.62))
        .environment(\.colorScheme, .dark)
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// "Ladder · Dictation & AI · General" across the width.
    private var tabBar: some View {
        HStack(spacing: Space.xxs) {
            ForEach([(SettingsTab.ladder, "Ladder", "stairs"), (.dictation, "Dictation & AI", "mic"),
                     (.general, "General", "gearshape")], id: \.0) { item in
                let on = tab == item.0
                Button { tab = item.0 } label: {
                    HStack(spacing: Space.xs) {
                        Image(systemName: item.2).font(.system(size: 12, weight: .semibold))
                        Text(item.1).font(GlassFont.calloutBold).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.xs)
                    .foregroundStyle(on ? EditorInk.ink : EditorInk.primary)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(on ? 0.92 : 0.1)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.2), value: tab)
    }

    private func refresh() {
        permissions.refresh()
        storedKeys = APIKeyStore.storedProviders
        launchAtLogin = LaunchAtLogin.isEnabled
        presence = Presence.shared.reason()?.text
        let now = HandyStatus.current()
        if now != handy { handy = now }
        models.refresh()
    }

    // MARK: - Ladder

    @ViewBuilder private var ladder: some View {
        section("How hard to push", footer: LadderPreset.matching(store.settings)?.detail ?? "Custom values") {
            Segments(options: LadderPreset.allCases.map { ($0, $0.label) },
                     selection: LadderPreset.matching(store.settings)) { $0.apply(to: &store.settings) }
        }
        section("Steps") {
            labeled("Surface", store.settings.surfaceEveryMinutes.map { "every \($0) min" } ?? "off") {
                Segments(options: [(Int?.none, "off")] + BubbleSettings.surfaceChoices.map { (Optional($0), "\($0)") },
                         selection: store.settings.surfaceEveryMinutes, small: true) { store.settings.surfaceEveryMinutes = $0 }
            }
            labeled("Takeover before deadline", store.settings.takeoverBeforeMinutes.map { "\($0) min before" } ?? "off") {
                Segments(options: [(Int?.none, "off")] + BubbleSettings.takeoverChoices.map { (Optional($0), "\($0)") },
                         selection: store.settings.takeoverBeforeMinutes, small: true) { store.settings.takeoverBeforeMinutes = $0 }
            }
            labeled("End of day", store.settings.endOfDayMinutes.map { DayTask.clock($0) } ?? "off") {
                Segments(options: [(Int?.none, "off")] + BubbleSettings.endOfDayChoices.map { (Optional($0), "\($0 / 60)") },
                         selection: store.settings.endOfDayMinutes, small: true) { store.settings.endOfDayMinutes = $0 }
            }
        }
        section("Closing") {
            labeled("Hold the button", "\(Int(store.settings.holdSeconds)) s") {
                Slider(value: stepped($store.settings.holdSeconds, by: 1), in: BubbleSettings.holdRange)
                    .labelsHidden()
                    .tint(EditorInk.mint)
                caption("1 to 30 seconds — how long you hold the button on the card and in the takeover")
            }
            toggle(FleeModeText.title, caption: store.settings.fleeMode
                       ? FleeModeText.caption + ". No takeover while this mode is on"
                       : FleeModeText.caption,
                   isOn: Binding(get: { store.settings.fleeMode }, set: { store.settings.fleeMode = $0 }))
        }
        section("Takeover", footer: "You can move a task to tomorrow without losing your streak until its takeover starts. "
                    + "During the takeover you can only close it or burn it") {
            toggle("Don't take over during screen sharing, full-screen calls and Focus",
                   caption: presence.map { "Right now \($0) — the ladder is waiting" }
                       ?? "The takeover waits and comes right after",
                   isOn: Binding(get: { store.settings.pauseDuringCalls }, set: { store.settings.pauseDuringCalls = $0 }))
            toggle("\"15 more minutes\" in the takeover", caption: "Once per task, without burning it",
                   isOn: Binding(get: { store.settings.allowExtension }, set: { store.settings.allowExtension = $0 }))
        }
    }

    // MARK: - Dictation & AI

    @ViewBuilder private var dictation: some View {
        section("Who parses dictation", footer: whoParses) {
            Segments(options: ParserProvider.allCases.map { ($0, $0.label) }, selection: provider, onSelect: selectProvider)
        }
        VStack(alignment: .leading, spacing: Space.s) {
            groupTitle("\(provider.label) key")
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.xs) {
                    Image(systemName: hasKey ? "checkmark.seal.fill" : "key")
                        .foregroundStyle(hasKey ? EditorInk.mint : EditorInk.tertiary)
                    Text(hasKey ? "Key saved in the Keychain" : "Not connected")
                    Spacer(minLength: 0)
                    if hasKey {
                        Button(checking ? "Checking…" : "Check", action: checkStoredKey)
                            .buttonStyle(PillButtonStyle(small: true))
                            .disabled(checking)
                        Button("Delete") {
                            APIKeyStore.delete(provider)
                            storedKeys = APIKeyStore.storedProviders
                            keyStatus = nil
                        }
                        .buttonStyle(PillButtonStyle(small: true, destructive: true))
                    }
                }
                if !hasKey {
                    HStack(spacing: Space.xs) {
                        SecureField("\(provider.label) key", text: keyDraftState.projectedValue, prompt: Text(provider.keyPrompt))
                            .labelsHidden()
                            .glassField()
                            .onSubmit(checkDraft)
                        Button(checking ? "Checking…" : "Check", action: checkDraft)
                            .buttonStyle(PillButtonStyle(primary: true, small: true))
                            .disabled(checking || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let keyStatus {
                    Text(keyStatus.message(for: provider))
                        .font(GlassFont.caption)
                        .foregroundStyle(keyStatus == .invalid ? EditorInk.dangerSoft
                                                               : (keyStatus == .valid ? EditorInk.mint : EditorInk.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.xs) {
                    Text("Model")
                    Spacer(minLength: 0)
                    if store.settings.model(for: provider) != provider.defaultModel {
                        smallButton("Default") { modelBinding.wrappedValue = provider.defaultModel }
                    }
                    TextField("Model", text: modelBinding, prompt: Text(provider.defaultModel))
                        .labelsHidden()
                        .glassField()
                        .frame(width: 220)
                }
            }
            .glassSection()
            HStack(spacing: Space.xxs) {
                caption("The key is stored only in this Mac's Keychain.")
                Link("Where to get a key", destination: provider.consoleURL)
                    .font(GlassFont.caption.weight(.medium))
                    .foregroundStyle(EditorInk.secondary)
            }
        }
        section("Recognition", footer: engineFooter) {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    Text("Recognition")
                    Spacer(minLength: 0)
                    SpeechEngineMenu(store: store, handyInstalled: handy.installed)
                }
                if let engineFallback {
                    Text(engineFallback).font(GlassFont.caption).foregroundStyle(EditorInk.dangerSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !handy.installed {
                    // Handy is offered only once it is installed.
                    Link("Handy is a separate dictation app: get it here", destination: HandyApp.projectURL)
                        .font(GlassFont.caption.weight(.medium))
                        .foregroundStyle(EditorInk.secondary)
                }
            }
            if store.settings.speechEngine == .whisper || engine == .whisper || models.state != .ready(bundled: true) {
                WhisperModelRow(models: models)
            }
            if store.settings.speechEngine == .openAI {
                HStack(spacing: Space.xs) {
                    Text("Recognition model")
                    Spacer(minLength: 0)
                    if store.settings.transcriptionModel != OpenAITranscriber.defaultModel {
                        smallButton("Default") { store.settings.transcriptionModel = OpenAITranscriber.defaultModel }
                    }
                    TextField("Recognition model",
                              text: Binding(get: { store.settings.transcriptionModel },
                                            set: { store.settings.transcriptionModel = $0 }),
                              prompt: Text(OpenAITranscriber.defaultModel))
                        .labelsHidden()
                        .glassField()
                        .frame(width: 220)
                }
            }
            if engine == .handy {
                HStack(spacing: Space.xs) {
                    Text("Handy key")
                    Spacer(minLength: 0)
                    Text(handy.binding.map(HandyShortcut.display) ?? "not found")
                        .font(GlassFont.calloutBold)
                        .foregroundStyle(handy.binding == nil ? EditorInk.secondary : EditorInk.primary)
                    if !handy.running {
                        smallButton("Open Handy") { HandyApp.open() }
                    }
                }
                if let handyConflict { Text(handyConflict).font(GlassFont.caption).foregroundStyle(EditorInk.dangerSoft) }
            } else {
                HStack(spacing: Space.xs) {
                    Text("Recognition language")
                    Spacer(minLength: 0)
                    Text(engine == .system ? "Russian" : "Russian and English, automatic")
                        .foregroundStyle(EditorInk.secondary)
                }
            }
            HStack(spacing: Space.xs) {
                Text("Separator word")
                Spacer(minLength: 0)
                TextField("Separator word", text: Binding(get: { store.settings.separatorWord },
                                                             set: { store.settings.separatorWord = $0 }),
                          prompt: Text("next"))
                    .labelsHidden()
                    .glassField()
                    .frame(width: 220)
            }
            if engine != .handy {
                toggle("Show transcript", caption: "Lines appear as you speak, and you can fix them before parsing",
                       isOn: Binding(get: { store.settings.showTranscript }, set: { store.settings.showTranscript = $0 }))
            }
        }
        section("Permissions", plain: true) {
            PermissionRow(kind: .microphone, status: permissions.status(.microphone)) { permissions.request(.microphone) }
            // The built-in Whisper and the cloud need only the microphone.
            if engine == .system {
                PermissionRow(kind: .speech, status: permissions.status(.speech)) { permissions.request(.speech) }
            }
        }
    }

    // MARK: - General

    @ViewBuilder private var general: some View {
        section("Startup") {
            toggle("Open at login", caption: loginError, isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
        }
        section("Global shortcut",
                footer: "Starts and stops dictation from any app. Esc cancels recording the shortcut") {
            HStack(spacing: Space.xs) {
                Text("Dictate the day")
                Spacer(minLength: 0)
                Text(recorder.isRecording ? "Press a shortcut…" : (store.settings.hotkey?.display ?? "off"))
                    .font(GlassFont.calloutBold)
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xxs)
                    .background(Capsule().fill(Color.white.opacity(recorder.isRecording ? 0.2 : 0.08)))
                if recorder.isRecording {
                    smallButton("Cancel") { recorder.cancel() }
                } else {
                    smallButton("Change", recordHotkey)
                    if store.settings.hotkey != nil {
                        smallButton("Turn off") { _ = model.setHotkey(nil) }
                    } else {
                        smallButton("⌥Space") { recorder.message = model.setHotkey(.optionSpace) }
                    }
                }
            }
            if let message = recorder.message ?? model.hotkeyError ?? (engine == .handy ? handyConflict : nil) {
                Text(message).font(GlassFont.caption).foregroundStyle(EditorInk.dangerSoft)
            }
        }
        section("Intro") {
            HStack(spacing: Space.xs) {
                Text("Four steps: permissions, AI, how hard to push")
                    .foregroundStyle(EditorInk.secondary)
                Spacer(minLength: 0)
                Button("Show the intro") { model.showOnboarding() }
                    .buttonStyle(PillButtonStyle(small: true))
            }
        }
        section("Reset", footer: "Data means tasks, history, streak and settings. Claude and ChatGPT keys stay in the Keychain") {
            HStack(spacing: Space.xs) {
                Button("Reset settings") {
                    var fresh = BubbleSettings()
                    fresh.launchAtLoginOffered = store.settings.launchAtLoginOffered
                    fresh.hidden = store.settings.hidden
                    store.settings = fresh
                }
                .buttonStyle(PillButtonStyle(small: true))
                Spacer(minLength: 0)
                Button("Reset data…") { model.confirmResetAllData() }
                    .buttonStyle(PillButtonStyle(small: true, destructive: true))
            }
        }
    }

    // MARK: - Actions

    private func recordHotkey() {
        recorder.start(onRecord: { hotkey in
            recorder.message = model.setHotkey(hotkey)
        }, onCancel: {
            _ = model.setHotkey(store.settings.hotkey)   // put the old one back
        })
    }

    /// Which AI parses now, or that there is none (the plain tracker).
    private var whoParses: String {
        switch ParserProvider.active(selected: provider, hasKey: { storedKeys.contains($0) }) {
        case nil where ParserProvider.missingKey(selected: provider, hasKey: { storedKeys.contains($0) }) != nil:
            "No \(provider.label) key — plain tracker: lines are saved as written. "
                + "Your text isn't sent to the other provider, even if its key is saved"
        case nil:
            "No keys — plain tracker: you type tasks, and each line becomes a task as written"
        case let active?:
            "\(active.label) parses: natural speech without commas is split into tasks with time and urgency"
        }
    }

    /// The engine in use: Handy only while it is installed, the cloud only with a ChatGPT key, Whisper only
    /// with its model.
    private var engine: SpeechEngine {
        SpeechEngine.effective(selected: store.settings.speechEngine, handyInstalled: handy.installed,
                               whisperReady: modelReady, openAIKey: storedKeys.contains(.openAI))
    }

    private var modelReady: Bool {
        if case .ready = models.state { true } else { false }
    }

    /// The chosen engine cannot run right now: what runs instead.
    private var engineFallback: String? {
        let chosen = store.settings.speechEngine
        guard chosen != engine else { return nil }
        let instead = "\(engine == .whisper ? "the built-in Whisper" : "macOS") is used for now"
        switch chosen {
        case .openAI: return "No ChatGPT key — \(instead). Add the key above, under \"Who parses dictation\""
        case .whisper: return "No Whisper model — \(instead). Download it below"
        case .handy: return "Handy isn't installed — \(instead)"
        case .system: return nil
        }
    }

    private var engineFooter: String {
        switch engine {
        case .whisper:
            return "The built-in Whisper recognizes speech on this Mac, offline: Russian, English and mixed phrases. "
                + "A pause starts a new line. Only the microphone is needed"
        case .openAI:
            return "Phrases go to ChatGPT with your key and are billed at OpenAI's rates. "
                + "If the cloud doesn't answer, the built-in Whisper takes over"
        case .system:
            return "macOS uses the system recognizer for Russian speech. It needs the microphone and Speech Recognition"
        case .handy:
            return "The microphone opens a field: hold the Handy key and speak. Each phrase is a new line, \"Done\" parses them. "
                + "Handy recognizes on this Mac; Bubbles doesn't need microphone access"
        }
    }

    /// Our shortcut and Handy's are the same keys: one of the two apps would never get the press.
    private var handyConflict: String? {
        guard let binding = handy.binding, let hotkey = store.settings.hotkey,
              HandyShortcut.conflicts(binding, with: hotkey) else { return nil }
        return "The Bubbles shortcut \(hotkey.display) is the same as the Handy key — change one of them"
    }

    private var modelBinding: Binding<String> {
        Binding(get: { provider == .claude ? store.settings.claudeModel : store.settings.openAIModel },
                set: { value in
                    if provider == .claude { store.settings.claudeModel = value } else { store.settings.openAIModel = value }
                })
    }

    private func selectProvider(_ choice: ParserProvider) {
        guard choice != provider else { return }
        store.settings.provider = choice
        keyDraft = ""
        keyStatus = nil
    }

    private func checkDraft() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !checking else { return }
        let asked = provider
        checking = true
        keyStatus = nil
        Task { @MainActor in
            let status = await APIKeyStore.checkAndSave(key, for: asked)
            checking = false
            storedKeys = APIKeyStore.storedProviders
            guard asked == provider else { return }   // switched away meanwhile
            keyStatus = status
            if storedKeys.contains(asked) { keyDraft = "" }
        }
    }

    private func checkStoredKey() {
        let asked = provider
        checking = true
        keyStatus = nil
        Task { @MainActor in
            let status = await APIKeyStore.checkStored(asked)
            checking = false
            if asked == provider { keyStatus = status }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            try LaunchAtLogin.set(on)
            loginError = nil
        } catch {
            loginError = "macOS didn't allow it. Move the app to Applications and try again"
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    // MARK: - Pieces

    /// A titled group: small-caps heading, the rows on a glass section (or bare, for rows that are cards
    /// themselves), an optional footer caption.
    private func section<Content: View>(_ title: String, plain: Bool = false, footer: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            groupTitle(title)
            if plain {
                VStack(alignment: .leading, spacing: Space.xs) { content() }
            } else {
                VStack(alignment: .leading, spacing: Space.m) { content() }
                    .glassSection()
            }
            if let footer { caption(footer) }
        }
    }

    private func labeled<Content: View>(_ title: String, _ value: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 0)
                Text(value).font(GlassFont.mono).monospacedDigit().foregroundStyle(EditorInk.secondary)
            }
            content()
        }
    }

    private func toggle(_ title: String, caption text: String?, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let text { caption(text) }
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(EditorInk.mint.opacity(0.9))
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(GlassFont.caption)
            .foregroundStyle(EditorInk.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the settings show about Handy; compared so the 2-second refresh redraws only on a change.
struct HandyStatus: Equatable {
    var installed: Bool
    var running: Bool
    var binding: String?

    @MainActor static func current() -> HandyStatus {
        let installed = HandyApp.isInstalled
        return HandyStatus(installed: installed, running: installed && HandyApp.isRunning,
                           binding: installed ? HandyApp.binding() : nil)
    }
}
