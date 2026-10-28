import BubblesCore
import SwiftUI

/// "Day summary" (screen 10): at "End of day" or on the first start of the next day. Every unclosed task gets
/// a decision — to tomorrow (default), long, or burn. Closing the panel without "Done" carries everything.
struct DaySummaryView: View {
    let title: String
    let closed: Int
    let streak: Int
    let tasks: [DayTask]
    let onDone: ([UUID: DaySummaryChoice]) -> Void
    let onClose: () -> Void

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let choicesState = State<[UUID: DaySummaryChoice]>(initialValue: [:])
    private var choices: [UUID: DaySummaryChoice] {
        get { choicesState.wrappedValue }
        nonmutating set { choicesState.wrappedValue = newValue }
    }

    private let listHeightState = State<CGFloat>(initialValue: 64)
    private var listHeight: CGFloat {
        get { listHeightState.wrappedValue }
        nonmutating set { listHeightState.wrappedValue = newValue }
    }

    private func choice(for task: DayTask) -> DaySummaryChoice {
        choices[task.id] ?? (task.kind == .long ? .long : .carry)
    }

    private var burnCount: Int { tasks.filter { choice(for: $0) == .burn }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(GlassFont.display)
                    .tracking(GlassFont.displayTracking)
                Text("\(closed) of \(closed + tasks.count) done · \(streak)-day streak")
                    .font(GlassFont.mono)
                    .foregroundStyle(EditorInk.secondary)
            }
            ScrollView(.vertical) {
                VStack(spacing: Space.xs) {
                    ForEach(tasks) { task in row(task) }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .frame(height: min(listHeight, 384))
            VStack(alignment: .leading, spacing: Space.s) {
                Text(burnCount > 0 ? "Burned tasks will reset your streak"
                                   : "In the morning these tasks will be in \"Got it\", under \"Carried over and long\"")
                    .font(GlassFont.caption)
                    .foregroundStyle(burnCount > 0 ? EditorInk.dangerSoft : EditorInk.tertiary)
                HStack(spacing: Space.xs) {
                    Button("All to tomorrow", action: onClose)
                        .buttonStyle(PillButtonStyle())
                    Spacer(minLength: 0)
                    Button("Done") {
                        var result: [UUID: DaySummaryChoice] = [:]
                        for task in tasks { result[task.id] = choice(for: task) }
                        onDone(result)
                    }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Space.panel)
        .frame(width: 600)
        .glassPanel()
    }

    private func row(_ task: DayTask) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(task.title)
                    .font(GlassFont.calloutBold)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(choice(for: task) == .burn, color: EditorInk.secondary)
                HStack(spacing: Space.xs) {
                    Text(task.priority.label)
                    if let due = task.dueText { Text(due) }
                    if let note = task.note { Text(note) }
                }
                .font(GlassFont.micro)
                .foregroundStyle(EditorInk.tertiary)
            }
            HStack(spacing: Space.xxs) {
                ForEach(DaySummaryChoice.allCases, id: \.self) { option in
                    let on = choice(for: task) == option
                    Button { choices[task.id] = option } label: {
                        Text(option.label)
                            .font(GlassFont.captionBold)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Space.xs)
                            .foregroundStyle(on ? EditorInk.ink : EditorInk.primary)
                            .background(Capsule(style: .continuous).fill(
                                on ? (option == .burn ? EditorInk.dangerSoft : Color.white.opacity(0.92))
                                   : Color.white.opacity(0.1)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .glassSection(padding: Space.s)
    }
}
