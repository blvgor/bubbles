import AppKit
import BubblesCore
import SwiftUI
import UniformTypeIdentifiers

/// Shared editor pieces (screens 4, 6, 7): the inline title field, urgency menu, the time picker, the row
/// with ⋮⋮ / ⋯ and its hints, and the "Deleted · Undo" bar. Everything is dark glass, white text
/// (palette and components — `GlassStyle.swift`).
/// `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode: views keep this wrapper.
typealias ViewState<Value> = State<Value>

// MARK: - Title field

/// A title that is edited in place: click (or a focus request) to type; Return or leaving the field saves,
/// Esc puts the old text back. Return with the cursor inside the text splits the task there (`onSplit`).
struct TitleField: NSViewRepresentable {
    let text: String
    var placeholder = "Task title"
    var fontSize: CGFloat = 15
    var weight: NSFont.Weight = .medium
    /// Wraps onto several lines (the card's big title).
    var multiline = false
    /// Bump to put the cursor into the field.
    var focusRequest = 0
    /// Clears after saving (the "add" field).
    var clearsOnCommit = false
    var onCommit: (String) -> Void
    var onSplit: ((String, Int) -> Void)? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> EditorTextField {
        let field = EditorTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.textColor = .white
        field.font = .systemFont(ofSize: fontSize, weight: weight)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.4), .font: NSFont.systemFont(ofSize: fontSize, weight: weight),
        ])
        if multiline {
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
        } else {
            field.usesSingleLineMode = true
            field.cell?.wraps = false
            field.cell?.isScrollable = true
            field.lineBreakMode = .byTruncatingTail
        }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.focused() }
        field.stringValue = text
        context.coordinator.original = text
        return field
    }

    func updateNSView(_ field: EditorTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
            coordinator.original = text
        }
        if multiline { field.preferredMaxLayoutWidth = field.bounds.width }
        if coordinator.lastFocusRequest != focusRequest {
            coordinator.lastFocusRequest = focusRequest
            field.focusAllowed = true
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EditorTextField, context: Context) -> CGSize? {
        guard multiline, let width = proposal.width, width.isFinite else { return nil }
        nsView.preferredMaxLayoutWidth = width
        let height = nsView.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(height ?? nsView.intrinsicContentSize.height))
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TitleField
        var original = ""
        var lastFocusRequest = 0
        private var cancelled = false
        private var editing = false

        init(_ parent: TitleField) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func focused() {
            guard !editing else { return }
            editing = true
            original = parent.text
            parent.onEditingChanged(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            editing = false
            if cancelled {
                cancelled = false
                field.stringValue = original
            } else if !parent.clearsOnCommit, field.stringValue != original {
                parent.onCommit(field.stringValue)   // the add field saves on Return only
            }
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                let range = textView.selectedRange()
                let length = (textView.string as NSString).length
                let text = textView.string
                if let onSplit = parent.onSplit, range.length == 0, range.location > 0, range.location < length {
                    cancelled = true   // the split saves both halves
                    control.window?.makeFirstResponder(nil)
                    onSplit(text, range.location)
                } else if parent.clearsOnCommit {
                    parent.onCommit(text)
                    textView.string = ""
                    (control as? NSTextField)?.stringValue = ""
                    original = ""
                } else {
                    control.window?.makeFirstResponder(nil)
                }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                cancelled = true
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

/// Reports when it takes keyboard focus (a click into it), before the first keystroke. It takes focus only
/// from a click or a focus request, so a window opening does not select a title instead of the main field.
final class EditorTextField: NSTextField {
    var onFocus: (() -> Void)?
    var focusAllowed = false

    override var acceptsFirstResponder: Bool {
        focusAllowed || currentEditor() != nil || NSApp.currentEvent?.type == .leftMouseDown
    }

    override func textDidEndEditing(_ notification: Notification) {
        focusAllowed = false
        super.textDidEndEditing(notification)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }
}

// MARK: - Urgency and time

/// Click on the pill: "Urgent / Important / Normal".
struct PriorityMenu: View {
    let priority: Priority
    let onChange: (Priority) -> Void

    var body: some View {
        Menu {
            ForEach([Priority.urgent, .important, .normal], id: \.self) { p in
                Button { onChange(p) } label: {
                    if p == priority { Label(p.label, systemImage: "checkmark") } else { Text(p.label) }
                }
            }
        } label: {
            PriorityPill(priority: priority)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Urgency")
        .accessibilityLabel("Urgency: \(priority.label)")
    }
}

/// The time as a chip. It toggles `expanded`; the parent shows `DuePicker` inline right under it, inside the
/// window — a popover from a borderless panel is cut by the window edge and covers the title.
struct DueButton: View {
    let task: DayTask
    @Binding var expanded: Bool
    var fontSize: CGFloat = 12

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() } } label: {
            HStack(spacing: Space.xxs) {
                Text(task.dueText ?? "time")
                    .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .opacity(0.7)
            }
            .foregroundStyle(task.dueText == nil ? EditorInk.faint : EditorInk.secondary)
            .fixedSize()
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
            .background(Capsule(style: .continuous).fill(Color.white.opacity(expanded ? 0.16 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Time")
        .accessibilityLabel(task.dueText.map { "Time: \($0)" } ?? "Set time")
    }
}

/// "No time · By HH:MM · At HH:MM", quick 12:00 · 15:00 · 18:00 · "End of day"; a time already passed
/// says so and offers "Move to tomorrow". Shown inline as a glass card of fixed width (`width`, nil —
/// the width it is given).
struct DuePicker: View {
    let task: DayTask
    var endOfDay: Int?
    var width: CGFloat? = 320
    var onSet: (Int?, DueKind?) -> Void
    var onTomorrow: (() -> Void)?
    var onClose: (() -> Void)? = nil

    private let minutesState: ViewState<Int?>
    private let kindState: ViewState<DueKind>

    init(task: DayTask, endOfDay: Int?, width: CGFloat? = 320, onSet: @escaping (Int?, DueKind?) -> Void,
         onTomorrow: (() -> Void)?, onClose: (() -> Void)? = nil) {
        self.task = task
        self.endOfDay = endOfDay
        self.width = width
        self.onSet = onSet
        self.onTomorrow = onTomorrow
        self.onClose = onClose
        minutesState = ViewState(initialValue: task.dueMinutes)
        kindState = ViewState(initialValue: task.dueKind ?? .deadline)
    }

    private var minutes: Int? {
        get { minutesState.wrappedValue }
        nonmutating set { minutesState.wrappedValue = newValue }
    }
    private var kind: DueKind {
        get { kindState.wrappedValue }
        nonmutating set { kindState.wrappedValue = newValue }
    }

    private enum Mode: Hashable { case none, deadline, at }

    private var mode: Mode { minutes == nil ? .none : (kind == .at ? .at : .deadline) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Segments(options: [(Mode.none, "No time"), (.deadline, "By"), (.at, "At")], selection: mode, small: true) { m in
                    switch m {
                    case .none: apply(nil, kind)
                    case .deadline: apply(minutes ?? defaultMinutes, .deadline)
                    case .at: apply(minutes ?? defaultMinutes, .at)
                    }
                }
                if minutes != nil {
                    DatePicker("", selection: Binding(get: { date(for: minutes ?? defaultMinutes) },
                                                      set: { apply(Ranker.minutesSinceMidnight($0), kind) }),
                               displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel("Time")
                }
            }

            HStack(spacing: Space.xxs) {
                ForEach([12 * 60, 15 * 60, 18 * 60], id: \.self) { m in
                    quick(DayTask.clock(m), selected: minutes == m) { apply(m, kind) }
                }
                quick("End of day", selected: minutes == (endOfDay ?? 20 * 60) && kind == .deadline) {
                    apply(endOfDay ?? 20 * 60, .deadline)
                }
                Spacer(minLength: 0)
                if let onClose {
                    Button("Done", action: onClose).buttonStyle(ChipButtonStyle())
                }
            }

            if let minutes, minutes < Ranker.minutesSinceMidnight(Date()) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("\(DayTask.clock(minutes)) has passed")
                        .font(GlassFont.calloutBold)
                        .foregroundStyle(EditorInk.warning)
                    HStack(spacing: Space.xxs) {
                        if let onTomorrow { smallButton("Move to tomorrow", onTomorrow) }
                        smallButton("Clear time") { apply(nil, kind) }
                    }
                }
            }
        }
        .frame(width: width.map { $0 - 2 * Space.m }, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .glassPopover()
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var defaultMinutes: Int {
        let now = Ranker.minutesSinceMidnight(Date())
        return min(23 * 60, (now / 60 + 1) * 60)
    }

    private func quick(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(ChipButtonStyle(selected: selected))
            .fixedSize()
    }

    private func apply(_ value: Int?, _ k: DueKind) {
        minutes = value
        kind = k
        onSet(value, value == nil ? nil : k)
    }

    private func date(for minutes: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes) * 60)
    }
}

// MARK: - Row

/// What one row shows.
struct TaskRowModel {
    let task: DayTask
    var number: Int?
    var pinned = false
    /// "on the desk": already launched (in "Got it").
    var onDesk = false
    /// Dimmed with a note: this row leaves the desk when the day is replaced.
    var leaving = false
    var duplicateOf: String?
    var pastDue = false
    var selected = false
    var sourceHighlighted = false
    var dropTarget = false
    var focusRequest = 0
}

/// What a row can do; nil actions are not offered.
struct TaskRowActions {
    var rename: (UUID, String) -> Void
    var splitAt: (UUID, String, Int) -> Void
    var split: (UUID) -> Void
    var mergeNext: ((UUID) -> Void)?
    var setPriority: (UUID, Priority) -> Void
    var setDue: (UUID, Int?, DueKind?) -> Void
    var setLong: (UUID, Bool) -> Void
    var remove: (UUID) -> Void
    var moveToTomorrow: ((UUID) -> Void)?
    var mergeDuplicate: ((UUID) -> Void)?
    var dismissDuplicate: ((UUID) -> Void)?
    var hover: (UUID?) -> Void = { _ in }
    var select: (UUID) -> Void = { _ in }
    var editingChanged: (Bool) -> Void = { _ in }
    var dragBegan: (UUID) -> Void = { _ in }
    var drop: (UUID) -> Void = { _ in }
    var dropHover: (UUID?) -> Void = { _ in }
    var endOfDay: Int?
}

/// ⋮⋮ · № · title · 📌 · note · urgency · time · ⋯, with the duplicate and past-time hints under it.
struct TaskEditorRow: View {
    let row: TaskRowModel
    let actions: TaskRowActions

    private let dueOpenState = ViewState<Bool>(initialValue: false)
    private var dueOpen: Bool {
        get { dueOpenState.wrappedValue }
        nonmutating set { dueOpenState.wrappedValue = newValue }
    }

    var body: some View {
        let task = row.task
        let id = task.id
        let invalid = task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EditorInk.faint)
                    .frame(width: 16, height: 24)
                    .contentShape(Rectangle())
                    .onDrag {
                        actions.dragBegan(id)
                        return NSItemProvider(object: id.uuidString as NSString)
                    }
                    .help("Drag to put the task where you want it")
                    .accessibilityLabel("Drag")
                if let number = row.number {
                    Text("\(number)")
                        .font(GlassFont.mono)
                        .foregroundStyle(EditorInk.tertiary)
                        .frame(minWidth: 16)
                }
                TitleField(text: task.title, focusRequest: row.focusRequest,
                           onCommit: { actions.rename(id, $0) },
                           onSplit: { text, offset in actions.splitAt(id, text, offset) },
                           onEditingChanged: { editing in
                               if editing { actions.select(id) }
                               actions.editingChanged(editing)
                           })
                    .frame(minWidth: 80, maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                        .fill(invalid ? EditorInk.danger.opacity(0.22) : Color.clear))
                    .accessibilityLabel("Task title")
                if row.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(EditorInk.tertiary)
                        .help("Placed by hand — the order isn't recalculated")
                        .accessibilityLabel("Pinned")
                }
                if let note = noteText {
                    Text(note)
                        .font(GlassFont.micro)
                        .foregroundStyle(EditorInk.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                PriorityMenu(priority: task.priority) { actions.setPriority(id, $0) }
                DueButton(task: task, expanded: dueOpenState.projectedValue)
                moreMenu
            }
            if dueOpen {
                DuePicker(task: task, endOfDay: actions.endOfDay, onSet: { actions.setDue(id, $0, $1) },
                          onTomorrow: actions.moveToTomorrow.map { move in { dueOpen = false; move(id) } },
                          onClose: { withAnimation(.easeOut(duration: 0.2)) { dueOpen = false } })
                    .padding(.leading, Space.l)
                    .padding(.vertical, Space.xxs)
            }
            if invalid {
                hint("Empty title — write what to do, or delete the row", color: EditorInk.danger)
            }
            if let original = row.duplicateOf {
                HStack(spacing: 8) {
                    hint("Looks like “\(original)” — merge?", color: EditorInk.warning)
                    if let merge = actions.mergeDuplicate { smallButton("Merge") { merge(id) } }
                    if let dismiss = actions.dismissDuplicate { smallButton("They're different") { dismiss(id) } }
                }
            }
            if row.pastDue, let due = task.dueMinutes {
                HStack(spacing: 8) {
                    hint("\(DayTask.clock(due)) has passed", color: EditorInk.warning)
                    if let move = actions.moveToTomorrow { smallButton("Move to tomorrow") { move(id) } }
                    smallButton("Clear time") { actions.setDue(id, nil, nil) }
                }
            }
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .fill(row.selected || row.sourceHighlighted ? EditorInk.rowSelected : EditorInk.rowFill))
        .overlay(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .strokeBorder(Color.white.opacity(row.selected ? 0.16 : 0), lineWidth: 1))
        .overlay(alignment: .top) {
            if row.dropTarget {
                Capsule().fill(EditorInk.mint).frame(height: 2).offset(y: -3)
            }
        }
        .opacity(row.leaving ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { actions.select(id) }
        .onHover { inside in actions.hover(inside ? id : nil) }
        .onDrop(of: [UTType.text], delegate: RowDropDelegate(id: id, actions: actions))
    }

    private var noteText: String? {
        if row.leaving { return "leaves the desk" }
        if row.onDesk { return row.task.kind == .long ? row.task.note : "on the desk" }
        return row.task.note
    }

    private var moreMenu: some View {
        let task = row.task
        let id = task.id
        return Menu {
            Button("Split") { actions.split(id) }
                .disabled(task.title.split(whereSeparator: \.isWhitespace).count < 2)
            if let merge = actions.mergeNext { Button("Merge with next") { merge(id) } }
            Button(task.kind == .long ? "Make a task of the day" : "Make long") { actions.setLong(id, task.kind != .long) }
            if let move = actions.moveToTomorrow { Button("Move to tomorrow") { move(id) } }
            Divider()
            Button("Delete  ⌘⌫", role: .destructive) { actions.remove(id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EditorInk.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    private func hint(_ text: String, color: Color) -> some View {
        Text(text)
            .font(GlassFont.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.leading, Space.l)
    }
}

/// Drop of a dragged row onto this one: it takes this row's place.
private struct RowDropDelegate: DropDelegate {
    let id: UUID
    let actions: TaskRowActions

    func dropEntered(info: DropInfo) { actions.dropHover(id) }
    func dropExited(info: DropInfo) { actions.dropHover(nil) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        actions.dropHover(nil)
        actions.drop(id)
        return true
    }
}

/// "Deleted · Undo" for 5 seconds after a row is removed.
struct UndoBar: View {
    let text: String
    let onRestore: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "trash")
                .font(GlassFont.caption)
                .foregroundStyle(EditorInk.tertiary)
            Text(text)
                .font(GlassFont.callout)
                .foregroundStyle(EditorInk.secondary)
                .lineLimit(1)
            Button("Undo", action: onRestore)
                .buttonStyle(PillButtonStyle(primary: true, small: true))
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs)
        .background(Capsule(style: .continuous).fill(Color.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(EditorInk.softStroke, lineWidth: 1))
        .transition(.opacity)
    }
}

/// A banner line: tone dot, text and up to two actions, on a tinted section.
struct EditorBanner: View {
    let text: String
    var tone: Color = EditorInk.warning
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(spacing: Space.s) {
            Circle().fill(tone).frame(width: 8, height: 8)
            Text(text)
                .font(GlassFont.callout)
                .foregroundStyle(EditorInk.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                smallButton(action.0, action.1)
            }
        }
        .glassSection(padding: Space.s, radius: Radius.field, tone: tone)
    }
}

/// Invisible buttons that only carry keyboard shortcuts (⌘Z, ⌘⌫, Return, Esc) for a panel.
struct ShortcutButton: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .disabled(!enabled)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
