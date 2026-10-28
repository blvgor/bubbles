import Foundation
import Testing
import BubblesCore

/// F6: dictation through Handy — the engine setting, Handy's shortcut from its settings file, and
/// «one insertion = one line».
@Suite struct HandyTests {
    // MARK: Engine setting

    // F7 made the built-in Whisper the default (WhisperTests); a save that says `system` stays macOS.
    @Test func savedSystemEngineStaysSystem() throws {
        let saved = Data(#"{"roundness": 40, "tint": "mint", "speechEngine": "system"}"#.utf8)
        #expect(try JSONDecoder().decode(BubbleSettings.self, from: saved).speechEngine == .system)
    }

    @Test func handyEngineSurvivesASave() throws {
        var settings = BubbleSettings()
        settings.speechEngine = .handy
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(BubbleSettings.self, from: data).speechEngine == .handy)
    }

    @Test func handyCountsOnlyWhenInstalled() {
        #expect(SpeechEngine.effective(selected: .handy, handyInstalled: true) == .handy)
        #expect(SpeechEngine.effective(selected: .handy, handyInstalled: false) == .whisper)
        #expect(SpeechEngine.effective(selected: .handy, handyInstalled: false, whisperReady: false) == .system)
        #expect(SpeechEngine.effective(selected: .system, handyInstalled: true) == .system)
    }

    // MARK: Handy's shortcut

    @Test func readsOnlyTheTranscribeBinding() {
        let json = #"""
        {"settings": {"bindings": {"transcribe": {"id": "transcribe", "current_binding": "option+space",
          "default_binding": "fn"}, "cancel": {"current_binding": "escape"}},
          "some_other_field": "ignored", "selected_model": "synthetic"}}
        """#
        #expect(HandyShortcut.binding(fromSettingsJSON: Data(json.utf8)) == "option+space")
    }

    @Test func missingOrBrokenSettingsGiveNoBinding() {
        #expect(HandyShortcut.binding(fromSettingsJSON: Data("not json".utf8)) == nil)
        #expect(HandyShortcut.binding(fromSettingsJSON: Data(#"{"settings": {"bindings": {}}}"#.utf8)) == nil)
        #expect(HandyShortcut.binding(fromSettingsJSON: Data(#"{"settings": {"bindings": {"transcribe": {"current_binding": "  "}}}}"#.utf8)) == nil)
        #expect(HandyShortcut.binding(fromSettingsJSON: Data(#"[1, 2]"#.utf8)) == nil)
    }

    @Test func shortcutIsShownTheMacWay() {
        #expect(HandyShortcut.display("fn") == "fn")
        #expect(HandyShortcut.display("option+space") == "⌥Space")
        #expect(HandyShortcut.display("option+shift+space") == "⌥⇧Space")
        #expect(HandyShortcut.display("shift+option+space") == "⌥⇧Space")
        #expect(HandyShortcut.display("ctrl+d") == "⌃D")
        #expect(HandyShortcut.display("cmd+shift+f5") == "⇧⌘F5")
        #expect(HandyShortcut.display("alt+command+k") == "⌥⌘K")
    }

    @Test func conflictWithOurHotkey() {
        #expect(HandyShortcut.conflicts("option+space", with: .optionSpace))
        #expect(HandyShortcut.conflicts("alt+Space", with: .optionSpace))
        #expect(!HandyShortcut.conflicts("option+shift+space", with: .optionSpace))
        #expect(!HandyShortcut.conflicts("fn", with: .optionSpace))
        #expect(!HandyShortcut.conflicts("option+space", with: nil))
        let ctrlD = GlobalHotkey(keyCode: 2, modifiers: GlobalHotkey.control, key: "D")
        #expect(HandyShortcut.conflicts("ctrl+d", with: ctrlD))
    }

    @Test func hintNamesTheKeyOrStaysGeneric() {
        #expect(HandyShortcut.hint(binding: "fn") == "Hold fn and speak — Handy will type the text")
        #expect(HandyShortcut.hint(binding: "option+space") == "Hold ⌥Space and speak — Handy will type the text")
        #expect(HandyShortcut.hint(binding: nil) == "Hold the Handy key and speak — Handy will type the text")
    }

    // MARK: One insertion = one line

    private func insert(_ inserted: String, into text: String, at location: Int? = nil, length: Int = 0,
                        since: TimeInterval? = nil) -> String {
        let ns = text as NSString
        let range = NSRange(location: location ?? ns.length, length: length)
        let piece = InsertionLines.text(inserting: inserted, into: text, range: range, sincePreviousInsertion: since)
        return ns.replacingCharacters(in: range, with: piece ?? inserted)
    }

    @Test func firstInsertionGoesInAsIs() {
        #expect(insert("Transfer the rent", into: "") == "Transfer the rent")
    }

    @Test func insertionAfterTextStartsANewLine() {
        #expect(insert("Book a dentist appointment ", into: "Transfer the rent ")
                == "Transfer the rent \nBook a dentist appointment ")
        #expect(insert(" Buy groceries", into: "Transfer the rent") == "Transfer the rent\nBuy groceries")
    }

    @Test func emptyCurrentLineNeedsNoBreak() {
        #expect(insert("Buy groceries", into: "Transfer the rent\n") == "Transfer the rent\nBuy groceries")
        #expect(insert("Buy groceries", into: "Transfer the rent\n   ") == "Transfer the rent\n   Buy groceries")
    }

    @Test func typingOneLetterDoesNotBreakTheLine() {
        #expect(InsertionLines.text(inserting: "a", into: "Transfer the rent", range: NSRange(location: 17, length: 0)) == nil)
        #expect(InsertionLines.text(inserting: " ", into: "Transfer", range: NSRange(location: 8, length: 0)) == nil)
        #expect(InsertionLines.text(inserting: " b ", into: "Transfer", range: NSRange(location: 8, length: 0)) == nil)
    }

    @Test func insertionInsideALineGetsItsOwnLine() {
        // cursor at the start of a non-empty line: the rest moves below
        #expect(insert("Buy groceries", into: "Transfer the rent", at: 0) == "Buy groceries\nTransfer the rent")
        // cursor in the middle: both sides
        #expect(insert("Buy groceries", into: "Transfer the rent", at: 9) == "Transfer \nBuy groceries\nthe rent")
    }

    @Test func replacingASelectionLooksAroundIt() {
        // the whole second line selected: it is simply replaced
        #expect(insert("Buy groceries", into: "Transfer the rent\nscribble", at: 18, length: 8)
                == "Transfer the rent\nBuy groceries")
    }

    @Test func pieceOfTheSameBurstContinuesTheLine() {
        #expect(InsertionLines.text(inserting: " rent and bill", into: "Transfer the", range: NSRange(location: 12, length: 0),
                                    sincePreviousInsertion: 0.05) == nil)
        #expect(insert("Buy groceries", into: "Transfer the rent", since: 3) == "Transfer the rent\nBuy groceries")
    }
}
