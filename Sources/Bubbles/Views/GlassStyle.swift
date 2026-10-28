import SwiftUI

// The one visual language of every panel, taken from the onboarding (the look the user called beautiful):
// dark Liquid Glass, big continuous corners, white type, capsule buttons, soft translucent sections.
// Spacing is on the 4-pt scale (4/8/12/16/24/32); inside a group is always tighter than between groups.

/// Spacing scale. `panel` is the padding of every panel and window on all sides.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    /// Padding of a panel / window, the same on every side.
    static let panel: CGFloat = 32
    /// Between blocks inside a panel (heading → content → buttons).
    static let block: CGFloat = 24
}

/// Corner radii: panel 24 → section 16 → field / row 12 → small row 8. Buttons are capsules.
enum Radius {
    static let panel: CGFloat = 24
    static let section: CGFloat = 16
    static let field: CGFloat = 12
    static let row: CGFloat = 8
}

/// The type scale: 28 display · 17 title · 15 body · 14 button · 13 callout · 12 caption · 11 micro.
enum GlassFont {
    static let display = Font.system(size: 28, weight: .heavy)
    static let displayTracking: CGFloat = -0.6
    static let title = Font.system(size: 17, weight: .bold)
    static let body = Font.system(size: 15)
    static let bodyMedium = Font.system(size: 15, weight: .medium)
    static let button = Font.system(size: 14, weight: .bold)
    static let callout = Font.system(size: 13, weight: .medium)
    static let calloutBold = Font.system(size: 13, weight: .bold)
    static let caption = Font.system(size: 12)
    static let captionBold = Font.system(size: 12, weight: .bold)
    static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
    static let micro = Font.system(size: 11, weight: .medium, design: .monospaced)
}

/// Colours on dark glass: white text in three strengths, translucent fills, accents.
enum EditorInk {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.76)
    static let tertiary = Color.white.opacity(0.54)
    static let faint = Color.white.opacity(0.4)
    static let rowFill = Color.white.opacity(0.05)
    static let rowSelected = Color.white.opacity(0.1)
    static let sectionFill = Color.white.opacity(0.07)
    static let controlFill = Color.white.opacity(0.12)
    static let controlHover = Color.white.opacity(0.18)
    static let stroke = Color.white.opacity(0.16)
    static let softStroke = Color.white.opacity(0.1)
    static let warning = Color(red: 1, green: 0.78, blue: 0.4)
    static let danger = Color(red: 1, green: 0.42, blue: 0.48)
    static let dangerSoft = Color(red: 1, green: 0.55, blue: 0.6)
    static let mint = Color(red: 0x86 / 255, green: 0xF5 / 255, blue: 0xB8 / 255)
    /// Dark text on white / mint fills.
    static let ink = Color(red: 20 / 255, green: 8 / 255, blue: 28 / 255)
    /// The violet the panel glass is tinted with.
    static let panelTint = Color(red: 16 / 255, green: 7 / 255, blue: 24 / 255)
}

// MARK: - Surfaces

/// The panel: tinted Liquid Glass, 24-pt continuous corners, a hairline rim, dark scheme, white text.
struct GlassPanel: ViewModifier {
    var radius: CGFloat = Radius.panel
    var tint: Double = 0.62

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .foregroundStyle(EditorInk.primary)
            .glassEffect(.regular.tint(EditorInk.panelTint.opacity(tint)), in: shape)
            .overlay(shape.strokeBorder(EditorInk.stroke, lineWidth: 1))
            .environment(\.colorScheme, .dark)
    }
}

/// A soft section inside a panel: translucent fill, 16-pt corners, its own 16-pt padding.
struct GlassSection: ViewModifier {
    var padding: CGFloat = Space.m
    var radius: CGFloat = Radius.section
    var selected = false
    var tone: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tone.map { $0.opacity(0.12) } ?? Color.white.opacity(selected ? 0.16 : 0.07)))
            .overlay(shape.strokeBorder(tone.map { $0.opacity(0.3) } ?? Color.white.opacity(selected ? 0.5 : 0.08), lineWidth: 1))
    }
}

/// A text input: translucent fill, hairline rim, 12-pt corners, 16 × 12 inset.
struct GlassField: ViewModifier {
    var focused = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(shape.fill(Color.white.opacity(0.08)))
            .overlay(shape.strokeBorder(Color.white.opacity(focused ? 0.4 : 0.16), lineWidth: 1))
    }
}

/// What a popover shows (the time picker): a raised glass card of fixed width that lives inside the
/// window, so it is never cut by the window edge and never covers the title.
struct GlassPopover: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.section, style: .continuous)
        content
            .padding(Space.m)
            .background(shape.fill(Color.white.opacity(0.1)))
            .overlay(shape.strokeBorder(EditorInk.stroke, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.25), radius: 16, y: 8)
    }
}

extension View {
    func glassPanel(radius: CGFloat = Radius.panel, tint: Double = 0.62) -> some View {
        modifier(GlassPanel(radius: radius, tint: tint))
    }
    func glassSection(padding: CGFloat = Space.m, radius: CGFloat = Radius.section, selected: Bool = false,
                      tone: Color? = nil) -> some View {
        modifier(GlassSection(padding: padding, radius: radius, selected: selected, tone: tone))
    }
    func glassField(focused: Bool = false) -> some View { modifier(GlassField(focused: focused)) }
    func glassPopover() -> some View { modifier(GlassPopover()) }
}

// MARK: - Text

/// A panel heading: the big title and its text, one group 8 pt apart.
struct PanelHeading: View {
    let title: String
    var text: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title)
                .font(GlassFont.display)
                .tracking(GlassFont.displayTracking)
                .fixedSize(horizontal: false, vertical: true)
            if let text, !text.isEmpty {
                Text(text)
                    .font(GlassFont.body)
                    .foregroundStyle(EditorInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Group heading in small caps (lists, sections).
@MainActor func groupTitle(_ text: String) -> some View {
    Text(text.uppercased())
        .font(GlassFont.micro)
        .tracking(1.1)
        .foregroundStyle(EditorInk.tertiary)
}

// MARK: - Buttons

/// Capsule button. Primary: white with dark text. Secondary: translucent white. Destructive: soft red.
/// `small` is the compact size for rows and secondary actions.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    var small = false
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, primary: primary, small: small, destructive: destructive)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        let primary: Bool
        let small: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var isEnabled
        private let hoverState = State<Bool>(initialValue: false)

        var body: some View {
            let hover = hoverState.wrappedValue && isEnabled
            let pressed = configuration.isPressed
            configuration.label
                .font(small ? GlassFont.captionBold : GlassFont.button)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, small ? Space.s : Space.m)
                .padding(.vertical, small ? Space.xs : Space.s)
                .background(Capsule(style: .continuous).fill(fill(hover: hover, pressed: pressed)))
                .overlay(Capsule().strokeBorder(rim, lineWidth: 1))
                .scaleEffect(pressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hoverState.wrappedValue = $0 }
                .animation(.easeOut(duration: 0.15), value: hover)
                .animation(.easeOut(duration: 0.1), value: pressed)
        }

        private var foreground: Color {
            if primary { return EditorInk.ink }
            if destructive { return EditorInk.dangerSoft }
            return EditorInk.primary
        }

        private func fill(hover: Bool, pressed: Bool) -> Color {
            if primary {
                return destructive ? EditorInk.dangerSoft.opacity(pressed ? 0.8 : 1) : Color.white.opacity(pressed ? 0.8 : (hover ? 0.92 : 1))
            }
            if destructive { return EditorInk.danger.opacity(pressed ? 0.3 : (hover ? 0.24 : 0.16)) }
            return Color.white.opacity(pressed ? 0.24 : (hover ? 0.18 : 0.12))
        }

        private var rim: Color {
            if primary { return Color.clear }
            return destructive ? EditorInk.danger.opacity(0.3) : EditorInk.softStroke
        }
    }
}

/// A quiet text button (Skip, Emergency exit): no fill, dimmed until hovered.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration)
    }

    private struct QuietBody: View {
        let configuration: ButtonStyleConfiguration
        private let hoverState = State<Bool>(initialValue: false)

        var body: some View {
            configuration.label
                .font(GlassFont.callout)
                .foregroundStyle(Color.white.opacity(hoverState.wrappedValue || configuration.isPressed ? 0.92 : 0.6))
                .padding(.vertical, Space.xs)
                .contentShape(Rectangle())
                .onHover { hoverState.wrappedValue = $0 }
        }
    }
}

/// Compact capsule chip for row actions ("Merge", "Clear time").
@MainActor func smallButton(_ title: String, _ action: @escaping () -> Void) -> some View {
    Button(title, action: action)
        .buttonStyle(ChipButtonStyle())
        .fixedSize()
}

/// The chip look: 12-pt label in a translucent capsule, 12 × 4 inset.
struct ChipButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GlassFont.captionBold)
            .lineLimit(1)
            .foregroundStyle(selected ? EditorInk.ink : EditorInk.primary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xxs)
            .background(Capsule(style: .continuous)
                .fill(selected ? Color.white : Color.white.opacity(configuration.isPressed ? 0.22 : 0.12)))
            .contentShape(Capsule())
    }
}

// MARK: - Controls

/// A row of equal capsules spanning the width; the selected one is white with dark text.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    let selection: Value?
    var small = false
    let onSelect: (Value) -> Void

    init(options: [(Value, String)], selection: Value?, small: Bool = false, onSelect: @escaping (Value) -> Void) {
        self.options = options
        self.selection = selection
        self.small = small
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let on = selection.map { $0 == option.0 } ?? false
                Button { onSelect(option.0) } label: {
                    Text(option.1)
                        .font(small ? GlassFont.captionBold : GlassFont.calloutBold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.xs)
                        .padding(.horizontal, Space.xs)
                        .foregroundStyle(on ? EditorInk.ink : EditorInk.primary)
                        .background(Capsule(style: .continuous).fill(Color.white.opacity(on ? 0.92 : 0.1)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.easeOut(duration: 0.2), value: selection)
    }
}

/// Title on the left, switch at the right edge.
struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.xs)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .tint(EditorInk.mint.opacity(0.9))
        }
    }
}

/// A selectable card: radio mark, name and what it does (ladder presets, the kind of glass).
struct ChoiceCard: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(GlassFont.calloutBold)
                    Text(detail)
                        .font(GlassFont.caption)
                        .foregroundStyle(EditorInk.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .glassSection(padding: Space.s, selected: selected)
            .contentShape(RoundedRectangle(cornerRadius: Radius.section, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Rounds a slider's value to `step` without `Slider(step:)`, whose tick marks draw a dotted line under it.
@MainActor func stepped(_ value: Binding<Double>, by step: Double) -> Binding<Double> {
    Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 / step).rounded() * step })
}
