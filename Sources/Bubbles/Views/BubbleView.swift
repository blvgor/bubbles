import AppKit
import BubblesCore
import SwiftUI

/// What a bubble shows inside its soap film. The film, the rim light and the motion are Core Animation
/// layers (`BubbleCanvas`); this SwiftUI content is rendered to an image only when it changes, so nothing
/// SwiftUI is rebuilt per frame (story 39).
enum BubbleArt {
    /// Renders `view` to a bitmap at the screen's scale; nil if SwiftUI could not render it.
    @MainActor static func image<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// The 64-pt mic circle's glyph.
    static var micGlyph: some View {
        Image(systemName: "mic")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
    }

    /// "+N": the queue of tasks beyond the 8 visible ones.
    static func overflowLabel(count: Int, radius: CGFloat) -> some View {
        Text("+\(count)")
            .font(.system(size: max(13, radius * 0.5), weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: Color(red: 40 / 255, green: 0, blue: 50 / 255).opacity(0.28), radius: 4)
            .frame(width: 2 * radius, height: 2 * radius)
    }
}

/// Pill, title (≤ 3 lines, 2 on small bubbles) and due time; white text with a soft shadow.
struct BubbleContent: View {
    let task: DayTask
    let radius: CGFloat
    let sizeClass: BubbleSizeClass

    var body: some View {
        let r = radius
        VStack(spacing: r * 0.06) {
            PriorityPill(priority: task.priority, dotOnly: sizeClass == .tiny)
            Text(task.title)
                .font(.system(size: min(22, max(11, r * 0.155)), weight: .bold))
                .tracking(-0.1)
                .multilineTextAlignment(.center)
                .lineLimit(sizeClass == .regular ? 3 : 2)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
            if sizeClass == .regular, let due = task.dueText ?? task.note {
                Text(due)
                    .font(.system(size: min(13, max(9, r * 0.09)), design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
            }
        }
        // The soap film is clear inside: a crisp contact shadow plus the prototype's soft dark halo
        // (rgba(20, 0, 40, .55), blur 10) keep the white text readable on light wallpapers.
        .shadow(color: Color(red: 20 / 255, green: 0, blue: 40 / 255).opacity(0.45), radius: 1, y: 1)
        .shadow(color: Color(red: 20 / 255, green: 0, blue: 40 / 255).opacity(0.55), radius: 5)
        .padding(r * 0.24)
        .frame(width: 2 * r, height: 2 * r)
    }
}

/// A closed bubble: grows ×1.5 while fading out, with mint sparks flying off (prototype `pop` + `sparks`).
struct PopEffect: Identifiable {
    let id = UUID()
    let task: DayTask
    let body: BubbleBody
    let layer: DeskLayer
    let sparks: [(angle: Double, reach: Double, duration: Double)]

    init(task: DayTask, body: BubbleBody, layer: DeskLayer) {
        self.task = task
        self.body = body
        self.layer = layer
        sparks = (0..<14).map { _ in (Double.random(in: 0..<2 * .pi), Double.random(in: 1...1.9), Double.random(in: 0.6...0.9)) }
    }
}
