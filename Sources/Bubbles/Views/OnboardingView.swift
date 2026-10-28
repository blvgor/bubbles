import AppKit
import BubblesCore
import Combine
import SwiftUI

/// First launch (screen 1 of the flow): four steps with progress dots — what this is, permissions with
/// real statuses, Claude / ChatGPT or no AI, how hard to push. Every step but the first can be skipped.
/// `onlyPermissions` shows step 2 alone: dictation opens it when a permission was revoked.
struct OnboardingView: View {
    enum Finish { case dictate, sample, closed }

    let model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var permissions: PermissionCenter
    var onlyPermissions = false
    let onFinish: (Finish) -> Void

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let stepState: State<Int>
    private var step: Int {
        get { stepState.wrappedValue }
        nonmutating set { stepState.wrappedValue = newValue }
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

    private static let steps = 4

    init(model: AppModel, store: SettingsStore, permissions: PermissionCenter, onlyPermissions: Bool = false,
         initialStep: Int = 0, onFinish: @escaping (Finish) -> Void) {
        self.model = model
        self.store = store
        self.permissions = permissions
        self.onlyPermissions = onlyPermissions
        self.onFinish = onFinish
        stepState = State(initialValue: min(max(initialStep, 0), Self.steps - 1))
    }
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @ObservedObject private var models = WhisperModelStore.shared
    private let handyInstalled = HandyApp.isInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            if !onlyPermissions { dots }
            Group {
                switch onlyPermissions ? 1 : step {
                case 0: intro
                case 1: permissionsStep
                case 2: aiStep
                default: ladderStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            buttons
        }
        .padding(Space.panel)
        .frame(width: 520)
        .glassPanel()
        .onReceive(ticker) { _ in if step == 1 || onlyPermissions { permissions.refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    // MARK: Steps

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.steps, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(index == step ? 1 : (index < step ? 0.6 : 0.24)))
                    .frame(width: index == step ? 24 : 8, height: 8)
            }
            Spacer(minLength: 0)
            Text("\(step + 1) of \(Self.steps)")
                .font(GlassFont.mono)
                .foregroundStyle(EditorInk.tertiary)
        }
        .animation(.easeOut(duration: 0.25), value: step)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingBubbles()
                .frame(maxWidth: .infinity)
                .frame(height: 168)
            heading("Bubbles", "The day's tasks live on your desktop and won't let go until they're done")
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            if onlyPermissions {
                heading("Dictation access is off",
                        usesSystemSpeech ? "Dictation doesn't work without the microphone and speech recognition. Allow them again or type instead"
                                         : "Dictation doesn't work without the microphone. Allow it again or type instead")
            } else {
                heading("Permissions", usesSystemSpeech
                        ? "The microphone and speech recognition are for dictation. Without them you can type your tasks"
                        : "The microphone is for dictation. The built-in Whisper recognizes speech on this Mac, offline")
            }
            if !onlyPermissions {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Recognition").font(GlassFont.calloutBold)
                        Spacer(minLength: 0)
                        SpeechEngineMenu(store: store, handyInstalled: handyInstalled)
                    }
                    if store.settings.speechEngine == .whisper, !modelReady {
                        WhisperModelRow(models: models)
                    }
                }
                .glassSection()
            }
            VStack(spacing: 8) {
                ForEach(PermissionCenter.Kind.allCases.filter { $0 != .speech || usesSystemSpeech }) { kind in
                    PermissionRow(kind: kind, status: permissions.status(kind)) { permissions.request(kind) }
                }
            }
        }
    }

    private var modelReady: Bool {
        if case .ready = models.state { true } else { false }
    }

    /// The macOS recognizer runs (chosen, or Whisper without its model): it needs "Speech Recognition" too.
    private var usesSystemSpeech: Bool {
        SpeechEngine.effective(selected: store.settings.speechEngine, handyInstalled: handyInstalled,
                               whisperReady: modelReady, openAIKey: storedKeys.contains(.openAI)) == .system
    }

    private var aiStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("Who parses your tasks", "Claude or ChatGPT understand natural speech without commas and split it into tasks")
            VStack(alignment: .leading, spacing: 12) {
                providerChoice
                if hasKey && keyDraft.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "key.fill")
                        Text("\(provider.label) key saved in the Keychain").font(.system(size: 13))
                        Spacer(minLength: 0)
                        Button(checking ? "Checking…" : "Check") { checkStoredKey() }
                            .buttonStyle(PillButtonStyle(small: true))
                            .disabled(checking)
                    }
                } else {
                    HStack(spacing: 8) {
                        SecureField(provider.keyPrompt, text: keyDraftState.projectedValue)
                            .font(GlassFont.callout.weight(.regular))
                            .glassField()
                            .onSubmit(checkDraft)
                        Button(checking ? "Checking…" : "Check", action: checkDraft)
                            .buttonStyle(PillButtonStyle(primary: true, small: true))
                            .disabled(checking || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                if let keyStatus {
                    Text(keyStatus.message(for: provider))
                        .font(.system(size: 12))
                        .foregroundStyle(keyStatus == .invalid ? Color(red: 1, green: 0.55, blue: 0.6)
                                                               : Color.white.opacity(keyStatus == .valid ? 0.9 : 0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Where to get a \(provider.label) key", destination: provider.consoleURL)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.76))
            }
            .glassSection()
            VStack(alignment: .leading, spacing: 4) {
                Text("Without AI").font(GlassFont.calloutBold)
                Text("Plain tracker: you type tasks, each line becomes a task as written, and you set urgency and time yourself. "
                     + "You can connect AI later in Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Claude / ChatGPT, side by side across the card.
    private var providerChoice: some View {
        Segments(options: ParserProvider.allCases.map { ($0, $0.label) }, selection: provider, onSelect: selectProvider)
    }

    private var ladderStep: some View {
        VStack(alignment: .leading, spacing: 24) {
            heading("How hard to push", "Right now the bubbles just live on the desk and never cover anything. Turn on surfacing and the takeover before a deadline here or later in Settings")
            VStack(spacing: 8) {
                ForEach(LadderPreset.allCases, id: \.self) { preset in
                    ChoiceCard(title: preset.label, detail: preset.detail,
                               selected: LadderPreset.matching(store.settings) == preset) {
                        preset.apply(to: &store.settings)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                SwitchRow(title: "Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                    .font(.system(size: 13, weight: .medium))
                if let loginError {
                    Text(loginError).font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.55, blue: 0.6))
                }
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 8) {
            if onlyPermissions {
                Spacer(minLength: 0)
                Button("Type instead") { onFinish(.dictate) }
                    .buttonStyle(PillButtonStyle())
                Button("Continue") { onFinish(.dictate) }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            } else {
                switch step {
                case 0:
                    Spacer(minLength: 0)
                    next("Next")
                case 1:
                    skip
                    Spacer(minLength: 0)
                    next("Next")
                case 2:
                    skip
                    Spacer(minLength: 0)
                    if !hasKey { Button("Without AI") { step = 3 }.buttonStyle(PillButtonStyle()) }
                    next("Next")
                default:
                    Button("See an example") { finish(.sample) }
                        .buttonStyle(PillButtonStyle())
                    Spacer(minLength: 0)
                    Button("Dictate your first day") { finish(.dictate) }
                        .buttonStyle(PillButtonStyle(primary: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var skip: some View {
        Button("Skip") { step += 1 }
            .buttonStyle(QuietButtonStyle())
    }

    private func next(_ title: String) -> some View {
        Button(title) { step += 1 }
            .buttonStyle(PillButtonStyle(primary: true))
            .keyboardShortcut(.defaultAction)
    }

    private func heading(_ title: String, _ text: String) -> some View {
        PanelHeading(title: title, text: text)
    }

    // MARK: Actions

    private func finish(_ how: Finish) {
        store.settings.launchAtLoginOffered = true
        onFinish(how)
    }

    private func selectProvider(_ choice: ParserProvider) {
        guard choice != provider else { return }
        store.settings.provider = choice
        keyDraft = ""
        keyStatus = nil
    }

    /// Valid, or the provider could not be reached: the key is kept; a wrong one is never stored.
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
            guard asked == provider else { return }
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
}

/// One permission: icon, name, what it is for, and its status or the button that fixes it.
struct PermissionRow: View {
    let kind: PermissionCenter.Kind
    let status: PermissionCenter.Status
    var dark = true
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.primary.opacity(0.1)))
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.system(size: 13, weight: .bold))
                Text(kind.purpose)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(dark ? Color(red: 0.47, green: 0.94, blue: 0.75) : Color.green)
            case .notAsked:
                button("Allow", primary: true)
            case .denied:
                button("Open System Settings", primary: false)
            }
        }
        .padding(dark ? 12 : 0)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(dark ? 0.06 : 0)))
    }

    @ViewBuilder private func button(_ title: String, primary: Bool) -> some View {
        if dark {
            Button(title, action: onRequest).buttonStyle(PillButtonStyle(primary: primary, small: true))
        } else if primary {
            Button(title, action: onRequest).buttonStyle(.borderedProminent).controlSize(.small)
        } else {
            Button(title, action: onRequest).controlSize(.small)
        }
    }
}

/// Step 1 illustration: three glass bubbles, gently bobbing.
private struct OnboardingBubbles: View {
    private struct Spec { let size: CGFloat; let x: CGFloat; let y: CGFloat; let tint: GlassTint; let phase: Double }
    private let specs = [
        Spec(size: 128, x: -64, y: 4, tint: .pink, phase: 0),
        Spec(size: 88, x: 72, y: -32, tint: .sky, phase: 1.7),
        Spec(size: 56, x: 88, y: 52, tint: .mint, phase: 3.1),
    ]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(specs.enumerated()), id: \.offset) { _, s in
                    glass(s)
                        .frame(width: s.size, height: s.size)
                        .offset(x: s.x, y: s.y + CGFloat(sin(t * 0.9 + s.phase)) * 6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func glass(_ s: Spec) -> some View {
        let c = s.tint.rgb
        return Circle()
            .fill(Color(red: c.r, green: c.g, blue: c.b).opacity(0.28))
            .overlay {
                Circle().fill(RadialGradient(colors: [Color.white.opacity(0.65), Color.white.opacity(0)],
                                             center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: s.size * 0.45))
            }
            .overlay { Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1) }
    }
}
