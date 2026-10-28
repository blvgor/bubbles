import SwiftUI

/// A button on the toast. Tapping it hides the toast, then runs `run`.
struct ToastAction: Identifiable {
    let id = UUID()
    var label: String
    var primary: Bool = false
    var run: @MainActor () -> Void

    init(label: String, primary: Bool = false, run: @escaping @MainActor () -> Void) {
        self.label = label
        self.primary = primary
        self.run = run
    }
}

/// What the toast shows right now (`AppModel.toast`).
struct ToastMessage: Identifiable {
    let id = UUID()
    var text: String
    var actions: [ToastAction]
}

/// Dark glass pill, bottom centre above the mic: message plus optional action buttons.
struct ToastView: View {
    let toast: ToastMessage
    let onAction: (ToastAction) -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Text(toast.text)
                .font(GlassFont.callout)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !toast.actions.isEmpty {
                HStack(spacing: Space.xs) {
                    ForEach(toast.actions) { action in
                        Button(action.label) { onAction(action) }
                            .buttonStyle(PillButtonStyle(primary: action.primary, small: true))
                    }
                }
            }
        }
        .padding(.vertical, Space.s)
        .padding(.leading, Space.m)
        .padding(.trailing, toast.actions.isEmpty ? Space.m : Space.s)
        .frame(maxWidth: 560)
        .glassPanel(radius: Radius.panel, tint: 0.55)
        .accessibilityElement(children: .contain)
    }
}
