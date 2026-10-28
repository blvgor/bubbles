import AppKit
import BubblesCore
import Combine
import SwiftUI

/// Selection, the "Deleted · Undo" bar and focus requests of the "All tasks" window.
@MainActor final class AllTasksState: ObservableObject {
    @Published var selectedID: UUID?
    @Published var hoveredID: UUID?
    @Published var editing = false
    @Published var removed: RemovedTask?
    @Published var dropTargetID: UUID?
    @Published var addFocusRequest = 0
    @Published var focusRequests: [UUID: Int] = [:]
    var draggingID: UUID?
    private var removedTask: Task<Void, Never>?

    func showRemoved(_ removed: RemovedTask) {
        self.removed = removed
        removedTask?.cancel()
        removedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.removed = nil
        }
    }

    func focus(_ id: UUID) {
        selectedID = id
        focusRequests[id, default: 0] += 1
    }
}

/// Screen 7: groups "Today · Long · Done today", the same row editor as "Got it",
/// an add field with a microphone on top, ⌘Z, ⌘⌫ and "Deleted · Undo".
struct AllTasksView: View {
    let model: AppModel   // not observed: it republishes often
    @ObservedObject var store: TaskStore
    @ObservedObject var editing: DeskEditing
    @ObservedObject var state: AllTasksState

    var body: some View {
        let now = Date()
        let ordered = editing.editor.list.ordered(now: now)
        let today = ordered.filter { $0.task.kind != .long }
        let long = ordered.filter { $0.task.kind == .long }
        let closed = store.history.filter { Calendar.current.isDateInToday($0.completedAt) }.reversed()
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Space.block) {
                PanelHeading(title: "All tasks",
                             text: MenuStatus.line(taskCount: store.tasks.count, done: store.doneToday, streak: store.streak))
                addRow
            }
            .padding(.horizontal, Space.panel)
            .padding(.top, 48)   // the panel padding plus the title bar
            .padding(.bottom, Space.block)

            if ordered.isEmpty && closed.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: Space.xl) {
                        if !today.isEmpty { group("Today", rows: today, ordered: ordered, now: now) }
                        if !long.isEmpty { group("Long", rows: long, ordered: ordered, now: now) }
                        if !closed.isEmpty {
                            VStack(alignment: .leading, spacing: Space.s) {
                                groupTitle("Done today")
                                VStack(alignment: .leading, spacing: Space.xxs) {
                                    ForEach(Array(closed.enumerated()), id: \.offset) { _, record in
                                        closedRow(record)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, Space.panel)
                    .padding(.bottom, Space.panel)
                }
            }
            if let removed = state.removed {
                UndoBar(text: "Deleted: “\(removed.item.task.title)”") {
                    model.restoreTask(removed)
                    state.removed = nil
                }
                .padding(Space.block)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(EditorInk.primary)
        .frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .topLeading)
        // Over the window's behind-window blur (`AllTasksWindow`): the same violet glass as the panels.
        .background(EditorInk.panelTint.opacity(0.62))
        .environment(\.colorScheme, .dark)
        .background {
            ZStack {
                ShortcutButton(key: "z", enabled: !state.editing && editing.editor.canUndo) { model.undoTaskEdit() }
                ShortcutButton(key: .delete, enabled: !state.editing && state.selectedID != nil) { removeSelected() }
                ShortcutButton(key: .return, modifiers: [], enabled: !state.editing && state.selectedID != nil) {
                    if let id = state.selectedID { state.focus(id) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: ordered.map(\.id))
    }

    // MARK: Pieces

    private var addRow: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EditorInk.tertiary)
                    .frame(width: 16)
                TitleField(text: "", placeholder: "Add a task — e.g. “send the invoice by 18”",
                           focusRequest: state.addFocusRequest, clearsOnCommit: true,
                           onCommit: { model.addTasks(text: $0) }, onEditingChanged: { state.editing = $0 })
                    .accessibilityLabel("Add task")
            }
            .glassField()
            micButton
        }
    }

    private var micButton: some View {
        Button { model.startDictation() } label: {
            Image(systemName: "mic")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .glassEffect(.regular.tint(Color.white.opacity(0.08)).interactive(), in: Circle())
                .overlay(Circle().strokeBorder(EditorInk.stroke, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Dictate — new tasks are added to today's")
        .accessibilityLabel("Dictate tasks")
    }

    private var emptyState: some View {
        VStack(spacing: Space.m) {
            Text("No tasks. Dictate your day")
                .font(GlassFont.title)
                .foregroundStyle(EditorInk.secondary)
            micButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func group(_ title: String, rows: [DraftTask], ordered: [DraftTask], now: Date) -> some View {
        let list = editing.editor.list
        let dupes = list.duplicates(now: now)
        let past = list.pastDue(now: now)
        let titles = Dictionary(ordered.map { ($0.id, $0.task.title) }, uniquingKeysWith: { a, _ in a })
        let numbers = Dictionary(ordered.enumerated().map { ($0.element.id, $0.offset + 1) }, uniquingKeysWith: { a, _ in a })
        return VStack(alignment: .leading, spacing: Space.s) {
            groupTitle(title)
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(rows) { row in
                    TaskEditorRow(row: TaskRowModel(
                        task: row.task, number: numbers[row.id], pinned: list.isPinned(row.id),
                        duplicateOf: dupes[row.id].flatMap { titles[$0] }, pastDue: past.contains(row.id),
                        selected: state.selectedID == row.id, dropTarget: state.dropTargetID == row.id,
                        focusRequest: state.focusRequests[row.id] ?? 0),
                                  actions: actions(ordered: ordered))
                }
            }
        }
    }

    private func closedRow(_ record: CompletionRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(EditorInk.mint)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(record.title)
                    .font(GlassFont.callout)
                    .strikethrough(true, color: EditorInk.tertiary)
                    .foregroundStyle(EditorInk.secondary)
                Text("«\(record.proof)»")
                    .font(GlassFont.caption)
                    .foregroundStyle(EditorInk.tertiary)
            }
            Spacer(minLength: 0)
            Text(DayTask.clock(Ranker.minutesSinceMidnight(record.completedAt)))
                .font(GlassFont.micro)
                .foregroundStyle(EditorInk.tertiary)
        }
        .padding(Space.xs)
    }

    private func actions(ordered: [DraftTask]) -> TaskRowActions {
        TaskRowActions(
            rename: { model.renameTask($0, $1) },
            splitAt: { id, text, offset in
                if let other = model.splitTask(id, text: text, at: offset) { state.focus(other) }
            },
            split: { model.splitTask($0) },
            mergeNext: { model.mergeTaskWithNext($0) },
            setPriority: { model.setTaskPriority($0, $1) },
            setDue: { model.setTaskDue($0, $1, $2) },
            setLong: { model.setTaskLong($0, $1) },
            remove: { remove($0) },
            moveToTomorrow: { model.moveToTomorrow($0) },
            mergeDuplicate: { model.mergeDuplicateTask($0) },
            dismissDuplicate: nil,
            hover: { state.hoveredID = $0 },
            select: { state.selectedID = $0 },
            editingChanged: { state.editing = $0 },
            dragBegan: { state.draggingID = $0 },
            drop: { target in
                defer { state.draggingID = nil }
                guard let dragged = state.draggingID, dragged != target,
                      let index = ordered.firstIndex(where: { $0.id == target }) else { return }
                model.moveTask(dragged, to: index)
            },
            dropHover: { state.dropTargetID = $0 },
            endOfDay: model.settingsStore.settings.endOfDayMinutes)
    }

    private func remove(_ id: UUID) {
        guard let removed = model.removeTask(id) else { return }
        if state.selectedID == id { state.selectedID = nil }
        state.showRemoved(removed)
    }

    private func removeSelected() {
        if let id = state.selectedID { remove(id) }
    }
}
