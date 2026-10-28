import AppKit
import BubblesCore
import Combine
import QuartzCore

/// The app's single source of truth: owns the task store, settings, the physics world (stepped from the
/// overlay windows' display link) and a once-a-second housekeeping timer, and exposes the user intents. T01 builds the skeleton; windows (T03), settings UI (T04),
/// dictation (T05) and the ladder (T06) extend it; T08 adds onboarding, "Day summary", the ladder rules
/// ("15 more minutes", move to tomorrow, pause during calls), the settings window and the global hotkey.
@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()

    let taskStore: TaskStore
    let settingsStore: SettingsStore
    /// Stepped every display frame and read directly by the bubble canvases. Deliberately not published:
    /// republishing it per frame rebuilt every SwiftUI observer 60–120 times a second (story 39).
    var world: PhysicsWorld

    // Ladder state, driven by `LadderScheduler`; persisted (without the standing takeovers, so a takeover
    // interrupted by a crash or a forced quit comes back on the next start).
    private var ladderState = LadderState(lastSurfaceAt: Date())
    var lastSurfaceAt: Date? { ladderState.lastSurfaceAt }
    var snoozedUntil: Date? { ladderState.snoozedUntil }
    var takenOver: Set<UUID> { ladderState.takenOver }
    private let ladder = LadderScheduler()
    /// Tasks moved to tomorrow (off today's desk, back tomorrow as "from yesterday").
    private var shelf = TomorrowShelf()
    /// Why the next ladder step is waiting (screen sharing, a full-screen call, Focus), for the UI.
    private(set) var ladderWaitReason: Presence.Reason?
    /// The tasks "Day summary" is showing, until it is answered or closed.
    private var summaryPending: (tasks: [DayTask], evening: Bool)?
    /// "Day summary is ready" in the menu: set instead of a window while the ladder is off.
    let summaryOffer = SummaryOffer()
    /// The global shortcut could not be registered (taken by another app).
    private(set) var hotkeyError: String?
    private var hotkeyWatch: AnyCancellable?

    /// "All tasks ⌘L" and "Add task…" in the menu: set by `start()` to the "All tasks" window.
    var allTasksHandler: (() -> Void)?
    var addTaskHandler: (() -> Void)?

    // Editing (T07): manual order on top of the rank, the desk as an editable list with ⌘Z, the card's
    // history per task, per-task "Snooze", and the bubbles' hover / drag / context menu.
    let editing = DeskEditing()
    private(set) var taskOrder = TaskOrder()
    private var trails: [UUID: TaskTrail] = [:]
    private var snoozes: [UUID: Date] = [:]
    private var storeWatch: AnyCancellable?
    private var hover: [DeskLayer: UUID] = [:]
    private var drag: BubbleDrag?
    /// "Can't catch me": the cursor as of the last frame, for its speed.
    private var lastCursor: CursorState?
    private var gestures: BubbleGestures?
    private var outsideClickMonitor: Any?
    /// Clicks past the surfaced bubble (see `startSurfaceClickMonitors`).
    private var surfaceClickMonitors: [Any] = []
    /// Stands for the "+N" bubble in `DeskTarget.bubble` (the window then takes the click; `BubbleGestures`
    /// opens "All tasks").
    static let overflowTargetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000F0")!
    /// The open dictation panel, if any.
    private var dictation: DictationFlow?

    /// Toast at the bottom centre (float window), its frame for click-through, and closing pops.
    @Published private(set) var toast: ToastMessage?
    @Published private(set) var pops: [PopEffect] = []
    @Published private(set) var micHovered = false
    var toastFrame: CGRect = .zero

    private var overlays: OverlayWindows?
    private var toastTask: Task<Void, Never>?
    private var detailID: UUID?
    private let defaults: UserDefaults

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settingsWatch: AnyCancellable?

    init(taskStore: TaskStore = TaskStore(), settingsStore: SettingsStore = SettingsStore(),
         defaults: UserDefaults = .standard) {
        self.taskStore = taskStore
        self.settingsStore = settingsStore
        self.defaults = defaults
        world = PhysicsWorld(bounds: Self.visibleBounds())
    }

    /// Ranked tasks for lists, the detail card "# of N", the bubbles and the ladder: the manual order
    /// (rows dragged in "Got it" / "All tasks") on top of `Ranker`.
    var rankedTasks: [DayTask] { taskOrder.apply(taskStore.tasks) }

    /// Called once from `AppDelegate.applicationDidFinishLaunching`.
    func start() {
        loadLadder()
        loadEditing()
        taskStore.rolloverIfNeeded()
        keepSampleDayFresh()
        returnShelvedTasks()
        settingsStore.expireHiddenIfNeeded()
        seedSampleDayIfNeeded()
        ladderState.lastSurfaceAt = Date()
        world.bounds = Self.visibleBounds()
        syncWorld(spawnFrom: nil)

        let overlays = OverlayWindows(model: self)
        overlays.setDeskVisible(settingsStore.settings.hidden == .visible)
        overlays.show()
        self.overlays = overlays
        // "Hide bubbles" / "Show": the desk window (bubbles and the mic) leaves and comes back at once.
        settingsWatch = settingsStore.$settings
            .map { $0.hidden == .visible }
            .removeDuplicates()
            .sink { [weak self] visible in self?.overlays?.setDeskVisible(visible) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        })
        // Waking from sleep: a missed day change and a deadline that passed while asleep are handled at once.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dayChanged() }
        })
        // The built-in Whisper's model must be freed before exit: ggml's Metal backend aborts otherwise.
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            WhisperEngine.shared.shutdownNow()
        })
        overlays.startFrames { [weak self] dt in self?.advanceFrame(dt) }
        startEditing()
        startHotkey()
        startTimer()
        if !defaults.bool(forKey: Self.onboardingDoneKey) { showOnboarding() }
    }

    // MARK: - Intents

    /// Opens the task card: proof phrase + the hold ("Hold the button", 1…30 s). Clicking elsewhere closes it.
    /// Editing happens in the card (title, urgency, time, put off, move, burn), so it stays open while its
    /// menus and the time popover are used; a click outside the app closes it.
    func openDetail(_ id: UUID) {
        guard taskStore.tasks.contains(where: { $0.id == id }) else { return }
        let card = DetailCard(model: self, store: taskStore, id: id,
                              onDone: { [weak self] proof in self?.complete(id, proof: proof) },
                              onClose: { PanelWindow.shared.dismiss() })
        PanelWindow.shared.present(card, closesOnResign: false) { [weak self] in
            if self?.detailID == id { self?.detailID = nil }
            self?.stopOutsideClickMonitor()
        }
        detailID = id   // after present: replacing a card runs the previous card's onDismiss first
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.detailID != nil { PanelWindow.shared.dismiss() }
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }

    /// Proof phrase + hold done: the bubble pops, the next one grows.
    /// This (and `burn` from the takeover) is the only way a bubble leaves the desk.
    func complete(_ id: UUID, proof: String) {
        if detailID == id { PanelWindow.shared.dismiss() }
        let task = taskStore.tasks.first { $0.id == id }
        if let task, let body = world.bodies.first(where: { $0.id == id }), !body.isWaiting,
           settingsStore.settings.animation, settingsStore.settings.hidden == .visible {
            addPop(PopEffect(task: task, body: body, layer: body.surfaced ? .float : .desk))
        }
        taskStore.complete(id: id, proof: proof)
        ladderState.forget(id)
        saveLadder()
        syncWorld(spawnFrom: nil)
        guard task != nil else { return }
        if let next = rankedTasks.first {
            showToast("Done. Next: “\(next.title)”")
        } else {
            showToast("All of today's tasks are done")
        }
    }

    /// "Burn and exit" from the takeover: the task is gone, the streak resets.
    func burn(_ id: UUID) {
        taskStore.burn(id: id)
        ladderState.forget(id)
        saveLadder()
        syncWorld(spawnFrom: nil)
    }

    /// "Move to tomorrow": allowed until the task's takeover starts, and then the streak is safe —
    /// the task leaves today's desk and comes back tomorrow "from yesterday". Returns false (with a toast) once
    /// the takeover has started: then it can only be closed or burned.
    @discardableResult func moveToTomorrow(_ id: UUID) -> Bool {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return false }
        guard canMoveToTomorrow(id) else {
            refuseLocked(id)
            return false
        }
        if detailID == id { PanelWindow.shared.dismiss() }
        shelve([task])
        showToast("“\(task.title)” moved to tomorrow. Your streak is safe")
        return true
    }

    /// Whether "Move to tomorrow" is still free for this task (for menus and the card).
    func canMoveToTomorrow(_ id: UUID) -> Bool {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return false }
        return ladder.canMoveToTomorrow(task, settings: settingsStore.settings, now: Date(), state: ladderState)
    }

    /// "Add task…" in the menu (`addTaskHandler`: "All tasks" with the cursor in the add field).
    func openAddTask() {
        if let addTaskHandler { addTaskHandler() } else { startDictation() }
    }

    /// "All tasks ⌘L" in the menu (T07 sets `allTasksHandler`).
    func openAllTasks() {
        if let allTasksHandler { allTasksHandler() } else { showToast("The All tasks window comes in the next build") }
    }

    /// "Settings…".
    func openSettings(tab: SettingsTab = .ladder) {
        SettingsWindowController.shared.show(model: self, tab: tab)
    }

    /// Mic button / "Dictate tasks": the dictation panel (listening → "Got it").
    /// The example day is not offered in "Carried over and long"; launching replaces it.
    func startDictation() {
        beginDictation(checkPermissions: true)
    }

    /// ⌥Space (or the shortcut from settings): starts dictation from any app; pressed while listening, it
    /// stops and goes on to "Got it".
    func hotkeyPressed() {
        if let dictation, PanelWindow.shared.isPresented {
            if dictation.stage == .listening { dictation.finish() } else { NSApp.activate() }
            return
        }
        // Onboarding, "Day summary" or a task card is open: bring it forward instead of replacing it.
        if PanelWindow.shared.isPresented {
            NSApp.activate()
            return
        }
        startDictation()
    }

    /// `checkPermissions`: a microphone or speech permission revoked since the last dictation opens
    /// onboarding step 2 instead (once).
    private func beginDictation(checkPermissions: Bool) {
        guard !TakeoverWindow.shared.isPresented else { return }
        if dictation != nil, PanelWindow.shared.isPresented { return }
        // Without an AI key the panel is text only, with Handy the speech is Handy's, and the built-in Whisper
        // and the cloud ask only for the microphone themselves: this check is for the macOS recognizer.
        if checkPermissions, !isPlainTracker, DictationFlow.voiceEngine(settingsStore.settings) == .system,
           PermissionCenter.shared.dictationAccessWasRevoked() {
            showOnboarding(onlyPermissions: true)
            return
        }
        let samples = sampleTaskIDs
        let flow = DictationFlow(
            existing: taskStore.tasks.filter { !samples.contains($0.id) }, order: taskOrder,
            settings: { [weak self] in self?.settingsStore.settings ?? BubbleSettings() },
            onLaunch: { [weak self] draft in
                PanelWindow.shared.dismiss()
                self?.launchDraft(draft)
            },
            onToast: { [weak self] text in self?.showToast(text) },
            isLocked: { [weak self] id in self?.isLockedByTakeover(id) ?? false },
            onOpenSettings: { [weak self] in
                // The transcript is saved; reopening the mic offers it back ("continue?").
                PanelWindow.shared.dismiss()
                self?.openSettings(tab: .dictation)
            })
        dictation = flow
        PanelWindow.shared.present(DictationFlowView(flow: flow, onCancel: { PanelWindow.shared.dismiss() }),
                                   closesOnResign: false) { [weak self, weak flow] in
            flow?.stop()
            if self?.dictation === flow { self?.dictation = nil }
        }
        flow.beginListening()
    }

    /// No Claude or ChatGPT key: the plain tracker (tasks are typed, each line kept as written).
    var isPlainTracker: Bool { APIKeyStore.activeProvider(selected: settingsStore.settings.provider) == nil }

    /// "Looks good, launch": the confirmed list becomes the day; bubbles fly out of the mic.
    func launchDay(_ tasks: [DayTask]) {
        taskOrder = TaskOrder()
        saveOrder()
        taskStore.replaceDay(with: tasks)
        ladderState = LadderState(lastSurfaceAt: Date())
        saveLadder()
        if settingsStore.settings.hidden != .visible { settingsStore.settings.hidden = .visible }
        world = PhysicsWorld(bounds: Self.visibleBounds())
        syncWorld(spawnFrom: micCenter)
        guard let top = rankedTasks.first else { return }
        let count = taskStore.tasks.count
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            self?.showToast("\(count) \(Plural.en(count, "bubble")) for today. Top: “\(top.title)”")
        }
    }

    /// Ladder step "surfacing": the bubble rises above windows and heads to the centre, with a toast
    /// "In 15 min" / "In 1 hour" (sinks back, snoozed) / "Open" (the card). A click past the bubble
    /// and the toast sends it back to the desk with the short snooze.
    func surface(_ id: UUID) {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return }
        world.setSurfaced(id)
        ladderState.lastSurfaceAt = Date()
        ladderState.snoozedUntil = nil
        trails[id, default: TaskTrail()].surfaced += 1
        saveTrails()
        let minutes = settingsStore.settings.surfaceEveryMinutes ?? 45
        let snoozes = SurfaceSnooze.allCases.map { choice in
            ToastAction(label: choice.label) { [weak self] in self?.sendSurfacedBack(id, choice) }
        }
        showToast("\(minutes) \(Plural.en(minutes, "minute")) have passed and “\(task.title)” is still hanging",
                  actions: snoozes + [
            // The click monitors stay on: a click past the card closes it and sends the bubble back too.
            ToastAction(label: "Open", primary: true) { [weak self] in self?.openDetail(id) },
        ], duration: nil)
        startSurfaceClickMonitors(id)
    }

    /// "In 15 min" / "In 1 hour" / a click past: back under the windows, "Back at HH:MM".
    private func sendSurfacedBack(_ id: UUID, _ choice: SurfaceSnooze) {
        snoozeSurface(choice)
        trails[id, default: TaskTrail()].snoozedMinutes.append(choice.minutes)
        saveTrails()
        let back = DayTask.clock(Ranker.minutesSinceMidnight(choice.until(Date())))
        showToast("Back at \(back)")
    }

    /// The bubble sinks back under the windows and the ladder waits `choice` before surfacing again.
    func snoozeSurface(_ choice: SurfaceSnooze = .quarter) {
        stopSurfaceClickMonitors()
        world.setSurfaced(nil)
        ladderState.snoozedUntil = choice.until(Date())
        ladderState.lastSurfaceAt = Date()
    }

    /// Watches clicks while a bubble is surfaced: anywhere but the surfaced bubble and the toast (another
    /// app, the desktop, the desk layer) sends it back. Clicks on the bubble or the toast go on as usual.
    private func startSurfaceClickMonitors(_ id: UUID) {
        stopSurfaceClickMonitors()
        let isPast: @MainActor (NSEvent) -> Bool = { [weak self] event in
            guard let self, self.world.bodies.contains(where: { $0.id == id && $0.surfaced }) else { return false }
            guard let root = event.window?.contentView as? OverlayRootView else {
                // Our own panels and menus (the card, settings) are not «past the bubble».
                return event.window == nil
            }
            guard root.deskLayer == .float else { return true }
            let point = root.convert(event.locationInWindow, from: nil)
            if case .bubble(id)? = self.target(at: point, layer: .float) { return false }
            let flipped = CGPoint(x: point.x, y: root.bounds.height - point.y)
            return !self.toastFrame.insetBy(dx: -4, dy: -4).contains(flipped)
        }
        let handle: @MainActor (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            guard self.world.bodies.contains(where: { $0.id == id && $0.surfaced }) else {
                return self.stopSurfaceClickMonitors()
            }
            guard isPast(event) else { return }
            self.hideToast()
            self.sendSurfacedBack(id, .outsideClick)
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handle(event) }
        }) { surfaceClickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { handle(event) }
            return event
        }) { surfaceClickMonitors.append(local) }
    }

    private func stopSurfaceClickMonitors() {
        surfaceClickMonitors.forEach(NSEvent.removeMonitor)
        surfaceClickMonitors = []
    }

    /// Ladder step "takeover": the task covers the whole screen until it is closed with proof + hold
    /// or burned; "15 more minutes" once per task lifts it for 15 minutes.
    func takeover(_ id: UUID) {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return }
        ladderState.takenOver.insert(id)
        if detailID != nil { PanelWindow.shared.dismiss() }
        hideToast()
        let endOfDay = settingsStore.settings.endOfDayMinutes
        let deadline = ladder.effectiveDeadline(task, endOfDay: endOfDay).map {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double($0) * 60)
        }
        TakeoverWindow.shared.present(task: task, deadline: deadline, onDone: { [weak self] proof in
            TakeoverWindow.shared.dismiss()
            self?.complete(id, proof: proof)
        }, onBurn: { [weak self] in
            TakeoverWindow.shared.dismiss()
            self?.burn(id)
            self?.showToast("Task burned. Streak reset")
        }, onExtend: ladder.canExtend(id, settings: settingsStore.settings, state: ladderState) ? { [weak self] in
            self?.extendTakeover(id)
        } : nil)
    }

    /// "15 more minutes": the takeover leaves and comes back in 15 minutes; a task gets this once.
    func extendTakeover(_ id: UUID) {
        guard let until = ladder.extend(id, settings: settingsStore.settings, now: Date(), state: &ladderState) else { return }
        saveLadder()
        TakeoverWindow.shared.dismiss()
        showToast("Back at \(DayTask.clock(Ranker.minutesSinceMidnight(until))). It can't be extended again")
    }

    /// Once a second: asks `LadderScheduler` for the next step. The example day never surfaces or takes over;
    /// nothing new starts while a takeover is on screen; surfacing waits while a panel is open; "Can't catch me"
    /// never takes the screen over.
    /// While screen sharing, a full-screen call or Focus is on (and "pause" is enabled), nothing new starts,
    /// and a takeover already on screen steps aside when sharing or a call begins; it all comes right after.
    private func runLadder(now: Date = Date()) {
        let settings = settingsStore.settings
        if let shown = TakeoverWindow.shared.taskID {
            guard taskStore.tasks.contains(where: { $0.id == shown }) else {
                TakeoverWindow.shared.dismiss()
                return
            }
            // "Can't catch me" switched on: the takeover steps aside and comes back once it is off.
            if settings.fleeMode {
                TakeoverWindow.shared.dismiss()
                ladderState.takenOver.remove(shown)
                return
            }
            if settings.pauseDuringCalls, let reason = Presence.shared.reason(now: now), reason != .focus {
                TakeoverWindow.shared.dismiss()
                ladderState.takenOver.remove(shown)
                ladderWaitReason = reason
            }
            return
        }
        let samples = sampleTaskIDs
        let ranked = rankedTasks.filter { !samples.contains($0.id) }
        guard !ranked.isEmpty,
              ladder.next(ranked: ranked, settings: settings, now: now, state: ladderState) != nil else {
            ladderWaitReason = nil
            return
        }
        // Something is due: only now look at the screen (window list, microphone, Focus).
        let reason = settings.pauseDuringCalls ? Presence.shared.reason(now: now) : nil
        ladderWaitReason = reason
        switch ladder.next(ranked: ranked, settings: settings, now: now, state: ladderState, busy: reason != nil) {
        case .takeover(let id)?:
            guard !settings.fleeMode else { break }   // "Can't catch me": the screen is never taken over
            takeover(id)
        case .surface(let id)?:
            guard !PanelWindow.shared.isPresented else { break }
            // A task put off with "Snooze" does not surface; the next one does (takeovers are not affected).
            let snoozed = activeSnoozes(now: now)
            if !snoozed.contains(id) {
                surface(id)
            } else if case .surface(let other)? = ladder.next(ranked: ranked.filter { !snoozed.contains($0.id) },
                                                             settings: settings, now: now, state: ladderState,
                                                             busy: reason != nil) {
                surface(other)
            }
        case nil:
            break
        }
    }

    // MARK: - Toast

    /// Shows the toast above the mic; `duration` nil keeps it until an action or the next toast.
    func showToast(_ text: String, actions: [ToastAction] = [], duration: TimeInterval? = 3.8) {
        toastTask?.cancel()
        toast = ToastMessage(text: text, actions: actions)
        guard let duration else { return }
        let id = toast?.id
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self?.toast?.id == id else { return }
            self?.hideToast()
        }
    }

    func hideToast() {
        toastTask?.cancel()
        toast = nil
        toastFrame = .zero
    }

    func runToastAction(_ action: ToastAction) {
        hideToast()
        action.run()
    }

    // MARK: - Desk input

    /// What a click at `point` (window coordinates, bottom-left origin) would hit in `layer`.
    func target(at point: CGPoint, layer: DeskLayer) -> DeskTarget? {
        let settings = settingsStore.settings
        let micShown = layer == .desk && settings.micOnDesk && settings.hidden == .visible
        // "Can't catch me": the bubbles are not hit at all, so clicks, right clicks, drags and hover pass them by.
        if let hit = DeskHit.target(at: point, world: world, layer: layer, mic: micShown ? micCenter : nil,
                                    bubblesHidden: !settings.bubblesTakeInput) {
            return hit
        }
        if layer == .desk, settings.hidden == .visible, world.overflowCount > 0,
           hypot(point.x - world.overflowPoint.x, point.y - world.overflowPoint.y) <= world.overflowRadius {
            return .bubble(Self.overflowTargetID)
        }
        return nil
    }

    func activate(_ target: DeskTarget) {
        switch target {
        case .bubble(Self.overflowTargetID): openAllTasks()
        case .bubble(let id): openDetail(id)
        case .mic: startDictation()
        }
    }

    func setMicHovered(_ on: Bool) {
        if micHovered != on { micHovered = on }
    }

    private func addPop(_ pop: PopEffect) {
        pops.append(pop)
        let id = pop.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.pops.removeAll { $0.id == id }
        }
    }

    // MARK: - Sample day

    private static let sampleSeededKey = "bubbles.sampleDay.seeded"
    private static let sampleIDsKey = "bubbles.sampleDay.ids"

    /// IDs of the first-launch example tasks.
    var sampleTaskIDs: Set<UUID> {
        Set((defaults.stringArray(forKey: Self.sampleIDsKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    /// The desk still shows the example day (menu: "Sample day — dictate your own"). The ladder should leave it alone.
    var isSampleDay: Bool {
        let ids = sampleTaskIDs
        return !taskStore.tasks.isEmpty && taskStore.tasks.allSatisfy { ids.contains($0.id) }
    }

    /// First launch with an empty day: put the neutral example on the desk, once.
    private func seedSampleDayIfNeeded() {
        guard taskStore.tasks.isEmpty, !defaults.bool(forKey: Self.sampleSeededKey) else { return }
        let sample = SampleDay.tasks()
        taskStore.replaceDay(with: sample)
        defaults.set(sample.map(\.id.uuidString), forKey: Self.sampleIDsKey)
        defaults.set(true, forKey: Self.sampleSeededKey)
    }

    /// The example day is not "from yesterday" after midnight: rollover would mark it carried over; undo that.
    private func keepSampleDayFresh() {
        guard isSampleDay, taskStore.tasks.contains(where: { $0.kind != .today || $0.note != nil }) else { return }
        taskStore.replaceDay(with: taskStore.tasks.map { task in
            var t = task
            t.kind = .today
            t.note = nil
            return t
        })
    }

    // MARK: - Geometry

    /// Bottom edge of the toast: 16 pt above the mic circle (prototype: 104 from the bottom).
    var toastBottom: CGFloat { micCenter.y + DeskHit.micRadius + 16 }

    /// Centre of the 64-pt mic circle, bottom centre above the Dock, in overlay-window coordinates.
    var micCenter: CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: world.bounds.midX, y: world.bounds.minY + 56) }
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        return CGPoint(x: visible.midX, y: visible.minY + 24 + 32)
    }

    /// The main screen's visible frame inset by 8, in overlay-window coordinates (window = screen frame).
    static func visibleBounds() -> CGRect {
        guard let screen = NSScreen.main else { return CGRect(x: 8, y: 8, width: 1264, height: 784) }
        return screen.visibleFrame
            .offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
            .insetBy(dx: 8, dy: 8)
    }

    // MARK: - Frame loop

    private func syncWorld(spawnFrom: CGPoint?) {
        world.sync(ranked: rankedTasks.map(\.id), spawnFrom: spawnFrom)
    }

    /// Once a second: hidden-until expiry, the ladder and the day summary.
    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.housekeeping() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func housekeeping() {
        settingsStore.expireHiddenIfNeeded()
        runLadder()
        checkDaySummary()
    }

    /// One display frame: advances the physics by `dt` seconds; the overlay windows then draw it.
    func advanceFrame(_ dt: Double) {
        let s = settingsStore.settings
        guard !world.bodies.isEmpty, s.hidden == .visible else { return }
        world.keepOut = s.micOnDesk ? KeepOutZone(center: micCenter, radius: DeskHit.micRadius) : nil
        world.roundness = s.roundness
        if s.fleeMode {
            drag = nil
            world.cursor = cursorState(dt: dt)
        } else {
            world.cursor = nil
            lastCursor = nil
        }
        // Fleeing needs moving bodies, so "Can't catch me" keeps them simulated even with "Animation" off.
        world.step(dt: dt, speed: s.speed / 100, animate: s.animation || s.fleeMode, rotate: s.rotation)
        // A bubble held by the mouse follows it; a hovered one slows down.
        if let drag, let i = world.bodies.firstIndex(where: { $0.id == drag.id }) {
            world.bodies[i].position = drag.point
            world.bodies[i].velocity = .zero
        } else if let id = hoveredBubble, let i = world.bodies.firstIndex(where: { $0.id == id }) {
            let keep = pow(0.05, dt)
            world.bodies[i].velocity.dx *= keep
            world.bodies[i].velocity.dy *= keep
        }
    }

    /// The mouse in desk-window coordinates and its velocity from the last frame (lightly smoothed).
    private func cursorState(dt: Double) -> CursorState {
        let mouse = NSEvent.mouseLocation
        let origin = NSScreen.main?.frame.origin ?? .zero
        let point = CGPoint(x: mouse.x - origin.x, y: mouse.y - origin.y)
        var velocity = CGVector.zero
        if let last = lastCursor, dt > 0 {
            let raw = CGVector(dx: (point.x - last.position.x) / dt, dy: (point.y - last.position.y) / dt)
            velocity = CGVector(dx: last.velocity.dx + (raw.dx - last.velocity.dx) * 0.5,
                                dy: last.velocity.dy + (raw.dy - last.velocity.dy) * 0.5)
        }
        let state = CursorState(position: point, velocity: velocity)
        lastCursor = state
        return state
    }

    private func dayChanged() {
        summaryOffer.evening = nil   // yesterday's tasks have carried over by now
        taskStore.rolloverIfNeeded()
        keepSampleDayFresh()
        returnShelvedTasks()
        syncWorld(spawnFrom: nil)
    }

    private func screenChanged() {
        overlays?.screenChanged()
        world.bounds = Self.visibleBounds()
        syncWorld(spawnFrom: nil)   // re-anchors existing bodies to the new layout
    }

    // MARK: - Onboarding (T08)

    private static let onboardingDoneKey = "bubbles.onboarding.done"

    /// First launch, "Show the intro", or (`onlyPermissions`) step 2 alone after a revoked permission.
    func showOnboarding(onlyPermissions: Bool = false) {
        SettingsWindowController.shared.close()
        PermissionCenter.shared.refresh()
        let view = OnboardingView(model: self, store: settingsStore, permissions: PermissionCenter.shared,
                                  onlyPermissions: onlyPermissions) { [weak self] how in
            guard let self else { return }
            self.defaults.set(true, forKey: Self.onboardingDoneKey)
            PanelWindow.shared.dismiss()
            switch how {
            case .dictate: self.beginDictation(checkPermissions: false)
            case .sample: self.showSampleDay()
            case .closed: break
            }
        }
        PanelWindow.shared.present(view, closesOnResign: false) { [weak self] in
            self?.defaults.set(true, forKey: Self.onboardingDoneKey)
        }
    }

    /// "See an example": the neutral example day, when the desk is empty.
    private func showSampleDay() {
        guard taskStore.tasks.isEmpty else { return }
        let sample = SampleDay.tasks()
        taskStore.replaceDay(with: sample)
        defaults.set(sample.map(\.id.uuidString), forKey: Self.sampleIDsKey)
        defaults.set(true, forKey: Self.sampleSeededKey)
        world = PhysicsWorld(bounds: Self.visibleBounds())
        syncWorld(spawnFrom: micCenter)
    }

    // MARK: - Global hotkey (T08)

    private func startHotkey() {
        HotkeyCenter.shared.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeyWatch = settingsStore.$settings
            .map(\.hotkey)
            .removeDuplicates()
            .sink { [weak self] hotkey in
                guard HotkeyCenter.shared.current != hotkey else { return }
                self?.registerHotkey(hotkey)
            }
    }

    @discardableResult private func registerHotkey(_ hotkey: GlobalHotkey?) -> Bool {
        do {
            try HotkeyCenter.shared.register(hotkey)
            hotkeyError = nil
            return true
        } catch {
            hotkeyError = hotkey.map { "\($0.display) is taken by another app — pick a different shortcut" }
            return false
        }
    }

    /// The settings recorder: tries `hotkey`; if it cannot be registered, the previous one stays.
    /// Returns the error text, or nil on success.
    func setHotkey(_ hotkey: GlobalHotkey?) -> String? {
        let previous = settingsStore.settings.hotkey
        guard registerHotkey(hotkey) else {
            let message = hotkeyError
            registerHotkey(previous)
            return message
        }
        settingsStore.settings.hotkey = hotkey
        return nil
    }

    // MARK: - Ladder persistence and "move to tomorrow" (T08)

    private static let ladderKey = "bubbles.ladder"
    private static let shelfKey = "bubbles.tomorrow"

    private func loadLadder() {
        if let data = defaults.data(forKey: Self.ladderKey),
           var stored = try? JSONDecoder().decode(LadderState.self, from: data) {
            stored.takenOver = []   // a takeover cut short by a crash or a forced quit comes back
            stored.lastSurfaceAt = Date()
            ladderState = stored
        }
        if let data = defaults.data(forKey: Self.shelfKey),
           let stored = try? JSONDecoder().decode(TomorrowShelf.self, from: data) {
            shelf = stored
        }
    }

    private func saveLadder() {
        var kept = ladderState
        kept.extendedUntil = kept.extendedUntil.filter { id, _ in taskStore.tasks.contains { $0.id == id } }
        if let data = try? JSONEncoder().encode(kept) { defaults.set(data, forKey: Self.ladderKey) }
    }

    private func saveShelf() {
        if let data = try? JSONEncoder().encode(shelf) { defaults.set(data, forKey: Self.shelfKey) }
    }

    /// Takes `tasks` off today's desk onto the shelf for tomorrow; the streak is not touched.
    private func shelve(_ tasks: [DayTask]) {
        guard !tasks.isEmpty else { return }
        let ids = Set(tasks.map(\.id))
        for task in tasks {
            shelf.put(task, now: Date())
            ladderState.forget(task.id)
        }
        saveShelf()
        saveLadder()
        taskStore.replaceDay(with: taskStore.tasks.filter { !ids.contains($0.id) })
        world.setSurfaced(nil)
        syncWorld(spawnFrom: nil)
    }

    /// A new day: tasks moved to tomorrow join it as "from yesterday".
    private func returnShelvedTasks() {
        let back = shelf.takeDue(now: Date())
        guard !back.isEmpty else { return }
        saveShelf()
        taskStore.add(back)
    }

    // MARK: - "Day summary" (T08)

    private static let summaryDayKey = "bubbles.summary.shownDay"

    private var realTasks: [DayTask] {
        let samples = sampleTaskIDs
        return rankedTasks.filter { !samples.contains($0.id) }
    }

    /// At "End of day", or on the first start of a later day if that evening passed unseen.
    /// With the ladder on it waits while a takeover or another panel is on screen, then opens the window.
    /// On "Background only" no window opens at all: the day is marked as shown, `summaryOffer` makes the menu say
    /// "Day summary is ready", and the open tasks carry over by themselves at the day change (as after a closed panel).
    private func checkDaySummary(now: Date = Date()) {
        guard summaryPending == nil else { return }
        let opensItself = DaySummaryRule.opensItself(settingsStore.settings)
        if opensItself, PanelWindow.shared.isPresented || TakeoverWindow.shared.isPresented { return }
        let shown = defaults.object(forKey: Self.summaryDayKey) as? Date
        let open = realTasks
        let evening: Bool
        if DaySummaryRule.eveningDue(now: now, endOfDayMinutes: settingsStore.settings.endOfDayMinutes,
                                     shownDay: shown, hasOpenTasks: !open.isEmpty) {
            evening = true
        } else if DaySummaryRule.morningDue(now: now, shownDay: shown,
                                            hasCarriedTasks: open.contains { $0.kind == .carry }) {
            evening = false
        } else {
            return
        }
        if opensItself {
            showDaySummary(evening ? open : open.filter { $0.kind != .today }, evening: evening, now: now)
        } else {
            defaults.set(summaryDay(evening: evening, now: now), forKey: Self.summaryDayKey)
            summaryOffer.evening = evening
        }
    }

    /// The menu's "Day summary…" (shown after "Day summary is ready"): opens the summary the person has not seen yet.
    func openDaySummary(now: Date = Date()) {
        guard summaryPending == nil, let evening = summaryOffer.evening else { return }
        summaryOffer.evening = nil
        let open = realTasks
        let tasks = evening ? open : open.filter { $0.kind != .today }
        guard !tasks.isEmpty else {
            showToast("All tasks are already in place")
            return
        }
        showDaySummary(tasks, evening: evening, now: now)
    }

    private func summaryDay(evening: Bool, now: Date) -> Date {
        let today = Calendar.current.startOfDay(for: now)
        return evening ? today : (Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today)
    }

    private func showDaySummary(_ tasks: [DayTask], evening: Bool, now: Date) {
        let calendar = Calendar.current
        let day = summaryDay(evening: evening, now: now)
        defaults.set(day, forKey: Self.summaryDayKey)
        let closed = taskStore.history.filter { calendar.isDate($0.completedAt, inSameDayAs: day) }.count
        summaryPending = (tasks, evening)
        let view = DaySummaryView(
            title: evening ? "Day summary" : "Yesterday's summary", closed: closed, streak: taskStore.streak, tasks: tasks,
            onDone: { [weak self] choices in self?.finishDaySummary(choices) },
            onClose: { [weak self] in self?.finishDaySummary([:]) })
        PanelWindow.shared.present(view, closesOnResign: false) { [weak self] in
            self?.finishDaySummary([:])   // closed without looking: everything carries over
        }
    }

    /// Applies the decisions (missing ones mean "tomorrow") and closes the panel.
    private func finishDaySummary(_ choices: [UUID: DaySummaryChoice]) {
        guard let pending = summaryPending else { return }
        summaryPending = nil
        PanelWindow.shared.dismiss()
        var carried: [DayTask] = []
        var burned = 0
        for task in pending.tasks where taskStore.tasks.contains(where: { $0.id == task.id }) {
            switch choices[task.id] ?? (task.kind == .long ? .long : .carry) {
            case .burn:
                burn(task.id)
                burned += 1
            case .long:
                guard task.kind != .long else { continue }
                var long = task
                long.kind = .long
                long.note = TaskStore.longNote(day: pending.evening ? 1 : 2)
                taskStore.update(long)
            case .carry:
                if pending.evening {
                    carried.append(task)
                } else if task.kind == .long {
                    var carry = task
                    carry.kind = .carry
                    carry.note = TaskStore.carryNote
                    taskStore.update(carry)
                }
            }
        }
        shelve(carried)
        syncWorld(spawnFrom: nil)
        if burned > 0 {
            showToast("Summary saved. \(burned) burned — streak reset")
        } else if pending.evening, !carried.isEmpty {
            showToast("Summary saved. \(carried.count) \(Plural.en(carried.count, "task")) moved to tomorrow")
        }
    }

    // MARK: - Reset and relaunch (T08)

    /// "Reset data…" in "General": asks, then removes the whole data folder (tasks, history, streak, the
    /// dictation draft, a set-aside state file) and the settings, and relaunches. The AI keys stay in the Keychain.
    func confirmResetAllData() {
        let alert = NSAlert()
        alert.messageText = "Reset all data?"
        alert.informativeText = "Tasks, history, streak and settings will be deleted and the app will restart. Claude and ChatGPT keys stay."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        timer?.invalidate()
        PanelWindow.shared.dismiss()   // stops the dictation draft's autosave before its file goes
        try? TaskStore.removeAllData()
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        relaunch()
    }

    /// Starts a fresh copy of the app and quits this one (glass mode change, data reset).
    func relaunch() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Editing (T07)

    private static let orderKey = "bubbles.order"
    private static let trailsKey = "bubbles.trails"
    private static let snoozesKey = "bubbles.snoozes"

    private func loadEditing() {
        if let data = defaults.data(forKey: Self.orderKey), let stored = try? JSONDecoder().decode(TaskOrder.self, from: data) {
            taskOrder = stored
        }
        if let data = defaults.data(forKey: Self.trailsKey),
           let stored = try? JSONDecoder().decode([UUID: TaskTrail].self, from: data) {
            trails = stored
        }
        if let data = defaults.data(forKey: Self.snoozesKey),
           let stored = try? JSONDecoder().decode([UUID: Date].self, from: data) {
            snoozes = stored.filter { $0.value > Date() }
        }
    }

    /// Keeps the editable copy of the desk in step with the store; hooks up "All tasks" and the bubbles' gestures.
    private func startEditing() {
        editing.editor = DeskTaskEditor(tasks: taskStore.tasks, order: taskOrder)
        storeWatch = taskStore.$tasks.sink { [weak self] tasks in self?.storeChanged(tasks) }
        allTasksHandler = { [weak self] in
            guard let self else { return }
            AllTasksWindow.shared.show(model: self)
        }
        addTaskHandler = { [weak self] in
            guard let self else { return }
            AllTasksWindow.shared.show(model: self, focusAdd: true)
        }
        let gestures = BubbleGestures(model: self)
        gestures.install()
        self.gestures = gestures
    }

    /// The store changed (closed, burned, moved, rolled over, launched): the editor follows, pins of tasks
    /// that are gone are dropped.
    private func storeChanged(_ tasks: [DayTask]) {
        editing.editor.sync(tasks)
        if editing.editor.order != taskOrder {
            taskOrder = editing.editor.order
            saveOrder()
        }
    }

    /// Before showing "All tasks".
    func refreshEditing() {
        editing.editor.sync(taskStore.tasks)
    }

    private func saveOrder() {
        if let data = try? JSONEncoder().encode(taskOrder) { defaults.set(data, forKey: Self.orderKey) }
    }

    private func saveTrails() {
        if let data = try? JSONEncoder().encode(trails) { defaults.set(data, forKey: Self.trailsKey) }
    }

    private func saveSnoozes() {
        if let data = try? JSONEncoder().encode(snoozes) { defaults.set(data, forKey: Self.snoozesKey) }
    }

    /// Where the task came from and how often it surfaced or was put off (the card's history).
    func trail(for id: UUID) -> TaskTrail { trails[id] ?? TaskTrail() }

    /// One edit of the desk's tasks, from "All tasks", the card or a bubble's menu; ⌘Z undoes it.
    @discardableResult func editTasks<Result>(spawnFromMic: Bool = false, _ change: (inout EditableTaskList) -> Result) -> Result {
        editing.editor.sync(taskStore.tasks)
        let result = editing.editor.edit(change)
        commitEditing(spawnFromMic: spawnFromMic)
        return result
    }

    /// ⌘Z in "All tasks".
    func undoTaskEdit() {
        editing.editor.sync(taskStore.tasks)
        if editing.editor.undo() { commitEditing(spawnFromMic: false) }
    }

    /// Writes the editor back: the store, the manual order, the ladder (removed tasks are forgotten), the bubbles.
    private func commitEditing(spawnFromMic: Bool) {
        let tasks = editing.editor.tasks
        let gone = Set(taskStore.tasks.map(\.id)).subtracting(tasks.map(\.id))
        for id in gone {
            ladderState.forget(id)
            snoozes[id] = nil
        }
        if !gone.isEmpty {
            saveLadder()
            saveSnoozes()
            if let detailID, gone.contains(detailID) { PanelWindow.shared.dismiss() }
            if world.bodies.contains(where: { gone.contains($0.id) && $0.surfaced }) { world.setSurfaced(nil) }
        }
        taskOrder = editing.editor.order
        saveOrder()
        if tasks != taskStore.tasks { taskStore.replaceDay(with: tasks) }
        syncWorld(spawnFrom: spawnFromMic ? micCenter : nil)
    }

    func renameTask(_ id: UUID, _ title: String) {
        // A launched task cannot lose its name: an empty edit is ignored.
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editTasks { $0.setTitle(title.trimmingCharacters(in: .whitespacesAndNewlines), id: id) }
    }

    func setTaskPriority(_ id: UUID, _ priority: Priority) { editTasks { $0.setPriority(priority, id: id) } }
    func setTaskDue(_ id: UUID, _ minutes: Int?, _ kind: DueKind?) { editTasks { $0.setDue(minutes, kind: kind, id: id) } }
    func setTaskLong(_ id: UUID, _ on: Bool) { editTasks { $0.setLong(on, id: id) } }
    func mergeTaskWithNext(_ id: UUID) {
        let ordered = editing.editor.ordered()
        if let i = ordered.firstIndex(where: { $0.id == id }), i + 1 < ordered.count, isLockedByTakeover(ordered[i + 1].id) {
            return refuseLocked(ordered[i + 1].id)
        }
        editTasks { $0.mergeWithNext(id: id) }
    }
    func moveTask(_ id: UUID, to index: Int) { editTasks { $0.move(id: id, to: index) } }

    /// "Split" (from ⋯), or Return inside the title (`text` as typed, `offset` the cursor).
    @discardableResult func splitTask(_ id: UUID, text: String? = nil, at offset: Int? = nil) -> UUID? {
        editTasks { list in
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { list.setTitle(text, id: id) }
            return list.split(id: id, at: offset)
        }
    }

    func mergeDuplicateTask(_ id: UUID) {
        guard let target = editing.editor.list.duplicates()[id] else { return }
        guard !isLockedByTakeover(id) else { return refuseLocked(id) }
        editTasks { $0.merge(id, into: target) }
    }

    /// "Delete" in "All tasks": off the desk without burning (the row offers "Undo" for 5 s, ⌘Z works).
    /// Once the task's takeover has started it is refused with a toast that offers "Burn…" instead.
    @discardableResult func removeTask(_ id: UUID) -> RemovedTask? {
        guard !isLockedByTakeover(id) else {
            refuseLocked(id)
            return nil
        }
        return editTasks { $0.remove(id: id) }
    }

    /// A desk task whose takeover has started: it can only be closed or burned.
    func isLockedByTakeover(_ id: UUID) -> Bool {
        guard taskStore.tasks.contains(where: { $0.id == id }) else { return false }
        return TakeoverLock.refuses(onDesk: true, canMoveToTomorrow: canMoveToTomorrow(id))
    }

    /// "The takeover has started — …" with "Burn…" (asks, then burns with the streak reset).
    func refuseLocked(_ id: UUID) {
        showToast(TakeoverLock.refusal, actions: [
            ToastAction(label: "Burn…") { [weak self] in self?.confirmBurn(id) },
        ], duration: 6)
    }

    func restoreTask(_ removed: RemovedTask) {
        editTasks(spawnFromMic: false) { $0.restore(removed) }
    }

    /// The add field in "All tasks": parsed for time and urgency (kept as written in the plain tracker);
    /// the bubbles fly out of the mic.
    func addTasks(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var made = isPlainTracker ? TaskParser.plain(lines: [trimmed]).dayTasks : TaskParser.parse(lines: [trimmed]).dayTasks
        if made.isEmpty { made = [DayTask(title: DraftText.capitalized(trimmed))] }
        // The example day gives way to the first real task.
        let samples = sampleTaskIDs
        editTasks(spawnFromMic: true) { list in
            if isSampleDay { list.removeAll { samples.contains($0.id) } }
            list.append(made.map { DraftTask(task: $0) })
        }
        if settingsStore.settings.hidden != .visible { settingsStore.settings.hidden = .visible }
    }

    /// "Start the day" from "Got it": the list becomes the day (with its manual order); "Add to
    /// today" keeps the bubbles already flying and the ladder state, "Replace the day" starts over.
    /// Rows moved to tomorrow go on the shelf; each new task remembers the phrase it came from.
    func launchDraft(_ draft: DictationDraft) {
        let now = Date()
        let alive = Set(taskStore.tasks.map(\.id))
        let existing = Set(draft.list.items.filter(\.onDesk).map(\.id)).union(draft.carry.map(\.task.id))
        // A task closed on the desk while the draft was open does not come back.
        let tasks = draft.launchList(now: now).filter { !existing.contains($0.id) || alive.contains($0.id) }
        for row in draft.list.items where !row.onDesk {
            let line = row.sourceLine.flatMap { $0 < draft.lines.count ? draft.lines[$0] : nil }
            trails[row.id] = TaskTrail(sourceLine: line, dictatedAt: line == nil ? nil : now)
        }
        for task in draft.tomorrow {
            shelf.put(task, now: now)
            ladderState.forget(task.id)
        }
        if !draft.tomorrow.isEmpty { saveShelf() }
        let keepGoing = draft.dayInProgress && draft.mode == .addToToday
        let launched = Set(tasks.map(\.id))
        trails = trails.filter { launched.contains($0.key) || shelf.contains($0.key) }
        saveTrails()
        var order = TaskOrder()
        order.reindex(tasks.map(\.id), pinned: Set(draft.launchOrder(now: now).pins.keys))
        taskOrder = order
        saveOrder()
        taskStore.replaceDay(with: tasks)
        editing.editor = DeskTaskEditor(tasks: taskStore.tasks, order: taskOrder)
        if settingsStore.settings.hidden != .visible { settingsStore.settings.hidden = .visible }
        if keepGoing {
            for id in alive.subtracting(launched) { ladderState.forget(id) }
            saveLadder()
            world.setSurfaced(nil)
            syncWorld(spawnFrom: micCenter)
        } else {
            ladderState = LadderState(lastSurfaceAt: Date())
            saveLadder()
            snoozes = [:]
            saveSnoozes()
            world = PhysicsWorld(bounds: Self.visibleBounds())
            syncWorld(spawnFrom: micCenter)
        }
        guard let top = rankedTasks.first else { return }
        let count = taskStore.tasks.count
        let added = tasks.filter { !alive.contains($0.id) }.count
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if keepGoing {
                self?.showToast("Added \(added). \(count) \(Plural.en(count, "bubble")) on the desk, top: “\(top.title)”")
            } else {
                self?.showToast("\(count) \(Plural.en(count, "bubble")) for today. Top: “\(top.title)”")
            }
        }
    }

    // MARK: - "Snooze", burn, the bubble's menu (T07)

    private func activeSnoozes(now: Date) -> Set<UUID> {
        Set(snoozes.filter { $0.value > now }.map(\.key))
    }

    /// "Snooze ▸ 15 min / 1 hour": the task does not surface until then (a takeover still comes).
    func snooze(_ id: UUID, minutes: Int) {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return }
        let until = Date().addingTimeInterval(Double(minutes) * 60)
        snoozes[id] = until
        saveSnoozes()
        trails[id, default: TaskTrail()].snoozedMinutes.append(minutes)
        saveTrails()
        if world.bodies.contains(where: { $0.id == id && $0.surfaced }) { snoozeSurface() }
        if detailID == id { PanelWindow.shared.dismiss() }
        showToast("“\(task.title)” won't surface until \(DayTask.clock(Ranker.minutesSinceMidnight(until)))")
    }

    /// "Until evening": two hours before "End of day" (18:00 by default); later than that — an hour.
    func snoozeUntilEvening(_ id: UUID) {
        let now = Ranker.minutesSinceMidnight(Date())
        let evening = (settingsStore.settings.endOfDayMinutes ?? 20 * 60) - 120
        snooze(id, minutes: evening > now ? evening - now : 60)
    }

    /// "Burn" from the card (asked there) or the menu (asked here): gone, the streak resets.
    func burnTask(_ id: UUID) {
        guard taskStore.tasks.contains(where: { $0.id == id }) else { return }
        if detailID == id { PanelWindow.shared.dismiss() }
        burn(id)
        showToast("Task burned. Streak reset")
    }

    func confirmBurn(_ id: UUID) {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Burn “\(task.title)”?"
        alert.informativeText = "The task will burn and your streak will reset."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Burn")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        burnTask(id)
    }

    /// Right click on a bubble (screen 5): Edit… · Urgency ▸ · Time ▸ · Snooze ▸ · Move to tomorrow · Burn…
    func bubbleMenu(for id: UUID) -> NSMenu? {
        guard let task = taskStore.tasks.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Edit…") { [weak self] in self?.openDetail(id) })

        let urgency = NSMenu()
        for p in [Priority.urgent, .important, .normal] {
            let item = ClosureMenuItem(p.label) { [weak self] in self?.setTaskPriority(id, p) }
            item.state = task.priority == p ? .on : .off
            urgency.addItem(item)
        }
        menu.addItem(submenu("Urgency", urgency))

        let time = NSMenu()
        time.addItem(ClosureMenuItem("No time") { [weak self] in self?.setTaskDue(id, nil, nil) })
        for m in [12 * 60, 15 * 60, 18 * 60] {
            time.addItem(ClosureMenuItem("By \(DayTask.clock(m))") { [weak self] in self?.setTaskDue(id, m, .deadline) })
        }
        let end = settingsStore.settings.endOfDayMinutes ?? 20 * 60
        time.addItem(ClosureMenuItem("By end of day (\(DayTask.clock(end)))") { [weak self] in self?.setTaskDue(id, end, .deadline) })
        time.addItem(.separator())
        time.addItem(ClosureMenuItem("Other time…") { [weak self] in self?.openDetail(id) })
        menu.addItem(submenu("Time", time))

        let later = NSMenu()
        later.addItem(ClosureMenuItem("For 15 minutes") { [weak self] in self?.snooze(id, minutes: 15) })
        later.addItem(ClosureMenuItem("For 1 hour") { [weak self] in self?.snooze(id, minutes: 60) })
        later.addItem(ClosureMenuItem("Until evening") { [weak self] in self?.snoozeUntilEvening(id) })
        menu.addItem(submenu("Snooze", later))

        menu.addItem(.separator())
        let tomorrow = ClosureMenuItem("Move to tomorrow") { [weak self] in self?.moveToTomorrow(id) }
        tomorrow.isEnabled = canMoveToTomorrow(id)
        if !tomorrow.isEnabled { tomorrow.toolTip = "The takeover has started — you can only close or burn it" }
        menu.addItem(tomorrow)
        menu.addItem(ClosureMenuItem("Burn…") { [weak self] in self?.confirmBurn(id) })
        return menu
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Hover and drag (T07)

    /// The bubble under the cursor (float layer first), as each canvas saw it on its last frame.
    var hoveredBubble: UUID? { drag == nil ? (hover[.float] ?? hover[.desk]) : nil }

    func setHover(_ id: UUID?, layer: DeskLayer) {
        if hover[layer] != id { hover[layer] = id }
    }

    var draggedBubble: UUID? { drag?.id }

    func beginDrag(_ id: UUID, at point: CGPoint, time: TimeInterval) {
        guard settingsStore.settings.bubblesTakeInput, world.bodies.contains(where: { $0.id == id }) else { return }
        drag = BubbleDrag(id: id, samples: [(point, time)])
    }

    func dragMoved(to point: CGPoint, time: TimeInterval) {
        drag?.add(point, time: time)
    }

    /// Let go: the bubble flies on with the hand's speed and bounces off the others.
    func endDrag() {
        guard let drag else { return }
        self.drag = nil
        guard let i = world.bodies.firstIndex(where: { $0.id == drag.id }) else { return }
        world.bodies[i].velocity = drag.throwVelocity
    }
}

/// The editable copy of the desk, observed by "All tasks".
@MainActor final class DeskEditing: ObservableObject {
    @Published var editor = DeskTaskEditor()
}

/// A bubble held by the mouse: recent cursor positions for the throw.
struct BubbleDrag {
    let id: UUID
    var samples: [(point: CGPoint, time: TimeInterval)]

    var point: CGPoint { samples.last?.point ?? .zero }

    mutating func add(_ point: CGPoint, time: TimeInterval) {
        samples.append((point, time))
        samples.removeAll { time - $0.time > 0.1 }
    }

    /// Speed over the last tenth of a second, capped.
    var throwVelocity: CGVector {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.005 else { return .zero }
        let dt = last.time - first.time
        var v = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
        let speed = hypot(v.dx, v.dy), cap: CGFloat = 1800
        if speed > cap { v = CGVector(dx: v.dx / speed * cap, dy: v.dy / speed * cap) }
        return v
    }
}

/// An `NSMenuItem` that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}

/// Whether the menu offers "Day summary…"; `evening` tells which summary (nil = nothing to offer).
@MainActor final class SummaryOffer: ObservableObject {
    @Published var evening: Bool?
    var isReady: Bool { evening != nil }
}
