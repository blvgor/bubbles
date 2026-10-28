import BubblesCore
import SwiftUI

/// Full-screen deadline takeover (prototype `#take`): huge title, countdown, proof phrase + the hold
/// ("Hold the button", 1…30 s),
/// "15 more minutes" (once per task, when `onExtend` is set), and the emergency exit that burns the task and
/// resets the streak.
struct TakeoverView: View {
    let task: DayTask
    let deadline: Date?
    let onDone: (String) -> Void
    let onBurn: () -> Void
    /// nil when the task already used its extension or extensions are off.
    var onExtend: (() -> Void)? = nil
    /// "Hold the button"; nil — from the settings.
    var holdSeconds: Double? = nil

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let proofState = State<String>(initialValue: "")
    private var proof: String {
        get { proofState.wrappedValue }
        nonmutating set { proofState.wrappedValue = newValue }
    }
    private let shakesState = State<Int>(initialValue: 0)
    private var shakes: Int {
        get { shakesState.wrappedValue }
        nonmutating set { shakesState.wrappedValue = newValue }
    }
    private let burnAskedState = State<Bool>(initialValue: false)
    private var burnAsked: Bool {
        get { burnAskedState.wrappedValue }
        nonmutating set { burnAskedState.wrappedValue = newValue }
    }
    private let appearedState = State<Bool>(initialValue: false)
    private var appeared: Bool {
        get { appearedState.wrappedValue }
        nonmutating set { appearedState.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool

    private static let alarm = Color(red: 1, green: 0x6B / 255, blue: 0x8A / 255)

    var body: some View {
        GeometryReader { geo in
            // By width and by height: a long title on a short screen must not push the proof row off it.
            let titleSize = min(160, max(52, min(geo.size.width * 0.11, geo.size.height * 0.12)))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = deadline.map { max(0, Int($0.timeIntervalSince(context.date).rounded(.up))) }
                VStack(alignment: .leading, spacing: 40) {
                    top(left: left)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 16) {
                            meta
                            Text(task.title)
                                .font(.system(size: titleSize, weight: .heavy))
                                .tracking(-0.045 * titleSize)
                                .lineLimit(4)
                                .minimumScaleFactor(0.4)
                        }
                        .rise(appeared, delay: 0)
                        Text(Self.countdown(left))
                            .font(.system(size: min(64, max(32, geo.size.width * 0.06)), weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .tracking(-1)
                            .rise(appeared, delay: 0.12)
                        proofRow
                            .rise(appeared, delay: 0.22)
                    }
                    Spacer(minLength: 0)
                    bottom
                }
                .foregroundStyle(EditorInk.primary)
                .frame(maxWidth: 1040, alignment: .leading)
                .padding(48)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(EditorInk.panelTint.opacity(0.58))
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)) { appeared = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                focused = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deadline: \(task.title)")
    }

    private func top(left: Int?) -> some View {
        HStack(spacing: Space.m) {
            Text(Self.eyebrow(left)).foregroundStyle(Self.alarm)
            Spacer(minLength: 0)
            Text("In the plan since \(DayTask.clock(Ranker.minutesSinceMidnight(task.createdAt)))")
                .foregroundStyle(EditorInk.secondary)
        }
        .font(GlassFont.mono)
        .tracking(1)
        .textCase(.uppercase)
    }

    private var meta: some View {
        HStack(spacing: Space.s) {
            PriorityPill(priority: task.priority)
            if let due = task.dueText { Text(due) }
            if let note = task.note { Text(note) }
        }
        .font(.system(size: 15, weight: .medium, design: .monospaced))
        .foregroundStyle(EditorInk.secondary)
    }

    private var proofRow: some View {
        HStack(alignment: .center, spacing: Space.s) {
            ProofField(text: proofState.projectedValue, shakes: shakes, fontSize: 17)
                .focused($focused)
                .frame(minWidth: 260)
            HoldToCompleteButton(proof: proofState.projectedValue,
                                 seconds: holdSeconds ?? AppModel.shared.settingsStore.settings.holdSeconds, onRejected: {
                shakes += 1
                focused = true
            }) {
                onDone(proof.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .frame(width: 280)
        }
        .frame(maxWidth: 760)
    }

    private var bottom: some View {
        HStack(spacing: Space.m) {
            Text("This screen won't close until the task is done")
                .font(GlassFont.callout.weight(.regular))
                .foregroundStyle(EditorInk.tertiary)
            Spacer(minLength: 0)
            if burnAsked {
                HStack(spacing: Space.xs) {
                    Text("The task will burn and your streak will reset")
                        .font(GlassFont.callout)
                        .foregroundStyle(EditorInk.secondary)
                    Button("Burn and exit", action: onBurn)
                        .buttonStyle(PillButtonStyle(small: true, destructive: true))
                    Button("Stay") { burnAsked = false }
                        .buttonStyle(PillButtonStyle(primary: true, small: true))
                }
            } else {
                HStack(spacing: Space.m) {
                    if let onExtend {
                        Button("15 more minutes", action: onExtend)
                            .buttonStyle(PillButtonStyle(small: true))
                            .help("Once per task: the screen comes back in 15 minutes")
                    }
                    Button("Emergency exit") { burnAsked = true }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
    }

    /// "N min to deadline" within the last hour, "Deadline today" before, "Deadline passed" after.
    static func eyebrow(_ secondsLeft: Int?) -> String {
        guard let s = secondsLeft else { return "Time to close the task" }
        if s <= 0 { return "Deadline passed" }
        if s < 3600 { return "\(Int((Double(s) / 60).rounded(.up))) min to deadline" }
        return "Deadline today"
    }

    /// «HH:MM:SS» left; «00:00:00» once past, or without a deadline.
    static func countdown(_ secondsLeft: Int?) -> String {
        let s = max(0, secondsLeft ?? 0)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private extension View {
    /// Prototype `@keyframes rise`: from 32 pt below and transparent.
    func rise(_ on: Bool, delay: Double) -> some View {
        opacity(on ? 1 : 0)
            .offset(y: on ? 0 : 32)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7).delay(delay), value: on)
    }
}
