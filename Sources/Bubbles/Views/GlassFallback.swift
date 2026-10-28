import AppKit
import QuartzCore

/// Behind-window blur clipped to the blob outline, under the soap film of the surfaced bubble only (above
/// windows, so its text stays readable over them); desk bubbles are a clear film. The overlay canvas places
/// it under the bubble's own layers every frame and updates the mask path. Never takes the mouse.
final class BlobEffectView: NSVisualEffectView {
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        blendingMode = .behindWindow
        material = .hudWindow
        state = .active
        wantsLayer = true
        layer?.mask = shape
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `path` is in this view's own coordinates (y-up, origin at its bottom-left corner).
    func setOutline(_ path: CGPath) {
        shape.frame = bounds
        shape.path = path
    }
}
