import Foundation
import Testing
import BubblesCore

@MainActor @Suite struct SettingsStoreTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "bubbles-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test func freshStoreHasSpecDefaults() {
        withDefaults { defaults in
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.roundness == 70)
            #expect(s.tint == .clear)
            #expect(s.speed == 100)
            #expect(s.rotation && s.animation)
            #expect(s.surfaceEveryMinutes == nil)      // F2: background only until the person turns the ladder on
            #expect(s.takeoverBeforeMinutes == nil)
            #expect(s.endOfDayMinutes == 20 * 60)
            #expect(s.hidden == .visible)
            #expect(!s.launchAtLoginOffered)
            #expect(s.micOnDesk)
        }
    }

    @Test func settingsSurviveRestartIncludingOffValues() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.settings.roundness = 12
            store.settings.tint = .mint
            store.settings.speed = 150
            store.settings.rotation = false
            store.settings.surfaceEveryMinutes = nil
            store.settings.takeoverBeforeMinutes = 5
            store.settings.endOfDayMinutes = nil
            store.settings.hidden = .forever
            store.settings.micOnDesk = false
            let saved = store.settings

            let restored = SettingsStore(defaults: defaults).settings
            #expect(restored == saved)
            #expect(restored.surfaceEveryMinutes == nil)
            #expect(restored.endOfDayMinutes == nil)
            #expect(!restored.micOnDesk)
        }
    }

    /// Story 42: saves from before "Microphone on the desk" keep the mic on the desk.
    @Test func olderSaveWithoutMicKeyShowsTheMic() throws {
        let old = Data(#"{"roundness":40,"tint":"sky","speed":100,"rotation":true,"animation":true}"#.utf8)
        let decoded = try JSONDecoder().decode(BubbleSettings.self, from: old)
        #expect(decoded.micOnDesk)
        #expect(decoded.roundness == 40)
    }

    @Test func corruptStoredValueFallsBackToDefaults() {
        withDefaults { defaults in
            defaults.set(Data("garbage".utf8), forKey: "bubbles.settings")
            #expect(SettingsStore(defaults: defaults).settings == BubbleSettings())
        }
    }

    @Test func expiredHideIsLifted() {
        withDefaults { defaults in
            let now = Date()
            let store = SettingsStore(defaults: defaults)
            store.settings.hidden = .until(now.addingTimeInterval(-60))
            store.expireHiddenIfNeeded(now: now)
            #expect(store.settings.hidden == .visible)
            #expect(SettingsStore(defaults: defaults).settings.hidden == .visible)
        }
    }

    @Test func activeAndPermanentHidesStay() {
        withDefaults { defaults in
            let now = Date()
            let store = SettingsStore(defaults: defaults)
            let until = now.addingTimeInterval(3600)
            store.settings.hidden = .until(until)
            store.expireHiddenIfNeeded(now: now)
            #expect(store.settings.hidden == .until(until))
            store.settings.hidden = .forever
            store.expireHiddenIfNeeded(now: now.addingTimeInterval(86_400 * 30))
            #expect(store.settings.hidden == .forever)
        }
    }

    @Test func tintsHaveLabelsAndColours() {
        #expect(GlassTint.allCases.map(\.label) == ["Clear", "Pink", "Lilac", "Sky", "Mint", "Amber"])
        #expect(GlassTint.pink.rgb == (1, 0.47, 0.71))
        #expect(GlassTint.clear.rgb == (1, 1, 1))
    }

    // MARK: - T08

    @Test func newLadderAndDictationDefaults() {
        let s = BubbleSettings()
        #expect(s.pauseDuringCalls && s.allowExtension && s.showTranscript)
        #expect(s.hotkey == GlobalHotkey(keyCode: 49, modifiers: 0x0800, key: "Space"))
        #expect(s.hotkey?.display == "⌥Space")
        #expect(s.separatorWord == "next")
    }

    @Test func hotkeyOffAndChangesSurviveRestart() {
        withDefaults { defaults in
            let store = SettingsStore(defaults: defaults)
            store.settings.hotkey = nil
            store.settings.pauseDuringCalls = false
            store.settings.allowExtension = false
            #expect(SettingsStore(defaults: defaults).settings.hotkey == nil)
            store.settings.hotkey = GlobalHotkey(keyCode: 2, modifiers: 0x0100 | 0x0200, key: "D")
            let restored = SettingsStore(defaults: defaults).settings
            #expect(restored.hotkey?.display == "⇧⌘D")
            #expect(!restored.pauseDuringCalls && !restored.allowExtension)
        }
    }

    @Test func olderSaveGetsTheHotkeyAndPauses() throws {
        let old = Data(#"{"roundness":40,"micOnDesk":false}"#.utf8)
        let decoded = try JSONDecoder().decode(BubbleSettings.self, from: old)
        #expect(decoded.hotkey == .optionSpace)
        #expect(decoded.pauseDuringCalls && decoded.allowExtension)
    }

    @Test func hotkeyNeedsACommandOptionOrControl() {
        #expect(GlobalHotkey.optionSpace.isValid)
        #expect(!GlobalHotkey(keyCode: 49, modifiers: 0, key: "Space").isValid)
        #expect(!GlobalHotkey(keyCode: 2, modifiers: 0x0200, key: "D").isValid)
        #expect(GlobalHotkey(keyCode: 2, modifiers: 0x1000 | 0x0800 | 0x0200 | 0x0100, key: "D").display == "⌃⌥⇧⌘D")
    }

    @Test func presetsSetTheLadder() {
        var s = BubbleSettings()
        LadderPreset.backgroundOnly.apply(to: &s)
        #expect(s.surfaceEveryMinutes == nil && s.takeoverBeforeMinutes == nil)
        #expect(LadderPreset.matching(s) == .backgroundOnly)
        LadderPreset.gentle.apply(to: &s)
        #expect(s.surfaceEveryMinutes == 45 && s.takeoverBeforeMinutes == 15)
        LadderPreset.strict.apply(to: &s)
        #expect(s.surfaceEveryMinutes == 30 && s.takeoverBeforeMinutes == 30)
        #expect(LadderPreset.matching(BubbleSettings()) == .backgroundOnly)
        s.surfaceEveryMinutes = 90
        #expect(LadderPreset.matching(s) == nil)
        #expect(LadderPreset.allCases.map(\.label) == ["Background only", "Gentle", "Strict"])
    }

    @Test func claudeKeyCheckRequest() {
        let request = ClaudeKeyCheck.request(apiKey: "  test-key\n")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=1")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.timeoutInterval == 15)
    }

    @Test func claudeKeyCheckStatuses() {
        #expect(ClaudeKeyCheck.status(httpCode: 200) == .valid)
        #expect(ClaudeKeyCheck.status(httpCode: 401) == .invalid)
        #expect(ClaudeKeyCheck.status(httpCode: 403) == .invalid)
        for code in [429, 500, 529] {
            guard case .unavailable = ClaudeKeyCheck.status(httpCode: code) else {
                Issue.record("\(code) should be «unavailable»")
                continue
            }
        }
    }

    // MARK: - F2: one-time ladder migration

    private func save(_ json: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: "bubbles.settings")
    }

    @Test func untouchedOldDefaultsBecomeBackgroundOnlyOnce() {
        withDefaults { defaults in
            save(#"{"roundness":40,"surfaceEveryMinutes":45,"takeoverBeforeMinutes":15,"endOfDayMinutes":1200}"#, to: defaults)
            let store = SettingsStore(defaults: defaults)
            #expect(store.settings.surfaceEveryMinutes == nil)
            #expect(store.settings.takeoverBeforeMinutes == nil)
            #expect(store.settings.roundness == 40)
            #expect(store.settings.endOfDayMinutes == 1200)

            // Done once: a person who then picks "Gentle" keeps it across restarts.
            LadderPreset.gentle.apply(to: &store.settings)
            let restored = SettingsStore(defaults: defaults).settings
            #expect(restored.surfaceEveryMinutes == 45 && restored.takeoverBeforeMinutes == 15)
        }
    }

    @Test func oldSaveWithoutLadderKeysAlsoBecomesBackgroundOnly() {
        withDefaults { defaults in
            save(#"{"roundness":40}"#, to: defaults)   // missing keys used to mean 45 / 15
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.surfaceEveryMinutes == nil && s.takeoverBeforeMinutes == nil)
        }
    }

    @Test func chosenLadderValuesAreNotTouchedByTheMigration() {
        withDefaults { defaults in
            save(#"{"surfaceEveryMinutes":30,"takeoverBeforeMinutes":30}"#, to: defaults)
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.surfaceEveryMinutes == 30 && s.takeoverBeforeMinutes == 30)
        }
        withDefaults { defaults in
            save(#"{"surfaceEveryMinutes":45,"takeoverBeforeMinutes":null}"#, to: defaults)   // one rung changed by hand
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.surfaceEveryMinutes == 45 && s.takeoverBeforeMinutes == nil)
        }
    }

    @Test func migratedSaveIsNotMigratedAgain() {
        withDefaults { defaults in
            save(#"{"surfaceEveryMinutes":45,"takeoverBeforeMinutes":15,"ladderDefaultsMigrated":true}"#, to: defaults)
            let s = SettingsStore(defaults: defaults).settings
            #expect(s.surfaceEveryMinutes == 45 && s.takeoverBeforeMinutes == 15)
        }
    }

    @Test func freshInstallStartsMigratedAndSurvivesRestart() {
        withDefaults { defaults in
            #expect(BubbleSettings().ladderDefaultsMigrated)
            let store = SettingsStore(defaults: defaults)
            store.settings.roundness = 50
            LadderPreset.gentle.apply(to: &store.settings)
            let restored = SettingsStore(defaults: defaults).settings
            #expect(restored.surfaceEveryMinutes == 45 && restored.takeoverBeforeMinutes == 15)
        }
    }
}
