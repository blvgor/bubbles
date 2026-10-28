# Bubbles architecture

A menu bar app for macOS 26+, with no main window and no Dock icon (`LSUIElement`). Swift 6, strict concurrency, built with the Command Line Tools only, no `.xcodeproj`. Decisions and their reasons are in `docs/adr/`, the project's words are in `CONTEXT.md`.

## Two targets

The `Package.swift` package (tools 6.0, platform macOS 26.0) consists of:

| Target | What it is | Depends on |
|---|---|---|
| `BubblesCore` | library: logic without a UI | only Foundation, CoreGraphics, Combine |
| `Bubbles` | executable app: windows, SwiftUI, dictation, keychain | `BubblesCore`, AppKit, SwiftUI, Speech, Security, ServiceManagement |
| `BubblesCoreTests` | core tests on Swift Testing | `BubblesCore` |

### The boundary

- `BubblesCore` has no AppKit and no SwiftUI. Everything that can be checked without a screen lives here and is covered by tests: task models, storage and streak, ranking, the ladder, bubble physics, card and menu rules, the dictation transcript, the "Got it" draft, task parsing (rules, Claude, ChatGPT), settings.
- `Bubbles` holds only what needs the system: windows and layers, views, the microphone and speech recognition, the hotkey, the keychain, launch at login, permissions and "presence" (a call, screen sharing, Focus). The core makes the decisions, the app carries them out.
- The core knows nothing about the app. Everything the app needs from the core is declared `public`; AppKit types must not be pulled into the core for convenience.
- UI and storage types are marked `@MainActor`. Network clients are `Sendable` structs with `async` methods.

## Data flow

```
 dictation / text input
        │  lines (Transcript: a pause > 0.8 s or a separator word = a new line)
        ▼
 DictationFlow ──► ProviderParser ──► Claude or ChatGPT   (a key is set)
        │                 └────────► TaskParser.plain      (no key, or the request failed)
        ▼
 TaskParseResult { tasks, "Unparsed" }
        │
        ▼
 DictationDraft ("Got it"): edit titles, urgency, time, order
        │  "Start the day"
        ▼
 TaskStore.replaceDay ──► state.json (written after every change)
        │
        ▼
 AppModel.rankedTasks ──► PhysicsWorld.sync ──► bubble bodies
        │                                            │ display link frame: step(dt)
        │                                            ▼
        │                                    BubbleCanvas (Core Animation layers)
        ▼
 once a second: LadderScheduler.next ──► surface / takeover
```

1. **Input.** `SpeechRecognizer` (SpeechTranscriber, then DictationTranscriber, then SFSpeechRecognizer; language ru-RU) hands words to the core's `Transcript`. It assembles lines, understands voice commands ("delete the last one", "done") and saves unfinished dictation to `dictation-draft.json` so it can offer to continue. Without a key, text input opens instead of voice.
2. **Parsing.** `ProviderParser` picks the provider from the settings and from whether a key exists. The answer is a `ParseOutcome`: the result, who parsed it, the reason for a refusal. Any failure (no key, network, wrong key, out of credit) turns into "every line is a task as written" (`TaskParser.plain`) with an explanation in the UI. Lines from which the provider made no task go to "Unparsed" and are not lost.
3. **Confirmation.** Nothing appears on the desk until the person presses "Start the day". Until then `DictationDraft` is edited: order, urgency, "until"/"at", long task, merging and splitting lines.
4. **Storage.** `TaskStore` holds the tasks, the count of tasks closed today and the streak, and writes `state.json` atomically after every change; a corrupt or missing file gives an empty state, not a crash. On the day change (`rolloverIfNeeded`) unclosed tasks become "from yesterday", the day counter of long tasks grows, and the streak is counted by the rules in `CONTEXT.md`.
5. **Order and physics.** `AppModel.rankedTasks` is `Ranker` plus the manual order. `PhysicsWorld` receives the ordered ids (`sync`), keeps at most `maxVisible` bubbles on the desk, and the rest wait in "+N". The size depends on the place in the ranking.
6. **Frame.** The desk windows start a display link; `FrameDriver` computes `dt` between the target presentation times of frames, `AppModel.advanceFrame` moves the physics, and `BubbleCanvas` updates positions, paths and a few layer filter values. SwiftUI is not rebuilt within a frame: the bubble's content (pill, title, time) is drawn into an image once, when it changes.
7. **Ladder.** Once a second `AppModel.runLadder` asks `LadderScheduler.next(ranked:settings:now:state:busy:)`. The result is `.surface(id)` or `.takeover(id)`. The sample day (`isSampleDay`) never surfaces and never takes over. If screen sharing, a video call or Focus (`Presence`) is active and the pause is on, nothing new starts; a takeover that is already on screen steps back during a call and returns after it. The ladder state (`LadderState`) is stored separately from the tasks.
8. **Closing.** A task is closed only by `TaskStore.complete(id:proof:)` after the sentence and the hold (`ProofHold`, `HoldToCompleteButton`), or it burns through `burn`, which is available only from the takeover ("Emergency exit") and resets the streak.

### Windows

- Desk: a transparent full-screen window at desktop level (above the icons, below ordinary windows). The microphone and the bubbles live in it. Clicks outside a bubble pass through the window: mouse transparency is switched by hit-testing the bubble body (`DeskHit`).
- Surfacing: a second transparent window above ordinary windows (`.floating`) with one bubble and a toast. Under this bubble's film there is a system blur (`GlassFallback.swift`) so the text is readable over windows.
- Card and "Got it": `PanelWindow` (`NSPanel`, centred, activates the app).
- Takeover: `TakeoverWindow` at `.screenSaver` level, on all Spaces.
- The rest: the settings window (`SettingsWindowController`), "All tasks", the introduction, the day summary.

### The bubble's film

A bubble is a holographic soap bubble (`SoapFilm.swift`): rings go inward from the outline, and their colour along the angle comes from the thickness of the film (thin-film interference, pastel); the band is thicker on one side and almost disappears on the other, all softly blurred. The film image is computed on the CPU and refreshed about 5 times a second with a smooth transition; squashing and rotation are set by the layer transform, and the edge is a vector. The centre is transparent, with a light radial darkening only under the text. The wallpaper is not read, and the "Screen Recording" permission is not needed. The outline is `BlobGeometry` (harmonics 2 to 8). Why it is done this way: [ADR 0007](adr/0007-soap-film-instead-of-glass.md).

## Where things are on disk

| What | Where |
|---|---|
| Tasks, streak, history | `~/Library/Application Support/Bubbles/state.json` |
| Unfinished dictation | `~/Library/Application Support/Bubbles/dictation-draft.json` |
| Settings | `UserDefaults`, key `bubbles.settings` (JSON) |
| Tasks moved to tomorrow, introduction state and other flags | `UserDefaults`, keys with the prefix `bubbles.` |
| Claude and ChatGPT keys | the keychain only, one entry per provider (`APIKeyStore`) |

A key is not written to disk, to `UserDefaults` or to a log, and is not shown back. Network requests go through an ephemeral session with no cache (`ClaudeHTTP.session`). Without a key there are no network requests. "Reset data" deletes the data folder but not the keys. See [ADR 0006](adr/0006-keys-only-in-keychain.md).

## Conventions

- **Language.** All text for people is in English. Dictation input is bilingual: the local parser and the voice commands understand Russian and English keywords, and task titles keep the language they were spoken in. Identifiers, code comments and commit messages are in English. The words from `CONTEXT.md` (bubble, desk, ladder, takeover, proof, burn) are used the same way in the UI and in names.
- **No SwiftUI macros.** `@State`, `@Entry`, `#Preview` do not compile with the Command Line Tools; write `State(initialValue:)`.
- **Tests.** Swift Testing only. A new rule is added to the core with a test in `Tests/BubblesCoreTests/`, not to a view. Time and files are passed into types as parameters (`now:`, `fileURL:`, `defaults:`) so that tests do not touch real data.
- **Neutral examples.** Code, tests and docs use only neutral tasks ("Pay for internet", "Book a dentist appointment"); no personal data.
- **UI spacing.** Scale 4 / 8 / 12 / 16 / 24 / 32 / 40 / 48; inner spacing is smaller than outer spacing; related texts sit in one stack with their own gap.
- **Failure tolerance.** A corrupt file, a missing key, the network, permissions: not a crash but a fallback path and a clear message.
- **Respect for the user's screen.** By default (the "Background only" preset) the app never surfaces and never takes over. Surfacing and takeover are turned on explicitly in the settings.
- **Build.** `make` on top of SwiftPM, or `scripts/direct-build.sh` on `swiftc` for sandboxes where SwiftPM cannot write its database. The code is the same. Packaging the `.app` and the ad-hoc signature are in `scripts/build-app.sh`; the architecture is the host's (only arm64 has been checked).

### Speech recognition

By default it is the built-in Whisper: `whisper.xcframework` (whisper.cpp, MIT) sits in `Contents/Frameworks`, and the model `ggml-large-v3-turbo-q5_0.bin` (MIT) in `Contents/Resources/Models`; both are downloaded by `scripts/fetch-whisper.sh` into `Vendor/` during the build. Recording is 16 kHz mono, `PauseSegmenter` cuts at silence of 0.8 s or more, each segment is recognised in the background (`actor WhisperEngine`) and becomes a line. Other engines: ChatGPT with a key (`OpenAITranscriber`), macOS system recognition, Handy.
