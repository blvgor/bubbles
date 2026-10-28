import BubblesCore
import SwiftUI

/// "Hold for N seconds" (`BubbleSettings.holdSeconds`, 1…30): a glass capsule; press and hold to fill it with mint; letting go resets it. Without a proof phrase
/// of at least 3 characters it does not start, shows "First write what you did" and calls `onRejected`
/// (the caller shakes the field). The phrase is checked during the hold too: erasing it resets the count.
/// When focused, holding Space works like holding the mouse. Shared by the detail card and the takeover.
struct HoldToCompleteButton: View {
    @Binding var proof: String
    var seconds: Double = BubbleSettings.defaultHoldSeconds
    var onRejected: () -> Void = {}
    /// Moves keyboard focus here (Space hold), e.g. after Return in the proof field.
    var focus: FocusState<Bool>.Binding? = nil
    var onDone: () -> Void

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let startedAtState = State<Date?>(initialValue: nil)
    private var startedAt: Date? {
        get { startedAtState.wrappedValue }
        nonmutating set { startedAtState.wrappedValue = newValue }
    }
    private let elapsedState = State<Double>(initialValue: 0)
    private var elapsed: Double {
        get { elapsedState.wrappedValue }
        nonmutating set { elapsedState.wrappedValue = newValue }
    }
    private let rejectedState = State<Bool>(initialValue: false)
    private var rejected: Bool {
        get { rejectedState.wrappedValue }
        nonmutating set { rejectedState.wrappedValue = newValue }
    }
    private let finishedState = State<Bool>(initialValue: false)
    private var finished: Bool {
        get { finishedState.wrappedValue }
        nonmutating set { finishedState.wrappedValue = newValue }
    }
    private let loopState = State<Task<Void, Never>?>(initialValue: nil)
    private var loop: Task<Void, Never>? {
        get { loopState.wrappedValue }
        nonmutating set { loopState.wrappedValue = newValue }
    }

    var body: some View {
        let valid = ProofHold.isValid(proof)
        let progress = ProofHold.progress(elapsed: elapsed, seconds: seconds)
        let holding = startedAt != nil || finished
        let shape = Capsule(style: .continuous)
        ZStack {
            // Resting: glass capsule, label readable on its own; ready — a hint of mint.
            shape.fill(rejected ? EditorInk.danger.opacity(0.22) : EditorInk.mint.opacity(valid ? 0.16 : 0))
            // Progress: a mint fill growing from the leading edge.
            GeometryReader { geo in
                shape
                    .fill(LinearGradient(colors: [EditorInk.mint.opacity(0.85), EditorInk.mint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(progress > 0 ? geo.size.height : 0, geo.size.width * progress))
                    .opacity(progress > 0 ? 1 : 0)
            }
            // The label: white over glass, dark where the fill already reached — readable at every moment.
            GeometryReader { geo in
                ZStack {
                    labelText
                        .foregroundStyle(rejected ? EditorInk.dangerSoft : Color.white.opacity(valid || holding ? 1 : 0.7))
                        .frame(width: geo.size.width, height: geo.size.height)
                    labelText
                        .foregroundStyle(EditorInk.ink)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * progress)
                        }
                }
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(Color.white.opacity(0.1)).interactive(), in: shape)
        .overlay(Capsule().strokeBorder(Color.white.opacity(keyboardFocused ? 0.6 : (valid ? 0.28 : 0.16)), lineWidth: keyboardFocused ? 1.5 : 1))
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in begin() }
                .onEnded { _ in end() }
        )
        .animation(.easeOut(duration: 0.2), value: valid)
        .animation(.easeOut(duration: 0.2), value: rejected)
        .modifier(SpaceHold(focus: focus, onDown: begin, onUp: end))
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .onDisappear { loop?.cancel() }
    }

    private var labelText: some View {
        Text(label)
            .font(GlassFont.button)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, Space.m)
    }

    private var keyboardFocused: Bool { focus?.wrappedValue ?? false }

    private var label: String {
        if rejected { return ProofHold.rejectedLabel }
        if startedAt != nil || finished { return ProofHold.holdingLabel(elapsed: elapsed, seconds: seconds) }
        return ProofHold.idleLabel(seconds: seconds)
    }

    private func begin() {
        guard startedAt == nil, !finished else { return }
        guard ProofHold.isValid(proof) else { return reject() }
        rejected = false
        let start = Date()
        startedAt = start
        elapsed = 0
        loop?.cancel()
        loop = Task { @MainActor in
            while !Task.isCancelled {
                // The phrase is checked to the end: erased during the hold → the count starts over.
                guard ProofHold.isValid(proof) else {
                    end()
                    reject()
                    return
                }
                elapsed = Date().timeIntervalSince(start)
                if elapsed >= seconds {
                    finished = true
                    startedAt = nil
                    onDone()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func reject() {
        guard !rejected else { return }
        rejected = true
        onRejected()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            rejected = false
        }
    }

    private func end() {
        guard startedAt != nil else { return }
        loop?.cancel()
        loop = nil
        startedAt = nil
        withAnimation(.easeOut(duration: 0.2)) { elapsed = 0 }
    }
}

/// Space held on the focused button: down (and key repeat) starts or continues the hold, up lets go.
private struct SpaceHold: ViewModifier {
    let focus: FocusState<Bool>.Binding?
    let onDown: () -> Void
    let onUp: () -> Void

    func body(content: Content) -> some View {
        if let focus {
            content
                .focusable()
                .focusEffectDisabled()
                .focused(focus)
                .onKeyPress(keys: [.space], phases: [.down, .repeat, .up]) { press in
                    if press.phase == .up { onUp() } else { onDown() }
                    return .handled
                }
        } else {
            content
        }
    }
}

/// "What did you do? One sentence" field that shakes when `shakes` increments.
struct ProofField: View {
    @Binding var text: String
    var shakes: Int
    var fontSize: CGFloat = 15
    /// Return in the field (the card moves focus to the hold button).
    var onSubmit: () -> Void = {}

    var body: some View {
        TextField("", text: $text, prompt: Text("What did you do? One sentence").foregroundStyle(EditorInk.tertiary))
            .onSubmit(onSubmit)
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(EditorInk.primary)
            .glassField()
            .modifier(ShakeEffect(travel: CGFloat(shakes)))
            .animation(.linear(duration: 0.35), value: shakes)
    }
}

/// Prototype `@keyframes shake`: −8, +8, −4 pt, then rest.
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let t = travel - travel.rounded(.down)   // 0…1 within the current shake
        let decay = 8 * (1 - t)
        return ProjectionTransform(CGAffineTransform(translationX: -sin(t * .pi * 3) * decay, y: 0))
    }
}
