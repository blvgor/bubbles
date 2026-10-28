import AppKit
import BubblesCore
import SwiftUI

/// The dropdown under the menu bar bubble icon (`MenuBarExtra`, window style), screen 11 of the flow:
/// the header, frequent actions, everything about how the bubbles look, "Hide bubbles ▸", "Settings…"
/// and "Quit". Rare settings live in the settings window. Every change goes straight to `SettingsStore`.
struct SettingsMenuView: View {
    let model: AppModel   // not observed: it republishes often
    @ObservedObject var tasks: TaskStore
    @ObservedObject var store: SettingsStore

    // `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode; store the wrapper directly.
    private let contentHeightState = State<CGFloat>(initialValue: 560)
    private var contentHeight: CGFloat {
        get { contentHeightState.wrappedValue }
        nonmutating set { contentHeightState.wrappedValue = newValue }
    }

    private var maxHeight: CGFloat { max(320, (NSScreen.main?.visibleFrame.height ?? 800) - 48) }

    var body: some View {
        ScrollView(.vertical) {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.automatic)
        .frame(width: 304, height: min(contentHeight, maxHeight))
        .foregroundStyle(EditorInk.primary)
        // The menu window brings its own system glass; the tint makes it the same violet glass as the panels
        // in light and dark mode alike.
        .background(EditorInk.panelTint.opacity(0.62))
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            header
                .padding(Space.xs)
            divider
            VStack(spacing: 0) {
                // No AI key: the same panel takes typed tasks only.
                let plain = model.isPlainTracker
                MenuRow(title: plain ? "Type tasks" : "Dictate the day", symbol: plain ? "square.and.pencil" : "mic",
                        shortcut: store.settings.hotkey?.display) {
                    model.startDictation()
                }
                MenuRow(title: "Add task…", symbol: "plus") { model.openAddTask() }
                MenuRow(title: "All tasks", symbol: "list.bullet", shortcut: "⌘L") { model.openAllTasks() }
                    .keyboardShortcut("l")
                SummaryReadyRow(offer: model.summaryOffer) { model.openDaySummary() }
            }
            bubbles
                .glassSection(padding: Space.s, radius: Radius.field)
            closing
                .glassSection(padding: Space.s, radius: Radius.field)
            hide
            divider
            VStack(spacing: 0) {
                MenuRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { model.openSettings() }
                    .keyboardShortcut(",")
                MenuRow(title: "Quit", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.switch)
        .font(GlassFont.callout)
        .padding(Space.s)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Bubbles").font(GlassFont.title)
            Text(MenuStatus.line(taskCount: tasks.tasks.count, done: tasks.doneToday, streak: tasks.streak))
                .font(GlassFont.caption)
                .foregroundStyle(EditorInk.secondary)
            if model.isSampleDay {
                Text("Sample day — dictate your own")
                    .font(GlassFont.caption.weight(.medium))
                    .foregroundStyle(EditorInk.warning)
            }
            SummaryReadyLine(offer: model.summaryOffer)
        }
    }

    /// "Bubbles": shape, glass colour, speed, rotation, animation, mic on the desk.
    private var bubbles: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            groupTitle("Bubble look")
            VStack(alignment: .leading, spacing: Space.xs) {
                valueRow("Shape", store.settings.roundness >= 100 ? "circle" : "\(Int(store.settings.roundness))")
                Slider(value: stepped($store.settings.roundness, by: 1), in: 0...100).tint(EditorInk.mint)
                ends("Chaos", "Circle")
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Glass colour")
                HStack(spacing: 0) {
                    ForEach(Array(GlassTint.allCases.enumerated()), id: \.element) { index, tint in
                        if index > 0 { Spacer(minLength: Space.xxs) }
                        Swatch(tint: tint, selected: store.settings.tint == tint) { store.settings.tint = tint }
                    }
                }
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                valueRow("Speed", "\(Int(store.settings.speed))%")
                Slider(value: stepped($store.settings.speed, by: 5), in: 0...200).tint(EditorInk.mint)
                ends("Frozen", "Racing")
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                SwitchRow(title: "Rotate and tilt text", isOn: $store.settings.rotation)
                SwitchRow(title: "Animation", isOn: Binding(get: { store.settings.animation }, set: { store.settings.animation = $0 }))
                SwitchRow(title: "Microphone on the desk", isOn: Binding(get: { store.settings.micOnDesk }, set: { store.settings.micOnDesk = $0 }))
            }
        }
    }

    /// "Closing": how long the hold takes, and "Can't catch me".
    private var closing: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            groupTitle("Closing")
            VStack(alignment: .leading, spacing: Space.xs) {
                valueRow("Hold the button", "\(Int(store.settings.holdSeconds)) s")
                Slider(value: stepped($store.settings.holdSeconds, by: 1), in: BubbleSettings.holdRange).tint(EditorInk.mint)
                ends("1 s", "30 s")
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                SwitchRow(title: FleeModeText.title,
                          isOn: Binding(get: { store.settings.fleeMode }, set: { store.settings.fleeMode = $0 }))
                Text(FleeModeText.caption)
                    .font(GlassFont.caption)
                    .foregroundStyle(EditorInk.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Hide bubbles ▸ For an hour / Until tomorrow / Until I turn them on", or how long they stay hidden and "Show".
    @ViewBuilder private var hide: some View {
        if let note = store.settings.hidden.menuText() {
            HStack(spacing: Space.xs) {
                Image(systemName: "eye.slash").frame(width: 16)
                Text(note).foregroundStyle(EditorInk.secondary)
                Spacer(minLength: 0)
                Button("Show") { store.settings.hidden = .visible }
                    .buttonStyle(PillButtonStyle(primary: true, small: true))
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, Space.xxs)
        } else {
            Menu {
                ForEach(HideOption.allCases, id: \.self) { option in
                    Button(option.label) {
                        let state = option.hiddenState()
                        store.settings.hidden = state
                        model.showToast(option == .forever ? "Bubbles are off. Turn them back on from the menu bar"
                                                           : "Bubbles \((state.menuText() ?? "").lowercased())")
                    }
                }
            } label: {
                MenuRowLabel(title: "Hide bubbles", symbol: "eye.slash", trailing: Image(systemName: "chevron.right"))
            }
            .menuStyle(.button)
            .buttonStyle(MenuRowStyle())
            .menuIndicator(.hidden)
        }
    }

    // MARK: Pieces

    private var divider: some View {
        Rectangle().fill(EditorInk.softStroke).frame(height: 1).padding(.horizontal, Space.xs)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
            Text(title)
            Spacer(minLength: 0)
            Text(value)
                .font(GlassFont.mono)
                .monospacedDigit()
                .foregroundStyle(EditorInk.secondary)
        }
    }

    private func ends(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer(minLength: 0)
            Text(right)
        }
        .font(GlassFont.caption)
        .foregroundStyle(EditorInk.tertiary)
    }
}

/// "Day summary is ready" under the counters: on "Background only" the summary waits here instead of opening a window.
private struct SummaryReadyLine: View {
    @ObservedObject var offer: SummaryOffer

    var body: some View {
        if offer.isReady {
            Text("Day summary is ready")
                .font(GlassFont.caption.weight(.medium))
                .foregroundStyle(EditorInk.warning)
        }
    }
}

private struct SummaryReadyRow: View {
    @ObservedObject var offer: SummaryOffer
    let action: () -> Void

    var body: some View {
        if offer.isReady {
            MenuRow(title: "Day summary…", symbol: "checkmark.circle", action: action)
        }
    }
}

/// A menu-like row: icon, title, shortcut on the right, highlighted under the pointer.
private struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, symbol: symbol,
                         trailing: shortcut.map { Text($0).foregroundStyle(EditorInk.tertiary) })
        }
        .buttonStyle(MenuRowStyle())
    }
}

private struct MenuRowLabel<Trailing: View>: View {
    let title: String
    let symbol: String
    let trailing: Trailing?

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).frame(width: 16)
            Text(title)
            Spacer(minLength: Space.xs)
            if let trailing { trailing.font(GlassFont.caption) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Full-width row with a rounded hover/press highlight, like a native menu item.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRowBody(configuration: configuration)
    }

    private struct MenuRowBody: View {
        let configuration: ButtonStyleConfiguration
        private let hoverState = State<Bool>(initialValue: false)

        var body: some View {
            let on = hoverState.wrappedValue || configuration.isPressed
            configuration.label
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .frame(minHeight: 28)
                .foregroundStyle(EditorInk.primary)
                .background(RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : (on ? 0.1 : 0))))
                .contentShape(Rectangle())
                .onHover { hoverState.wrappedValue = $0 }
        }
    }
}

/// "Can't catch me" as the menu and the settings window name it.
enum FleeModeText {
    static let title = "Can't catch me"
    static let caption = "Bubbles run away from the mouse — you can't close them until you turn this off"
}

/// A 28-pt glass swatch for one tint; the selected one gets a ring.
struct Swatch: View {
    let tint: GlassTint
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let c = tint.rgb
        Button(action: action) {
            Circle()
                .fill(Color(red: c.r, green: c.g, blue: c.b).opacity(tint == .clear ? 0.25 : 0.6))
                .overlay {
                    Circle().fill(RadialGradient(colors: [Color.white.opacity(0.7), Color.white.opacity(0)],
                                                 center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: 12))
                }
                .overlay { Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1) }
                .frame(width: 28, height: 28)
                .padding(Space.xxs)
                .overlay { Circle().strokeBorder(Color.white, lineWidth: selected ? 2 : 0) }
        }
        .buttonStyle(.plain)
        .help(tint.label)
        .accessibilityLabel(tint.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
