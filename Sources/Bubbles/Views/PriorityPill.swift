import BubblesCore
import SwiftUI

extension Priority {
    /// Dot colour: urgent #FF2D55, important #FF9F0A, normal #0A84FF.
    var color: Color {
        switch self {
        case .urgent: Color(red: 1, green: 0x2D / 255, blue: 0x55 / 255)
        case .important: Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
        case .normal: Color(red: 0x0A / 255, green: 0x84 / 255, blue: 1)
        }
    }
}

/// White capsule with a coloured dot and a black label: padding 8×4, continuous corners.
/// `dotOnly` is for the tiniest bubbles, where only the dot fits.
struct PriorityPill: View {
    let priority: Priority
    var dotOnly = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(priority.color).frame(width: 6, height: 6)
            if !dotOnly {
                Text(priority.label)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, dotOnly ? 4 : 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(Color.white))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(priority.label)
    }
}
