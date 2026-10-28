<!-- autopilot:start -->
# Bubbles

A native macOS menu bar app: the day's tasks live on the desktop as soap bubbles and do not let go until they are done.

Architecture, module boundaries and conventions are in `docs/architecture.md`; why things are the way they are is in `docs/adr/`; the project's vocabulary is in `CONTEXT.md`.

## Commands

| Command | What it does |
|---------|--------------|
| `make vendor` | downloads the whisper.cpp engine and the Whisper model into `Vendor/` once (≈550 MB, sha256 is verified); `make check` and `make app` call it themselves |
| `make check` | build and all tests through SwiftPM (Swift Testing); run outside the sandbox |
| `make check-direct` | the same through `swiftc`, without SwiftPM; works inside the sandbox too |
| `make app` | builds `build/Bubbles.app` (release, ad-hoc signature, arm64) with the engine and the model inside (≈560 MB); `WHISPER_MODEL=0 make app` builds without the model |
| `make run` | builds and opens the app with `open build/Bubbles.app` |
| `make install` | copies the app to `~/Applications` |
| `swift test --disable-sandbox -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter TaskStoreTests` | one test suite (the suite name goes after `--filter`) |
| `scripts/direct-build.sh test --filter TaskStoreTests` | one test suite without SwiftPM |
| `make clean` | removes `.build` and `build` |

## Where things are

- `Sources/BubblesCore/` is all the logic without AppKit and SwiftUI: `Models.swift`, `TaskStore.swift`, `Ladder.swift`, `Physics.swift`, `Ranker.swift`, `Settings.swift`, and dictation parsing (`TaskParser.swift`, `ClaudeTaskParser.swift`, `OpenAITaskParser.swift`, `ParserProvider.swift`). A new rule goes here first, with a test.
- `Tests/BubblesCoreTests/` holds the core tests, one file per area (`LadderTests.swift`, `PhysicsTests.swift`, …).
- `Sources/Bubbles/AppModel.swift` is the single point of app state: `start()`, the frame (`advanceFrame`), the ladder (`runLadder`), actions on tasks.
- `Sources/Bubbles/Windows/OverlayWindows.swift` and `Views/BubbleCanvas.swift` are the desk and surfacing windows, the display link, and drawing the bubbles with Core Animation layers. The soap film of a bubble is `Views/SoapFilm.swift`.
- `Sources/Bubbles/Dictation/` and `Views/DictationFlowView.swift` are dictation, the "Got it" review and parsing through a provider. The built-in Whisper is `WhisperEngine.swift`; recording and splitting at pauses are `SegmentRecorder.swift` and `BubblesCore/SpeechSegments.swift`.
- `Sources/Bubbles/Views/SettingsWindowView.swift`, `SettingsMenuView.swift`, `OnboardingView.swift` are the settings, the menu bar menu and the first-run introduction. UI texts are in English; dictation input may be Russian or English.
- `Sources/Bubbles/System/APIKeyStore.swift` is the only place where keys are read and written (the keychain).
- `Makefile`, `scripts/build-app.sh`, `scripts/direct-build.sh`, `Resources/Info.plist` build and package the `.app`.

## Gotchas

- Start the app only through `open` or Finder (`make run`). The binary `build/Bubbles.app/Contents/MacOS/Bubbles` run from a terminal crashes when it asks for the microphone: TCC takes the usage description from the parent process.
- When testing, do not open the app's windows on the user's screen (introduction, takeover, dictation, settings) and do not run the ladder: the user has their own instance running.
- `@State` and other SwiftUI macros (`@Entry`, `#Preview`) do not compile with the Command Line Tools: the SwiftUIMacros plugin is missing. Use `State(initialValue:)`.
- There is no XCTest, only Swift Testing (`import Testing`, `@Test`, `#expect`).
- SwiftPM without `-plugin-path` does not find TestingMacros; the flag is already in the `Makefile` (`TEST_FLAGS`). If "TestingMacros plugin not found" still shows up after two simultaneous builds, `rm -rf .build/out` helps.
- The ad-hoc signature changes on every rebuild: macOS asks again for keychain access and for permissions.
- Bubbles are Core Animation layers on a display link, not SwiftUI views: shape, film and motion are in `Views/BubbleCanvas.swift` and `Views/SoapFilm.swift`; SwiftUI draws only the content of a bubble (`Views/BubbleView.swift`), and that content is cached as an image.
- Builds are arm64 only (Apple Silicon); the `Makefile` has no architecture flag.
- `Vendor/` (engine and model) is not in git; Metal crashes inside the sandbox (GGML_ASSERT), so run checks with the model (`scripts/whisper-smoke.sh`) outside the sandbox.
- The repository is public: no personal data, only neutral wording in example tasks.

## Environment

There are no environment variables: provider keys are stored only in the keychain.

## How Autopilot works here

The build is driven by the `/autopilot` skill. Requirements, the spec and the tasks are in `.autopilot/` (local, not in git).
Progress is in `.autopilot/dashboard.html`. A requirement from `manifest.md` can only be dropped by the user. An interrupted build is continued by saying "continue autopilot".

### Editing without Autopilot

A small bug or polish after a build is an ordinary session, with no run.

Read first:
1. `.autopilot/PROGRESS.md`: what is unfinished, known bugs, what was agreed with the user.
2. What was changed after the last build: the first row of the table in "Git history".
3. Only if the change touches them: why things are the way they are is in `docs/adr/`; what the words mean is in `CONTEXT.md`;
   what exactly was asked for is in `manifest.md` in the build folder (named at the top of `PROGRESS.md`).

After the change:
- commit by the rules in "Git history";
- add a line to the "edits without Autopilot" section of `PROGRESS.md` (the Russian heading «Правки без автопилота»): date, what, why;
- remove the fixed item from the "unfinished" or "known bugs" sections;
- if you agreed with the user on something the next build must not revisit, add a line to the "agreed" section, in the user's words.

### Git history

Do not read all of it; take a slice for the question:

| Question | Command |
|---|---|
| what changed after the last build | `git log --oneline "$(git log -1 --format=%h --grep='^Autopilot: сборка сдана')"..HEAD -- . ':(exclude).autopilot'` |
| everything done for a requirement | `git log --oneline --grep="R02"` |
| history of a file | `git log --oneline -10 -- <file>` |
| when code appeared or disappeared | `git log --oneline -S "<fragment>"` |
| why a line is the way it is | `git blame -L <from>,<to> <file>`, then `git show <sha>` |
| what is inside a commit | `git show --stat <sha>` |

If a slice is longer than about 30 commits, hand it to a subagent and take a ten-line summary.

Commit: the title says what (`fix: dates in one format`), the body says why, and the trailer
`--trailer "Requirements: R02"` is added if the change touches a requirement from `manifest.md`.
The title `Autopilot: сборка сдана` ("build delivered") is written only by Autopilot; it is how the last build is found, so the first command above keeps the Russian text.
<!-- autopilot:end -->
