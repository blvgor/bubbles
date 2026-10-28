import AppKit
import BubblesCore
import SwiftUI

/// The dictation panel, hosted by `PanelWindow` (screens 2–4): "continue?", listening with the live lines,
/// "Edit transcript", text mode, parsing, and the "Got it" editor.
struct DictationFlowView: View {
    @ObservedObject var flow: DictationFlow
    let onCancel: () -> Void

    var body: some View {
        Group {
            switch flow.stage {
            case .resume: ResumeView(flow: flow, onCancel: cancel)
            case .listening: ListenView(flow: flow, speech: flow.speech, onCancel: cancel)
            case .review, .typing: TranscriptEditView(flow: flow, onCancel: cancel)
            case .parsing: ParsingView(flow: flow)
            case .confirm: ConfirmEditor(flow: flow, onCancel: cancel)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private func cancel() {
        if flow.confirmCancel() { onCancel() }
    }
}

// MARK: - "Unfinished dictation"

private struct ResumeView: View {
    @ObservedObject var flow: DictationFlow
    let onCancel: () -> Void

    var body: some View {
        let lines = flow.savedDraft?.lines ?? []
        VStack(alignment: .leading, spacing: Space.block) {
            PanelHeading(title: "Unfinished dictation from \(flow.savedDraftTime ?? "")",
                         text: "Continue it? \(lines.count) \(Plural.en(lines.count, "line")) already saved")
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(Array(lines.prefix(5).enumerated()), id: \.offset) { index, line in
                    TranscriptLine(number: index + 1, text: line, highlighted: false)
                }
                if lines.count > 5 {
                    Text("and \(lines.count - 5) more").font(GlassFont.caption).foregroundStyle(EditorInk.tertiary)
                        .padding(.leading, Space.xs)
                }
            }
            .glassSection(padding: Space.xs)
            HStack(spacing: Space.xs) {
                Button("Start over") { flow.discardSaved() }
                    .buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
                Button("Parse as is") { flow.reviewSaved() }
                    .buttonStyle(PillButtonStyle())
                Button("Continue") { flow.resumeSaved() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.panel)
        .frame(width: 640)
        .glassPanel()
        .background(ShortcutButton(key: .escape, modifiers: [], action: onCancel))
    }
}

// MARK: - Listening

private struct ListenView: View {
    @ObservedObject var flow: DictationFlow
    @ObservedObject var speech: SpeechRecognizer
    let onCancel: () -> Void

    var body: some View {
        let lines = flow.liveLines
        VStack(alignment: .leading, spacing: Space.block) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Circle()
                            .fill(flow.paused ? EditorInk.tertiary : EditorInk.danger)
                            .frame(width: 12, height: 12)
                        Text(flow.paused ? "Paused" : (speech.state == .requesting ? "Asking for permissions" : "Listening"))
                            .font(GlassFont.display)
                            .tracking(GlassFont.displayTracking)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(elapsed(at: context.date)) · pause = new task")
                            .font(GlassFont.mono)
                            .foregroundStyle(EditorInk.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Wave(level: speech.level, active: speech.state == .listening && !flow.paused)
            }
            if let interruption = speech.interruption {
                EditorBanner(text: interruption, actions: [
                    ("Continue", { flow.continueAfterInterruption() }),
                    ("Parse what's there", { flow.finish() }),
                ])
            }
            if flow.showTranscript {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            if lines.isEmpty {
                                Text("Speak — lines will appear here")
                                    .font(GlassFont.title.weight(.medium))
                                    .foregroundStyle(EditorInk.faint)
                                    .padding(Space.xs)
                            }
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                TranscriptLine(number: index + 1, text: line, highlighted: index == lines.count - 1, large: true)
                                    .id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 240)
                    .onChange(of: lines.count) { _, count in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .glassSection(padding: Space.xs)
            } else {
                Text(lines.isEmpty ? "Listening…" : "\(lines.count) \(Plural.en(lines.count, "line")) recorded")
                    .font(GlassFont.title.weight(.medium))
                    .foregroundStyle(EditorInk.secondary)
            }
            if !flow.hint.isEmpty {
                Text(flow.hint)
                    .font(GlassFont.callout.weight(.regular))
                    .foregroundStyle(EditorInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Space.xs) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
                Button(flow.paused ? "Continue" : "Pause") { flow.togglePause() }
                    .buttonStyle(PillButtonStyle())
                Button("Type instead") { flow.switchToText() }
                    .buttonStyle(PillButtonStyle())
                Button("Stop and review") { flow.finish() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.panel)
        .frame(width: 640)
        .glassPanel()
        .background(ShortcutButton(key: .escape, modifiers: [], action: onCancel))
    }

    private func elapsed(at date: Date) -> String {
        guard let start = speech.startedAt else { return "00:00" }
        let s = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// One numbered transcript line.
private struct TranscriptLine: View {
    let number: Int
    let text: String
    let highlighted: Bool
    var large = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("\(number)")
                .font(GlassFont.mono)
                .foregroundStyle(EditorInk.tertiary)
                .frame(width: 20, alignment: .trailing)
            Text(text)
                .font(large ? GlassFont.title.weight(.medium) : GlassFont.callout)
                .foregroundStyle(highlighted ? EditorInk.primary : EditorInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
        .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
            .fill(highlighted ? Color.white.opacity(0.12) : Color.clear))
    }
}

// MARK: - "Edit transcript" and text mode

private struct TranscriptEditView: View {
    @ObservedObject var flow: DictationFlow
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let review = flow.stage == .review
        let handy = flow.isHandy && !review
        let text = review ? $flow.reviewText : $flow.typed
        VStack(alignment: .leading, spacing: Space.block) {
            PanelHeading(title: review ? "Edit transcript" : (handy ? "Dictate with Handy" : "Type your tasks"),
                         text: flow.hint)
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(handy ? "Each phrase from Handy goes on a new line — one line, one task"
                         : flow.isPlain ? "For example:\nPay the internet bill\nTeam call\nBuy groceries"
                                        : "For example:\nurgent pay the internet bill by 4 pm\nteam call at 12\nbuy groceries")
                        .font(GlassFont.bodyMedium)
                        .foregroundStyle(EditorInk.faint)
                        .padding(Space.m)
                        .allowsHitTesting(false)
                }
                if handy {
                    // Handy types into the focused field: this one has the cursor as soon as the panel opens.
                    HandyTextView(text: text)
                        .padding(Space.m)
                } else {
                    TextEditor(text: text)
                        .font(GlassFont.bodyMedium)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.m)
                }
            }
            .frame(height: 240)
            .background(RoundedRectangle(cornerRadius: Radius.section, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: Radius.section, style: .continuous).strokeBorder(EditorInk.stroke, lineWidth: 1))
            HStack(spacing: Space.xs) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
                if handy {
                    if !flow.handyRunning {
                        Button("Open Handy") { flow.openHandy() }
                            .buttonStyle(PillButtonStyle())
                            .help("Handy isn't running — without it no text will appear")
                    }
                } else if flow.isPlain {
                    Button("Connect AI") { flow.openAISettings() }
                        .buttonStyle(PillButtonStyle())
                } else {
                    Button(review ? (flow.isHandy ? "Dictate more" : "Keep dictating") : "Dictate by voice") {
                        flow.continueDictating()
                    }
                    .buttonStyle(PillButtonStyle())
                }
                Button(handy ? "Done  ⌘↩" : (flow.isPlain ? "Next  ⌘↩" : "Parse  ⌘↩")) { flow.finish() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(Space.panel)
        .frame(width: 640)
        .glassPanel()
        .background(ShortcutButton(key: .escape, modifiers: [], action: onCancel))
        .onAppear { focused = true }
    }
}

// MARK: - Parsing

private struct ParsingView: View {
    @ObservedObject var flow: DictationFlow

    var body: some View {
        VStack(spacing: Space.block) {
            Orb(fast: true)
            Text(flow.hint)
                .font(GlassFont.title.weight(.medium))
                .multilineTextAlignment(.center)
            Button("Cancel") { flow.cancelParsing() }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(Space.panel)
        .frame(width: 640)
        .glassPanel()
    }
}

/// 112-pt glass circle with a microphone and two rings pulsing outwards (prototype `.orb`).
private struct Orb: View {
    let fast: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let period = fast ? 0.8 : 1.8
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<2, id: \.self) { i in
                    let phase = ((t + Double(i) * period / 2).truncatingRemainder(dividingBy: period)) / period
                    Circle()
                        .strokeBorder(Color.white.opacity(0.6), lineWidth: 2)
                        .scaleEffect(1 + 0.32 * phase)
                        .opacity(0.75 * (1 - phase))
                }
                Image(systemName: "mic")
                    .font(.system(size: 36, weight: .medium))
                    .frame(width: 112, height: 112)
                    .glassEffect(.clear, in: Circle())
                    .overlay {
                        Circle().fill(LinearGradient(colors: [Color.white.opacity(0.34), Color.white.opacity(0.08)],
                                                     startPoint: UnitPoint(x: 0.25, y: 0.07), endPoint: UnitPoint(x: 0.75, y: 0.93)))
                    }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1) }
            }
            .frame(width: 112, height: 112)
        }
        .accessibilityHidden(true)
    }
}

/// 24 bars driven by the microphone level (prototype `.wave`).
private struct Wave: View {
    let level: Float
    let active: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let amp = active ? Double(max(0.08, level)) : 0
            HStack(spacing: 4) {
                ForEach(0..<16, id: \.self) { i in
                    let wobble = abs(sin(t / 0.14 + Double(i) * 0.7))
                    let jitter = Double((i * 7919 + Int(t * 11)) % 13) / 13
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(active ? 1 : 0.4))
                        .frame(width: 4, height: 4 + 24 * amp * (0.4 * wobble + 0.6 * jitter))
                }
            }
            .frame(height: 32)
            .animation(.easeOut(duration: 0.09), value: context.date)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - "Got it"

private struct ConfirmEditor: View {
    @ObservedObject var flow: DictationFlow
    let onCancel: () -> Void

    private let tasksHeightState = ViewState<CGFloat>(initialValue: 320)
    private var tasksHeight: CGFloat {
        get { tasksHeightState.wrappedValue }
        nonmutating set { tasksHeightState.wrappedValue = newValue }
    }
    private let linesHeightState = ViewState<CGFloat>(initialValue: 200)
    private var linesHeight: CGFloat {
        get { linesHeightState.wrappedValue }
        nonmutating set { linesHeightState.wrappedValue = newValue }
    }

    private var maxBodyHeight: CGFloat { max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 360) }

    var body: some View {
        let draft = flow.draft
        let now = Date()
        let rows = draft.ordered(now: now)
        let canLaunch = draft.canLaunch(now: now)
        VStack(alignment: .leading, spacing: Space.block) {
            header(draft, now: now)
            banners(draft, now: now)
            HStack(alignment: .top, spacing: Space.block) {
                transcriptColumn(draft, rows: rows)
                    .frame(width: 280)
                ScrollView(.vertical) {
                    tasksColumn(draft, rows: rows, now: now)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tasksHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(max(tasksHeight, linesHeight), maxBodyHeight))
            }
            if let removed = flow.removed {
                UndoBar(text: "Deleted: “\(removed.item.task.title)”") { flow.restoreRemoved() }
            }
            HStack(spacing: Space.xs) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(PillButtonStyle())
                Button("Dictate more") { flow.dictateMore() }
                    .buttonStyle(PillButtonStyle())
                Spacer(minLength: 0)
                if !draft.emptyTitles.isEmpty {
                    Text("Fill in the empty titles")
                        .font(GlassFont.caption.weight(.medium))
                        .foregroundStyle(EditorInk.danger)
                }
                Button("Start the day  ⌘↩") { flow.launch() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canLaunch)
            }
        }
        .padding(Space.panel)
        .frame(width: 960)
        .glassPanel()
        .background {
            ZStack {
                ShortcutButton(key: "z", enabled: !flow.editing && draft.canUndo) { flow.undo() }
                ShortcutButton(key: .delete, enabled: !flow.editing && flow.selectedID != nil) { flow.removeSelected() }
                ShortcutButton(key: .return, modifiers: [], enabled: !flow.editing && flow.selectedID != nil) { flow.renameSelected() }
                ShortcutButton(key: .escape, modifiers: [], enabled: !flow.editing, action: onCancel)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: rows.map(\.id))
    }

    // MARK: Header and banners

    private func header(_ draft: DictationDraft, now: Date) -> some View {
        HStack(alignment: .top, spacing: Space.block) {
            PanelHeading(title: "Got it", text: draft.summary(now: now))
            Spacer(minLength: 0)
            if draft.dayInProgress {
                Segments(options: [(DraftMode.addToToday, "Add to today"), (.replaceDay, "Replace the day")],
                         selection: flow.draft.mode) { flow.setMode($0) }
                    .frame(width: 360)
                    .help("The day has started: new tasks are added to the ones on the desk, or replace them")
            }
        }
    }

    @ViewBuilder private func banners(_ draft: DictationDraft, now: Date) -> some View {
        // No key at all is the plain tracker by choice: no banner. A key that failed says why.
        let failure = flow.aiFailure
        let queue = draft.queueNote(now: now)
        if failure != nil || queue != nil {
            VStack(alignment: .leading, spacing: Space.xs) {
                if let failure {
                    EditorBanner(text: "\(failure.message(for: flow.askedProvider ?? .claude)). Set urgency and time yourself",
                                 actions: [(failure.actionLabel, { flow.runFailureAction() })])
                }
                if let queue {
                    EditorBanner(text: queue, tone: EditorInk.mint,
                                 actions: [("Make some long", { flow.makeTailLong() })])
                }
            }
        }
    }

    // MARK: Transcript

    private func transcriptColumn(_ draft: DictationDraft, rows: [DraftTask]) -> some View {
        let highlighted: Int? = {
            if let id = flow.hoveredID ?? flow.selectedID, let line = rows.first(where: { $0.id == id })?.sourceLine { return line }
            if let id = flow.hoveredLeftover { return draft.leftover.first { $0.id == id }?.sourceLine }
            return nil
        }()
        return VStack(alignment: .leading, spacing: Space.s) {
            groupTitle("Transcript")
                .padding(.horizontal, Space.xs)
            // All lines when they fit; a scroll view only when they do not.
            ViewThatFits(in: .vertical) {
                transcriptLines(draft, highlighted: highlighted)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) { transcriptLines(draft, highlighted: highlighted) }
                        .onChange(of: highlighted) { _, line in
                            if let line { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(line, anchor: .center) } }
                        }
                }
            }
            if !draft.lines.isEmpty {
                smallButton("Edit transcript") { flow.editTranscript() }
                    .padding(.horizontal, Space.xs)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSection(padding: Space.xs)
        // Exactly as tall as the tasks beside it: the lines show in full, a scroll view only when they do not fit.
        .frame(height: min(max(tasksHeight, linesHeight), maxBodyHeight), alignment: .top)
    }

    private func transcriptLines(_ draft: DictationDraft, highlighted: Int?) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if draft.lines.isEmpty {
                Text("Nothing here yet")
                    .font(GlassFont.callout)
                    .foregroundStyle(EditorInk.faint)
                    .padding(.horizontal, Space.xs)
            }
            ForEach(Array(draft.lines.enumerated()), id: \.offset) { index, line in
                TranscriptLine(number: index + 1, text: line, highlighted: index == highlighted)
                    .id(index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { linesHeight = $0 + 88 }
    }

    // MARK: Tasks

    private func tasksColumn(_ draft: DictationDraft, rows: [DraftTask], now: Date) -> some View {
        let dupes = draft.duplicates(now: now)
        let past = draft.pastDue(now: now)
        let titles = Dictionary(rows.map { ($0.id, $0.task.title) }, uniquingKeysWith: { a, _ in a })
        let actions = rowActions
        return VStack(alignment: .leading, spacing: Space.block) {
            if rows.isEmpty {
                EditorBanner(text: "No tasks found — split the lines or add tasks by hand", actions: [
                    ("Edit transcript", { flow.editTranscript() }),
                    ("Add task", { flow.addFocusRequest += 1 }),
                ])
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    TaskEditorRow(row: TaskRowModel(
                        task: row.task, number: index + 1, pinned: draft.isPinned(row.id), onDesk: row.onDesk,
                        leaving: draft.mode == .replaceDay && row.onDesk,
                        duplicateOf: dupes[row.id].flatMap { titles[$0] }, pastDue: past.contains(row.id),
                        selected: flow.selectedID == row.id, dropTarget: flow.dropTargetID == row.id,
                        focusRequest: flow.focusRequests[row.id] ?? 0), actions: actions)
                }
                addRow
            }
            if !draft.leftover.isEmpty { leftoverBlock(draft) }
            if !draft.carry.isEmpty { carryBlock(draft) }
            if !draft.tomorrow.isEmpty {
                Text("Tomorrow: " + draft.tomorrow.map(\.title).joined(separator: " · "))
                    .font(GlassFont.caption)
                    .foregroundStyle(EditorInk.tertiary)
            }
        }
        .padding(.trailing, Space.xs)
    }

    private var rowActions: TaskRowActions {
        TaskRowActions(
            rename: { flow.rename($0, $1) },
            splitAt: { flow.splitAt($0, text: $1, offset: $2) },
            split: { flow.split($0) },
            mergeNext: { flow.mergeNext($0) },
            setPriority: { flow.setPriority($0, $1) },
            setDue: { flow.setDue($0, $1, $2) },
            setLong: { flow.setLong($0, $1) },
            remove: { flow.remove($0) },
            moveToTomorrow: { flow.moveToTomorrow($0) },
            mergeDuplicate: { flow.mergeDuplicate($0) },
            dismissDuplicate: { flow.dismissDuplicate($0) },
            hover: { flow.hoveredID = $0 },
            select: { flow.selectedID = $0 },
            editingChanged: { flow.setEditing($0) },
            dragBegan: { flow.dragBegan($0) },
            drop: { flow.drop(on: $0) },
            dropHover: { flow.dropTargetID = $0 },
            endOfDay: flow.settings().endOfDayMinutes)
    }

    private var addRow: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(EditorInk.tertiary)
                .frame(width: 16)
            TitleField(text: "", placeholder: "Add a task — e.g. “send the invoice by 18”",
                       focusRequest: flow.addFocusRequest, clearsOnCommit: true,
                       onCommit: { flow.addTask($0) }, onEditingChanged: { flow.setEditing($0) })
                .padding(Space.xxs)
                .accessibilityLabel("Add task")
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            .strokeBorder(EditorInk.stroke, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    private func leftoverBlock(_ draft: DictationDraft) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            groupTitle("Unparsed")
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(draft.leftover) { item in
                    HStack(spacing: Space.xs) {
                        Text("«\(item.text)»")
                            .font(GlassFont.callout)
                            .foregroundStyle(EditorInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Space.xs)
                        smallButton("Make a task") { flow.promoteLeftover(item.id) }
                        smallButton("Remove") { flow.dismissLeftover(item.id) }
                    }
                    .padding(Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).fill(EditorInk.warning.opacity(0.08)))
                    .onHover { flow.hoveredLeftover = $0 ? item.id : nil }
                }
            }
        }
    }

    private func carryBlock(_ draft: DictationDraft) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            groupTitle("Carried over and long")
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(draft.carry, id: \.task.id) { item in
                    CarryRow(flow: flow, item: item)
                }
            }
        }
    }
}

/// A task from yesterday (or a long one): take it today or not; title, urgency and time editable in place.
private struct CarryRow: View {
    @ObservedObject var flow: DictationFlow
    let item: DictationDraft.CarryItem

    private let dueOpenState = ViewState<Bool>(initialValue: false)
    private var dueOpen: Bool {
        get { dueOpenState.wrappedValue }
        nonmutating set { dueOpenState.wrappedValue = newValue }
    }

    var body: some View {
        let id = item.task.id
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Toggle("", isOn: Binding(get: { item.included }, set: { flow.setIncluded(id, $0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Take for today")
                TitleField(text: item.task.title, onCommit: { flow.rename(id, $0) },
                           onEditingChanged: { flow.setEditing($0) })
                    .padding(Space.xxs)
                if let note = item.task.note {
                    Text(note)
                        .font(GlassFont.micro)
                        .foregroundStyle(EditorInk.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
                PriorityMenu(priority: item.task.priority) { flow.setPriority(id, $0) }
                DueButton(task: item.task, expanded: dueOpenState.projectedValue)
            }
            if dueOpen {
                DuePicker(task: item.task, endOfDay: flow.settings().endOfDayMinutes,
                          onSet: { flow.setDue(id, $0, $1) },
                          onTomorrow: { dueOpen = false; flow.moveToTomorrow(id) },
                          onClose: { withAnimation(.easeOut(duration: 0.2)) { dueOpen = false } })
                    .padding(.leading, Space.l)
                    .padding(.vertical, Space.xxs)
            }
        }
        .padding(Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.field, style: .continuous).fill(EditorInk.rowFill))
        .opacity(item.included ? 1 : 0.45)
    }
}
