import BubblesCore
import SwiftUI

/// The card a bubble opens (screen 6). Top — editing: the title (click to edit), urgency, time, "2 of 12",
/// where the task came from. Bottom — closing: a proof phrase and the hold ("Hold the button", mouse or Space).
/// "More": put off, move to tomorrow (under the ladder's rule), burn with a confirmation; and the history.
struct DetailCard: View {
    let model: AppModel   // not observed: it republishes often
    @ObservedObject var store: TaskStore
    let id: UUID
    let onDone: (String) -> Void
    let onClose: () -> Void

    private let proofState = ViewState<String>(initialValue: "")
    private var proof: String {
        get { proofState.wrappedValue }
        nonmutating set { proofState.wrappedValue = newValue }
    }
    private let shakesState = ViewState<Int>(initialValue: 0)
    private var shakes: Int {
        get { shakesState.wrappedValue }
        nonmutating set { shakesState.wrappedValue = newValue }
    }
    private let burnAskedState = ViewState<Bool>(initialValue: false)
    private var burnAsked: Bool {
        get { burnAskedState.wrappedValue }
        nonmutating set { burnAskedState.wrappedValue = newValue }
    }
    private let editingState = ViewState<Bool>(initialValue: false)
    private var editingTitle: Bool {
        get { editingState.wrappedValue }
        nonmutating set { editingState.wrappedValue = newValue }
    }
    /// The time picker, open inline under the urgency / time row.
    private let dueOpenState: ViewState<Bool>
    private var dueOpen: Bool {
        get { dueOpenState.wrappedValue }
        nonmutating set { dueOpenState.wrappedValue = newValue }
    }
    @FocusState private var proofFocused: Bool
    /// "Hold the button" from the settings, read when the card draws.
    private var holdSeconds: Double { model.settingsStore.settings.holdSeconds }
    @FocusState private var holdFocused: Bool

    init(model: AppModel, store: TaskStore, id: UUID, onDone: @escaping (String) -> Void, onClose: @escaping () -> Void,
         dueOpen: Bool = false) {
        self.model = model
        self.store = store
        self.id = id
        self.onDone = onDone
        self.onClose = onClose
        dueOpenState = ViewState(initialValue: dueOpen)
    }

    var body: some View {
        Group {
            if let task = store.tasks.first(where: { $0.id == id }) {
                content(task)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func content(_ task: DayTask) -> some View {
        let ranked = model.rankedTasks
        let number = (ranked.firstIndex { $0.id == id } ?? 0) + 1
        let trail = model.trail(for: id)
        let canMove = model.canMoveToTomorrow(id)
        return VStack(alignment: .leading, spacing: Space.block) {
            // Header: editing
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(spacing: Space.xs) {
                    PriorityMenu(priority: task.priority) { model.setTaskPriority(id, $0) }
                    DueButton(task: task, expanded: dueOpenState.projectedValue)
                    if let note = task.note {
                        Text(note)
                            .font(GlassFont.mono)
                            .foregroundStyle(EditorInk.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(number) of \(ranked.count)")
                        .font(GlassFont.mono)
                        .foregroundStyle(EditorInk.secondary)
                }
                if dueOpen {
                    DuePicker(task: task, endOfDay: model.settingsStore.settings.endOfDayMinutes, width: nil,
                              onSet: { model.setTaskDue(id, $0, $1) },
                              onTomorrow: canMove ? { dueOpen = false; model.moveToTomorrow(id) } : nil,
                              onClose: { withAnimation(.easeOut(duration: 0.2)) { dueOpen = false } })
                }
                TitleField(text: task.title, fontSize: 28, weight: .heavy, multiline: true,
                           onCommit: { model.renameTask(id, $0) },
                           onEditingChanged: { editingTitle = $0 })
                    .accessibilityLabel("Task title")
                if let origin = trail.originLine {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(origin)
                            .font(GlassFont.micro)
                            .foregroundStyle(EditorInk.tertiary)
                        if let line = trail.sourceLine {
                            Text("«\(line)»")
                                .font(GlassFont.callout.weight(.regular))
                                .foregroundStyle(EditorInk.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Closing
            VStack(alignment: .leading, spacing: Space.s) {
                ProofField(text: proofState.projectedValue, shakes: shakes) { holdFocused = true }
                    .focused($proofFocused)
                HoldToCompleteButton(proof: proofState.projectedValue, seconds: holdSeconds, onRejected: {
                    shakes += 1
                    proofFocused = true
                }, focus: $holdFocused) {
                    onDone(proof.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                Text(holdFocused ? ProofHold.holdHint(seconds: holdSeconds) : "Return, then hold Space. Erase the sentence and the countdown restarts")
                    .font(GlassFont.caption)
                    .foregroundStyle(EditorInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // More
            VStack(alignment: .leading, spacing: Space.s) {
                if burnAsked {
                    HStack(spacing: Space.xs) {
                        Text("The task will burn and your streak will reset")
                            .font(GlassFont.calloutBold)
                            .foregroundStyle(EditorInk.dangerSoft)
                        Spacer(minLength: 0)
                        Button("Never mind") { burnAsked = false }
                            .buttonStyle(PillButtonStyle(small: true))
                        Button("Burn") { model.burnTask(id) }
                            .buttonStyle(PillButtonStyle(primary: true, small: true, destructive: true))
                    }
                } else {
                    HStack(spacing: Space.xs) {
                        Menu {
                            Button("For 15 minutes") { model.snooze(id, minutes: 15) }
                            Button("For 1 hour") { model.snooze(id, minutes: 60) }
                            Button("Until evening") { model.snoozeUntilEvening(id) }
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Text("Snooze")
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(0.7)
                            }
                            .font(GlassFont.captionBold)
                            .foregroundStyle(EditorInk.primary)
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, Space.xs)
                            .background(Capsule(style: .continuous).fill(EditorInk.controlFill))
                            .overlay(Capsule().strokeBorder(EditorInk.softStroke, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        Button("Move to tomorrow") { model.moveToTomorrow(id) }
                            .buttonStyle(PillButtonStyle(small: true))
                            .fixedSize()
                            .disabled(!canMove)
                            .help(canMove ? "Your streak is safe" : "The takeover has started — you can only close or burn it")
                        Button("Burn…") { burnAsked = true }
                            .buttonStyle(PillButtonStyle(small: true, destructive: true))
                            .fixedSize()
                        Spacer(minLength: 0)
                        Button("Close", action: onClose)
                            .buttonStyle(PillButtonStyle(small: true))
                            .fixedSize()
                    }
                }
                Text(trail.historyLine)
                    .font(GlassFont.caption)
                    .foregroundStyle(EditorInk.tertiary)
            }
        }
        .padding(Space.panel)
        .frame(width: 560)
        .glassPanel()
        .animation(.easeOut(duration: 0.2), value: dueOpen)
        .background(ShortcutButton(key: .escape, modifiers: [], enabled: !editingTitle, action: onClose))
        .onAppear { proofFocused = true }
    }
}
