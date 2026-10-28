import AppKit
import BubblesCore
import Carbon.HIToolbox

/// One global shortcut through Carbon `RegisterEventHotKey`: works from any app and, unlike an
/// `NSEvent` global monitor, needs no Accessibility permission.
@MainActor final class HotkeyCenter {
    static let shared = HotkeyCenter()

    enum Failure: Error { case taken, invalid }

    /// Runs on the main thread each time the shortcut is pressed.
    var onPress: (() -> Void)?
    private(set) var current: GlobalHotkey?

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4255_4242   // 'BUBB'

    /// Replaces the registered shortcut; nil just unregisters. On failure nothing stays registered.
    func register(_ hotkey: GlobalHotkey?) throws {
        unregister()
        guard let hotkey else { return }
        guard hotkey.isValid else { throw Failure.invalid }
        installHandlerIfNeeded()
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &newRef)
        guard status == noErr, let newRef else { throw Failure.taken }
        ref = newRef
        current = hotkey
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        current = nil
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            // Carbon delivers application-target events on the main thread.
            MainActor.assumeIsolated { HotkeyCenter.shared.onPress?() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    // MARK: - Recording a new shortcut

    /// The shortcut a key-down event describes, or nil for a bare modifier press.
    static func hotkey(from event: NSEvent) -> GlobalHotkey? {
        guard event.type == .keyDown else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= GlobalHotkey.command }
        if flags.contains(.option) { modifiers |= GlobalHotkey.option }
        if flags.contains(.control) { modifiers |= GlobalHotkey.control }
        if flags.contains(.shift) { modifiers |= GlobalHotkey.shift }
        return GlobalHotkey(keyCode: UInt32(event.keyCode), modifiers: modifiers, key: keyName(event))
    }

    private static let namedKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func keyName(_ event: NSEvent) -> String {
        if let name = namedKeys[Int(event.keyCode)] { return name }
        // The character the key prints without modifiers, on the current layout.
        let raw = event.charactersIgnoringModifiers ?? ""
        return raw.isEmpty ? "#\(event.keyCode)" : raw.uppercased()
    }
}
