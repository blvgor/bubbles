import AppKit
import BubblesCore
import Combine
import Foundation

/// State of the dictation panel (screens 2–4):
/// "continue?" → listening (pause, interruption banner) → "Edit transcript" → parsing → "Got it".
/// Text mode replaces listening when voice is not possible or the person prefers typing.
/// Parsing goes through the AI whose key is stored (Claude or ChatGPT, `ParserProvider.active`). With no key
/// the panel is a plain tracker: text input only, every line a task as written; on an AI error the lines are
/// also kept as written and a banner says why.
/// The transcript is lines (one future task per line); it is saved every 5 s and offered back next time.
@MainActor final class DictationFlow: ObservableObject {
    enum Stage: Equatable { case resume, listening, review, typing, parsing, confirm }

    @Published private(set) var stage: Stage = .listening
    @Published var typed = ""
    /// "Edit transcript": the lines as editable text.
    @Published var reviewText = ""
    @Published private(set) var hint = ""
    @Published private(set) var paused = false
    /// Lines being parsed (for "Claude is sorting 14 lines…").
    @Published private(set) var parsingCount = 0
    @Published private(set) var draft: DictationDraft
    /// Who parsed the last time (nil: the lines were kept as written).
    @Published private(set) var parsedBy: ParserProvider?
    /// Who was asked the last time (names the provider in the failure banner).
    @Published private(set) var askedProvider: ParserProvider?
    /// Why the AI did not parse the last time although a key is stored (nil: no key, or it parsed).
    @Published private(set) var aiFailure: ClaudeFailure?
    /// No AI key at all when the panel opened: text input only, lines become tasks as written.
    let isPlain: Bool
    /// "Recognition: Handy" (and Handy is installed): the panel is a text field that Handy types into;
    /// the built-in recognizer never starts and no microphone or speech permission is asked.
    let isHandy: Bool
    /// Handy is running (else "Open Handy").
    @Published private(set) var handyRunning = false
    /// A dictation saved earlier and not launched: "Unfinished dictation from 09:12".
    @Published private(set) var savedDraft: TranscriptDraft?

    // "Got it" editor state
    @Published var hoveredID: UUID?
    @Published var hoveredLeftover: UUID?
    @Published var selectedID: UUID?
    @Published private(set) var editing = false
    @Published private(set) var removed: RemovedTask?
    @Published var dropTargetID: UUID?
    @Published private(set) var focusRequests: [UUID: Int] = [:]
    @Published var addFocusRequest = 0
    private(set) var draggingID: UUID?

    let speech = SpeechRecognizer()
    let settings: () -> BubbleSettings

    private let onLaunch: (DictationDraft) -> Void
    private let onToast: (String) -> Void
    private let onOpenSettings: () -> Void
    /// A desk task whose takeover has started: not removed, moved or merged away in "Got it".
    private let isLocked: (UUID) -> Bool
    private var parseTask: Task<Void, Never>?
    private var removedTask: Task<Void, Never>?
    /// Voice failed once this session: "Dictate more" goes straight to typing.
    private var voiceHint: String?
    /// The next parse replaces what the transcript gave (it was edited from "Got it"), instead of appending.
    private var replacesTranscript = false
    private var linesDraft: DictationLinesDraft!
    private var speechWatch: AnyCancellable?
    /// "Stop" was pressed while the phrase engine still recognises the last phrases.
    private var finishing = false
    private var handyWatch: AnyCancellable?

    static let typingHint = "One task per line. You can paste a list from your notes"
    static let reviewHint = "One line is one future task. Enter splits a line, deleting the line break joins them"
    static let plainHint = "Each line becomes a task as written. Connect Claude or ChatGPT to dictate"
    init(existing: [DayTask], order: TaskOrder, settings: @escaping () -> BubbleSettings,
         onLaunch: @escaping (DictationDraft) -> Void, onToast: @escaping (String) -> Void,
         isLocked: @escaping (UUID) -> Bool = { _ in false },
         onOpenSettings: @escaping () -> Void, draftStore: TranscriptDraftStore = TranscriptDraftStore()) {
        let plain = APIKeyStore.activeProvider(selected: settings().provider) == nil
        draft = DictationDraft(existing: existing, order: order, keepsTextAsWritten: plain)
        self.settings = settings
        self.onLaunch = onLaunch
        self.onToast = onToast
        self.isLocked = isLocked
        self.onOpenSettings = onOpenSettings
        isPlain = plain
        // Without a key the macOS recognizer's run-on speech cannot become tasks: every way into the mic leads
        // to typing. The phrase engines (built-in Whisper, cloud) give one line per phrase, which works as is.
        if isPlain, !Self.recordsPhrases(Self.voiceEngine(settings())) { voiceHint = Self.plainHint }
        // Handy types the speech in itself: every way into the mic leads to the field, with its key in the hint.
        isHandy = HandyApp.engine(for: settings()) == .handy
        if isHandy {
            voiceHint = HandyShortcut.hint(binding: HandyApp.binding())
            handyRunning = HandyApp.isRunning
            let center = NSWorkspace.shared.notificationCenter
            handyWatch = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
                .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.handyRunning = HandyApp.isRunning } }
        }
        speech.onFailure = { [weak self] reason in self?.switchToText(reason: reason) }
        speech.onFinishCommand = { [weak self] in self?.finish() }
        speech.onNotice = { [weak self] text in
            guard let self, self.stage == .listening else { return }
            self.hint = text
        }
        linesDraft = DictationLinesDraft(store: draftStore) { [weak self] in self?.linesToSave ?? [] }
        savedDraft = linesDraft.load()
        // Re-publish the recognizer's changes so views reading `liveLines` refresh.
        speechWatch = speech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - Lines

    var separatorWord: String {
        let word = settings().separatorWord.trimmingCharacters(in: .whitespacesAndNewlines)
        return word.isEmpty ? "next" : word
    }

    var showTranscript: Bool { settings().showTranscript }

    /// What the recognizer heard, cut also at the separator word from the settings.
    var liveLines: [String] { DraftText.splitLines(speech.lines, separator: separatorWord) }

    var listeningHint: String {
        "Say “\(separatorWord)” between tasks, “done” to finish, “delete last” to erase a line"
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Lines of the current stage that are not parsed yet.
    private var pendingLines: [String] {
        switch stage {
        case .listening: liveLines
        case .typing: DraftText.splitLines(Self.lines(of: typed), separator: separatorWord)
        case .review: Self.lines(of: reviewText)
        case .resume, .parsing, .confirm: []
        }
    }

    /// Autosaved every 5 s: everything said so far, parsed or not.
    private var linesToSave: [String] {
        if stage == .review, replacesTranscript { return pendingLines }
        return draft.lines + pendingLines
    }

    // MARK: - Listening

    /// Opens the microphone (asking for permissions the first time); a saved dictation is offered first.
    func beginListening() {
        typed = ""
        if savedDraft != nil, draft.lines.isEmpty {
            stage = .resume
            hint = ""
            return
        }
        if let voiceHint { return switchToText(reason: voiceHint) }
        startMicrophone(continuing: false)
    }

    /// "Unfinished dictation from 09:12 — continue?": "Continue".
    func resumeSaved() {
        guard let saved = savedDraft else { return startMicrophone(continuing: false) }
        savedDraft = nil
        speech.setLines(saved.lines)
        if let voiceHint {
            typed = saved.lines.joined(separator: "\n")
            return switchToText(reason: voiceHint)
        }
        startMicrophone(continuing: true)
    }

    /// "Parse" the saved dictation as it is.
    func reviewSaved() {
        guard let saved = savedDraft else { return }
        savedDraft = nil
        reviewText = saved.lines.joined(separator: "\n")
        stage = .review
        hint = Self.reviewHint
    }

    /// "Start over": the saved dictation is thrown away.
    func discardSaved() {
        savedDraft = nil
        linesDraft.clear()
        if let voiceHint { return switchToText(reason: voiceHint) }
        startMicrophone(continuing: false)
    }

    var savedDraftTime: String? {
        savedDraft.map { DayTask.clock(Ranker.minutesSinceMidnight($0.savedAt)) }
    }

    private func startMicrophone(continuing: Bool) {
        stage = .listening
        paused = false
        hint = listeningHint
        linesDraft.startAutosave()
        configureSpeech()
        Task { await speech.start(continuing: continuing) }
    }

    /// "Recognition" from the settings, narrowed to what can work now (model, key, Handy).
    static func voiceEngine(_ settings: BubbleSettings) -> SpeechEngine {
        SpeechEngine.effective(selected: settings.speechEngine, handyInstalled: HandyApp.isInstalled,
                               whisperReady: WhisperModelStore.modelURL != nil, openAIKey: APIKeyStore.hasKey(.openAI))
    }

    /// Whisper and the cloud recognise whole phrases: one phrase = one line.
    static func recordsPhrases(_ engine: SpeechEngine) -> Bool { engine == .whisper || engine == .openAI }

    private func configureSpeech() {
        let current = settings()
        speech.preferred = Self.voiceEngine(current)
        speech.cloudModel = current.transcriptionModel
    }

    /// "Pause" / "Continue": the lines stay; listening resumes on a new line.
    func togglePause() {
        guard stage == .listening, !finishing else { return }
        if paused {
            paused = false
            configureSpeech()
            Task { await speech.start(continuing: true) }
        } else {
            speech.stop()
            paused = true
            linesDraft.saveNow()
        }
    }

    /// The interruption banner's "Continue".
    func continueAfterInterruption() {
        paused = false
        configureSpeech()
        Task { await speech.start(continuing: true) }
    }

    /// "Type instead", or voice is not possible (`reason` says how to enable it).
    func switchToText(reason: String? = nil) {
        if let reason { voiceHint = reason }
        speech.stop()
        if typed.isEmpty {
            switch stage {
            case .review: typed = reviewText
            default: typed = liveLines.joined(separator: "\n")
            }
        }
        stage = .typing
        hint = reason ?? Self.typingHint
    }

    /// "Stop and review", "done", ⌥Space while listening: to "Edit transcript" (or straight to parsing
    /// when the transcript is hidden in the settings). From the review or text mode: "Parse".
    func finish() {
        switch stage {
        case .listening:
            guard !finishing else { return }
            speech.stop()   // keeps the not yet finalised tail
            if speech.pendingSegments > 0 {
                // The last phrases are still being recognised: their lines come in a moment.
                finishing = true
                hint = "Finishing the last phrase…"
                Task { [weak self] in
                    await self?.speech.waitForPendingSegments()
                    guard let self else { return }
                    self.finishing = false
                    if self.stage == .listening { self.finish() }
                }
                return
            }
            let lines = liveLines
            guard !lines.isEmpty else {
                return switchToText(reason: "Didn't hear anything. Check that the right microphone is selected, or type instead")
            }
            linesDraft.saveNow()
            if showTranscript {
                reviewText = lines.joined(separator: "\n")
                stage = .review
                hint = Self.reviewHint
            } else {
                parse(lines)
            }
        case .review, .typing:
            let lines = pendingLines
            guard !lines.isEmpty else {
                hint = stage == .review ? "Nothing here — dictate or type at least one line"
                                        : (isHandy ? voiceHint ?? Self.typingHint : Self.typingHint)
                return
            }
            parse(lines)
        default:
            break
        }
    }

    /// "Keep dictating" from the review: the edited lines stay, new speech goes on a new line.
    func continueDictating() {
        speech.setLines(Self.lines(of: reviewText))
        if let voiceHint { return switchToText(reason: voiceHint) }
        startMicrophone(continuing: true)
    }

    // MARK: - Parsing

    private func parse(_ lines: [String]) {
        linesDraft.saveNow()
        parsingCount = lines.count
        stage = .parsing
        let count = "\(lines.count) \(Plural.en(lines.count, "line"))"
        let current = settings()
        let provider = APIKeyStore.activeProvider(selected: current.provider)
        let missing = APIKeyStore.missingProvider(selected: current.provider)
        let model = provider.map { current.model(for: $0) } ?? ""
        hint = provider.map { "\($0.label) is sorting \(count)…" } ?? "Saving \(count)…"
        parseTask?.cancel()
        parseTask = Task { [weak self] in
            let outcome = await Self.parse(lines, provider: provider, missingKey: missing, model: model)
            guard let self, !Task.isCancelled, self.stage == .parsing else { return }
            if let failure = outcome.failure { self.onToast(failure.message(for: outcome.provider ?? .claude)) }
            self.aiFailure = outcome.failure
            self.askedProvider = outcome.provider
            self.parsedBy = outcome.parsedBy
            if self.replacesTranscript {
                self.draft.retranscribe(outcome.result, lines: lines)
            } else {
                self.draft.absorb(outcome.result, lines: lines)
            }
            self.replacesTranscript = false
            self.speech.setLines([])
            self.stage = .confirm
            self.hint = ""
        }
    }

    /// "Undo" while parsing: back to the transcript.
    func cancelParsing() {
        parseTask?.cancel()
        parseTask = nil
        stage = .review
        hint = Self.reviewHint
        if reviewText.isEmpty { reviewText = (typed.isEmpty ? liveLines : Self.lines(of: typed)).joined(separator: "\n") }
    }

    /// "Dictate more": back to the microphone; what is parsed is added to the list.
    func dictateMore() {
        typed = ""
        reviewText = ""
        speech.setLines([])
        if let voiceHint { return switchToText(reason: voiceHint) }
        startMicrophone(continuing: false)
    }

    /// "Edit transcript" from "Got it" (e.g. nothing was found): the whole transcript, parsed again.
    func editTranscript() {
        reviewText = draft.lines.joined(separator: "\n")
        replacesTranscript = true
        stage = .review
        hint = Self.reviewHint
    }

    /// "Open Handy": launched in the background so the text still lands in this panel.
    func openHandy() {
        HandyApp.open()
    }

    /// "Connect Claude or ChatGPT" / "Change key": the "Dictation & AI" settings.
    func openAISettings() { onOpenSettings() }

    /// The failure banner's button: "Change key" opens the key settings; "Retry" parses the whole
    /// transcript again (as "Edit transcript" does), replacing the lines that were kept as written.
    func runFailureAction() {
        guard let failure = aiFailure else { return }
        guard failure.retries else { return openAISettings() }
        guard stage == .confirm, !draft.lines.isEmpty else { return }
        reviewText = draft.lines.joined(separator: "\n")   // "Undo" while parsing comes back to it
        replacesTranscript = true
        parse(draft.lines)
    }

    // MARK: - "Got it" edits

    var now: Date { Date() }

    func rename(_ id: UUID, _ title: String) { draft.setTitle(title, id: id) }

    func splitAt(_ id: UUID, text: String, offset: Int) {
        draft.setTitle(text, id: id)
        if let other = draft.split(id: id, at: offset, now: now) { focus(other) }
    }

    func split(_ id: UUID) { draft.split(id: id, now: now) }
    func mergeNext(_ id: UUID) {
        let rows = draft.ordered(now: now)
        if let i = rows.firstIndex(where: { $0.id == id }), i + 1 < rows.count, refusesLocked(rows[i + 1].id) { return }
        draft.mergeWithNext(id: id, now: now)
    }
    func setPriority(_ id: UUID, _ priority: Priority) { draft.setPriority(priority, id: id) }
    func setDue(_ id: UUID, _ minutes: Int?, _ kind: DueKind?) { draft.setDue(minutes, kind: kind, id: id) }
    func setLong(_ id: UUID, _ on: Bool) { draft.setLong(on, id: id) }
    func moveToTomorrow(_ id: UUID) {
        guard !refusesLocked(id) else { return }
        draft.moveToTomorrow(id)
    }

    func mergeDuplicate(_ id: UUID) {
        guard !refusesLocked(id) else { return }
        draft.mergeDuplicate(id, now: now)
    }
    func dismissDuplicate(_ id: UUID) { draft.dismissDuplicate(id) }
    func setIncluded(_ id: UUID, _ on: Bool) { draft.setIncluded(on, id: id) }
    func setMode(_ mode: DraftMode) { draft.setMode(mode) }
    func promoteLeftover(_ id: UUID) { draft.promoteLeftover(id, now: now) }
    func dismissLeftover(_ id: UUID) { draft.dismissLeftover(id) }
    func makeTailLong() { draft.makeTailLong(keeping: PhysicsWorld.maxVisible, now: now) }

    func addTask(_ text: String) {
        let ids = draft.addTask(text: text, now: now)
        if let last = ids.last { selectedID = last }
    }

    /// "Delete" / ⌘⌫: the row goes, "Deleted · Undo" stays 5 seconds.
    func remove(_ id: UUID) {
        guard !refusesLocked(id) else { return }
        guard let gone = draft.remove(id: id, now: now) else { return }
        if selectedID == id { selectedID = nil }
        removed = gone
        removedTask?.cancel()
        removedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.removed = nil
        }
    }

    /// A row for a task already on the desk whose takeover has started: "Add to today" keeps it
    /// (in "Replace the day" it is leaving anyway, so there is nothing to refuse). Shows the refusal.
    private func refusesLocked(_ id: UUID) -> Bool {
        guard draft.mode == .addToToday,
              let row = draft.ordered(now: now).first(where: { $0.id == id }),
              TakeoverLock.refuses(onDesk: row.onDesk, canMoveToTomorrow: !isLocked(id)) else { return false }
        onToast(TakeoverLock.refusal)
        return true
    }

    func restoreRemoved() {
        guard let removed else { return }
        draft.restore(removed, now: now)
        self.removed = nil
        removedTask?.cancel()
    }

    func removeSelected() {
        if let selectedID { remove(selectedID) }
    }

    /// ⌘Z.
    func undo() {
        if draft.undo() { removed = nil }
    }

    func setEditing(_ on: Bool) { editing = on }

    /// Return on a selected row: the cursor goes into its title.
    func renameSelected() {
        if let selectedID { focus(selectedID) }
    }

    func focus(_ id: UUID) {
        selectedID = id
        focusRequests[id, default: 0] += 1
    }

    func dragBegan(_ id: UUID) { draggingID = id }

    /// A row dropped on `target`: it takes the target's place in the list and is pinned there.
    func drop(on target: UUID) {
        defer { draggingID = nil }
        guard let dragged = draggingID, dragged != target,
              let index = draft.ordered(now: now).firstIndex(where: { $0.id == target }) else { return }
        draft.move(id: dragged, to: index, now: now)
    }

    /// "Start the day".
    func launch() {
        guard draft.canLaunch(now: now) else { return }
        stop()
        linesDraft.clear()
        onLaunch(draft)
    }

    /// Esc / "Cancel": asks first when there is something to lose (the transcript stays saved anyway).
    func confirmCancel() -> Bool {
        let hasWork = stage == .confirm ? (draft.newCount > 0 || draft.canUndo) : !pendingLines.isEmpty
        guard hasWork else { return true }
        let alert = NSAlert()
        alert.messageText = stage == .confirm ? "Close without starting?" : "Stop dictation?"
        alert.informativeText = "The transcript is saved — you can continue it the next time you open the microphone."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Stay")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The panel closed (Esc, "Cancel", launch).
    func stop() {
        speech.stop()
        speech.discardPendingSegments()
        linesDraft.stopAutosave()
        parseTask?.cancel()
        parseTask = nil
    }

    /// The active provider with its key from the Keychain (read off the main thread), else lines as written.
    /// A stored key the Keychain no longer hands over (an ad-hoc rebuild changes the signature the item
    /// trusts) comes back as `.keyUnreadable`.
    nonisolated private static func parse(_ lines: [String], provider: ParserProvider?, missingKey: ParserProvider?,
                                          model: String) async -> ParseOutcome {
        let key = provider.flatMap { APIKeyStore.load($0) }
        return await ProviderParser.parse(lines: lines, provider: provider, apiKey: key, model: model, missingKey: missingKey)
    }
}
