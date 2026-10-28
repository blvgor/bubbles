import AppKit
import BubblesCore
import SwiftUI

/// The Handy field: a plain multi-line text view that has the cursor as soon as the panel opens. Every paste
/// or programmatic insertion longer than one character (what Handy does when the key is released) starts a
/// new line if the current one has text — one insertion, one task (`InsertionLines`). Typing stays as usual.
struct HandyTextView: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let view = LineInsertingTextView()
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: fontSize, weight: .medium)
        view.textColor = .white
        view.insertionPointColor = .white
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium), .foregroundColor: NSColor.white]
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 0)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("Tasks from Handy")
        view.string = text
        view.delegate = context.coordinator
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// `NSTextView` that puts each multi-character insertion on its own line and takes the cursor when it lands in
/// a window (the dictation panel is key by then).
final class LineInsertingTextView: NSTextView {
    /// The last multi-character insertion: a phrase typed in by chunks continues its own line.
    private var lastInsertion: Date?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Marked text (input methods) and replacements (autocorrect) go through unchanged.
        guard !hasMarkedText(), replacementRange.location == NSNotFound,
              let inserted = (string as? String) ?? (string as? NSAttributedString)?.string else {
            return super.insertText(string, replacementRange: replacementRange)
        }
        super.insertText(lineAware(inserted), replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard let inserted = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        super.insertText(lineAware(inserted), replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }

    /// ⌘V without an Edit menu (a menu-bar app), by key code so it works in any keyboard layout — Handy
    /// pastes with a simulated ⌘V.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if window?.firstResponder === self, mods == .command, event.keyCode == 9 {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func lineAware(_ inserted: String) -> String {
        let now = Date()
        let since = lastInsertion.map { now.timeIntervalSince($0) }
        if inserted.trimmingCharacters(in: .whitespacesAndNewlines).count > 1 { lastInsertion = now }
        return InsertionLines.text(inserting: inserted, into: string, range: selectedRange(),
                                   sincePreviousInsertion: since) ?? inserted
    }
}
