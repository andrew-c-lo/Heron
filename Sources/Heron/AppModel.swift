import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // Persisted settings
    @Published var autoClick: AutoClickSettings { didSet { Persist.save(autoClick, "autoClick") } }
    @Published var prefs: Preferences {
        didSet {
            Persist.save(prefs, "prefs")
            ClickSpread.configure(enabled: prefs.clickSpread, radius: prefs.clickSpreadRadius)
            DoubleClickEverywhere.configure(enabled: prefs.doubleClickEverywhere)
        }
    }
    @Published private(set) var hotkeys: [HotkeyAction: Hotkey] {
        didSet { Persist.save(hotkeys, "hotkeys"); registerHotkeys() }
    }

    // Macros
    @Published private(set) var macros: [Macro] = [] {
        didSet {
            let names = Dictionary(macros.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            if names != ActionGroup.macroNames { ActionGroup.macroNames = names }
        }
    }
    @Published var selectedMacroID: UUID?
    /// Keeps the sidebar visible (it would otherwise collapse in narrower windows).
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// What the window's sidebar shows.
    @Published var sidebar: SidebarItem? = .autoClicker {
        didSet {
            if case .macro(let id) = sidebar, selectedMacroID != id { selectedMacroID = id }
            // Remembered, so Heron (and mini mode) reopens on the tab you were on.
            switch sidebar {
            case .macro, .macros: UserDefaults.standard.set("macros", forKey: "lastTab")
            case .autoClicker: UserDefaults.standard.set("clicker", forKey: "lastTab")
            default: break
            }
        }
    }

    // Live state
    @Published private(set) var isAutoClicking = false
    @Published private(set) var autoClickCount = 0
    @Published private(set) var autoClickSkipped = 0
    @Published private(set) var isRecording = false
    @Published private(set) var countdown: Int?
    @Published private(set) var recordedSteps = 0
    @Published private(set) var playingMacroID: UUID?
    @Published private(set) var playStep = 0
    @Published private(set) var playLoop = 0
    @Published private(set) var playPausing: Double?
    @Published private(set) var playWaitingColor: String?

    // Macros running in the background (each on its own player, alongside everything else)
    @Published private(set) var backgroundRunning: Set<UUID> = []
    @Published private(set) var backgroundClicks: [UUID: Int] = [:]
    private var backgroundPlayers: [UUID: Player] = [:]
    /// Last run: how often each step fired, and the area its picture or text was found in.
    @Published private(set) var stepHits: [UUID: Int] = [:]
    /// What a running macro is up to, for the editor's live strip.
    struct LiveRun: Equatable {
        var started = Date()
        var lastActivity = Date()
        var lastFired: UUID?
        var lastFiredAt: Date?
        var rounds = 0
    }
    @Published private(set) var live: [UUID: LiveRun] = [:]
    /// Rounds the last run of each macro got through (macros that count rounds), for mini mode.
    @Published private(set) var lastRounds: [UUID: Int] = [:]

    /// Running macros, in a line each, for the menu bar: “Round 3 of 5 · quiet 0:42 · 4:12”.
    func liveLines(now: Date = Date()) -> [(id: UUID, name: String, line: String)] {
        live.compactMap { id, run in
            guard let m = macros.first(where: { $0.id == id }) else { return nil }
            var parts: [String] = []
            if let limit = m.playback.roundLimit {
                parts.append("Round \(min(run.rounds + 1, limit)) of \(limit)")
            } else if m.playback.stopAfterStep != nil {
                parts.append("Round \(run.rounds + 1)")
            }
            let quiet = now.timeIntervalSince(run.lastActivity)
            if m.playback.stopIfIdleMinutes > 0 || quiet >= 15 { parts.append("quiet \(Self.clock(quiet))") }
            parts.append("running \(Self.clock(now.timeIntervalSince(run.started)))")
            return (id, m.name, parts.joined(separator: " · "))
        }
        .sorted { $0.name < $1.name }
    }

    /// Beside the menu bar icon while a macro with a round goal runs: “3/5”.
    /// Next to the menu bar icon while something runs: rounds of a goal (“3/5”), time left (“12m left”),
    /// or how long it has run (“5m”); with several running, how many.
    var menuBarProgress: String? {
        guard !live.isEmpty else { return nil }
        guard live.count == 1, let (id, run) = live.first, let m = macros.first(where: { $0.id == id }) else {
            return "\(live.count) running"
        }
        if let limit = m.playback.roundLimit {
            return "\(min(run.rounds + 1, limit))/\(limit)"
        }
        if m.playback.stopAfterStep != nil { return "R\(run.rounds + 1)" }
        let ran = Date().timeIntervalSince(run.started) / 60
        if m.playback.stopAfterMinutes > 0 {
            return "\(Int(max(0, m.playback.stopAfterMinutes - ran).rounded(.up)))m left"
        }
        return ran < 1 ? "<1m" : "\(Int(ran))m"
    }

    nonisolated static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
    @Published private(set) var stepFound: [UUID: CGRect] = [:]
    /// The biggest single thing each step found last run (to tell one spot from matches all over the window).
    private var stepFoundSize: [UUID: CGSize] = [:]
    /// Screens where the idle tap had to step in, per macro (newest first).
    @Published private(set) var stuckScreens: [UUID: [URL]] = [:]
    /// Things you pressed yourself while a macro played, per macro (most pressed first).
    @Published private(set) var pressSuggestions: [UUID: [PressSuggestion]] = [:]
    private var pressWatchers: [UUID: PressWatcher] = [:]
    /// Smart recording, while a recording is in progress.
    private var clickReader: ClickReader?
    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasInputMonitoring = false
    @Published private(set) var hasScreenRecording = false
    /// Bumped whenever a macro snapshot image changes, so views reload it.
    @Published private(set) var snapshotVersion = 0
    private var snapshotCache: [UUID: NSImage?] = [:]
    private var pendingSnapshot: NSImage?
    @Published var statusMessage: String?
    /// A button shown with the message, when there's an obvious fix.
    struct StatusAction { let title: String; let perform: () -> Void }
    @Published private(set) var statusAction: StatusAction?
    /// The main area is narrow: toolbar items shrink so the page's main button (Play, Start) never overflows.
    @Published var compactToolbar = false

    let store = MacroStore()
    private let clicker = AutoClicker()
    private let player = Player()
    private let recorder = Recorder()
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]
    private var countdownTimer: Timer?
    private var permissionTimer: Timer?
    private var messageClear: DispatchWorkItem?

    init() {
        autoClick = Persist.load("autoClick", default: AutoClickSettings())
        let loadedPrefs = Persist.load("prefs", default: Preferences())
        prefs = loadedPrefs
        ClickSpread.configure(enabled: loadedPrefs.clickSpread, radius: loadedPrefs.clickSpreadRadius)
        DoubleClickEverywhere.configure(enabled: loadedPrefs.doubleClickEverywhere)
        var loadedHotkeys = Persist.load("hotkeys", default: HotkeyAction.defaults)
        // Hotkeys added in later versions get their default once (unless that shortcut is already taken).
        if UserDefaults.standard.integer(forKey: "hotkeysVersion") < 2 {
            let hk = HotkeyAction.toggleWatchers.defaultHotkey
            if loadedHotkeys[.toggleWatchers] == nil, !loadedHotkeys.values.contains(hk) { loadedHotkeys[.toggleWatchers] = hk }
            UserDefaults.standard.set(2, forKey: "hotkeysVersion")
        }
        if UserDefaults.standard.integer(forKey: "hotkeysVersion") < 3 {
            let hk = HotkeyAction.toggleDoubleClick.defaultHotkey
            if loadedHotkeys[.toggleDoubleClick] == nil, !loadedHotkeys.values.contains(hk) { loadedHotkeys[.toggleDoubleClick] = hk }
            UserDefaults.standard.set(3, forKey: "hotkeysVersion")
        }
        hotkeys = loadedHotkeys
        macros = store.loadAll()
        selectedMacroID = macros.first?.id
        recorder.onChange = { [weak self] n in self?.recordedSteps = n }
        convertOldWatchers()
        refreshPermissions()
        registerHotkeys()
        if UserDefaults.standard.string(forKey: "lastTab") == "macros" {
            sidebar = selectedMacroID.map { .macro($0) } ?? .macros
        }
        ScreenshotTour.runIfRequested(self)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.updateAwake() }
        }
        startScheduler()
        readPictureWords()
    }

    // MARK: - Words inside pictures (for step titles)

    private var readingWords = Set<UUID>()

    /// Reads the words inside picture steps that haven't been read yet (once each, on this Mac), so steps can be
    /// titled “Tap the “OK” picture” instead of all being “Tap the picture”.
    func readPictureWords() {
        var todo: [(UUID, Data)] = []
        for m in macros {
            for st in m.steps {
                if case .findImage(let p) = st.action, p.pictureWords == nil || (p.pictureWords == "" && p.pictureColor == nil), !p.png.isEmpty, !readingWords.contains(st.id) {
                    todo.append((st.id, p.png))
                }
            }
        }
        for (id, png) in todo {
            readingWords.insert(id)
            // One picture at a time on its own queue: text recognition blocks its thread, and many at once tied up
            // the threads everything else shares.
            Self.wordQueue.async {
                let words = Self.words(inPicture: png)
                let colour = words.isEmpty ? NSImage(data: png).flatMap(ScreenReader.WindowPixels.init(image:)).map(PictureColor.name) : nil
                Task { @MainActor in self.storePictureWords(words, colour: colour, step: id, png: png) }
            }
        }
    }

    private nonisolated static let wordQueue = DispatchQueue(label: "heron.picture-words", qos: .utility)

    private func storePictureWords(_ words: String, colour: String?, step id: UUID, png: Data) {
        readingWords.remove(id)
        guard var m = macros.first(where: { $0.steps.contains { $0.id == id } }),
              let i = m.steps.firstIndex(where: { $0.id == id }),
              case .findImage(var p) = m.steps[i].action, p.png == png else { return }
        p.pictureWords = words
        p.pictureColor = colour ?? ""
        m.steps[i].action = .findImage(p)
        update(m, bookkeeping: true)
    }

    /// The most prominent short label in a picture (a few words at most), or "" if there isn't one.
    nonisolated static func words(inPicture png: Data) -> String {
        guard let image = NSImage(data: png), let px = ScreenReader.WindowPixels(image: image) else { return "" }
        let candidates = TextFinder.read(px).compactMap { l -> (String, CGFloat)? in
            let t = l.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...20).contains(t.count), t.split(separator: " ").count <= 3,
                  t.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return (t, l.rect.width * l.rect.height)
        }
        return candidates.max { $0.1 < $1.1 }?.0 ?? ""
    }

    // MARK: - Schedules

    /// When each scheduled macro last started on its own (kept across launches).
    @Published private(set) var scheduleLastRun: [UUID: Date] = [:]
    private var scheduleTimer: Timer?
    private var lastScheduleCheck = Date()
    private let stayAwake = StayAwake()
    /// Started by its schedule (gets a summary notification when it ends).
    private var scheduledRuns: Set<UUID> = []
    /// Due while something else was playing: started as soon as Heron is free (within 30 minutes).
    private var pendingScheduled: [UUID: Date] = [:]
    private var launchObserver: NSObjectProtocol?

    private func startScheduler() {
        let stored = Persist.load("scheduleLastRun", default: [String: Date]())
        scheduleLastRun = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSchedules()
                // Keeps the menu bar's run time current through quiet stretches.
                if self?.live.isEmpty == false { self?.objectWillChange.send() }
            }
        }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in self?.appLaunched(bundle) }
        }
        checkSchedules()
    }

    /// When a scheduled macro starts next (nil when it waits for its app, or isn't scheduled).
    func nextScheduledRun(_ m: Macro) -> Date? {
        guard let s = m.schedule, s.enabled else { return nil }
        return s.nextRun(after: Date(), lastRun: scheduleLastRun[m.id])
    }

    private func checkSchedules() {
        let now = Date()
        var waiting = false
        for m in macros {
            guard let s = m.schedule, s.enabled else { continue }
            if s.kind != .appOpens { waiting = true }
            if s.kind == .interval, scheduleLastRun[m.id] == nil {
                // Counting starts when the schedule is first seen.
                setLastRun(m.id, now)
                continue
            }
            if let due = s.nextRun(after: lastScheduleCheck, lastRun: scheduleLastRun[m.id]), due <= now {
                runScheduled(m.id)
            }
        }
        // Retry the ones that were due while Heron was busy.
        for (id, since) in pendingScheduled {
            if now.timeIntervalSince(since) > 30 * 60 {
                pendingScheduled[id] = nil
                let name = macros.first { $0.id == id }?.name ?? "Macro"
                Notifier.post(name, "Skipped its scheduled run: something else was playing for 30 minutes.", enabled: true)
            } else {
                runScheduled(id, retry: true)
            }
        }
        lastScheduleCheck = now
        schedulesWaiting = waiting
        updateAwake()
    }

    private var schedulesWaiting = false

    /// Keeps the Mac and screen awake as the setting says: while running, shortly before a scheduled run, or
    /// the whole time a schedule is set.
    func updateAwake() {
        let running = playingMacroID != nil || !backgroundRunning.isEmpty || isAutoClicking
        let soon = macros.contains { m in nextScheduledRun(m).map { $0.timeIntervalSinceNow < 5 * 60 } ?? false }
        let screen: Bool
        switch prefs.screenAwake {
        case .off: screen = false
        case .whileRunning: screen = running || soon
        case .always: screen = running || schedulesWaiting
        }
        stayAwake.set(mac: schedulesWaiting && prefs.screenAwake != .off, screen: screen)
    }

    private func appLaunched(_ bundleID: String?) {
        guard let bundleID else { return }
        for m in macros where m.schedule?.enabled == true && m.schedule?.kind == .appOpens && m.target.app?.bundleID == bundleID {
            let id = m.id
            // Give the app a moment to show its window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.runScheduled(id) }
        }
    }

    private func setLastRun(_ id: UUID, _ date: Date) {
        scheduleLastRun[id] = date
        Persist.save(Dictionary(uniqueKeysWithValues: scheduleLastRun.map { ($0.key.uuidString, $0.value) }), "scheduleLastRun")
    }

    /// Starts a macro because its schedule says so.
    private func runScheduled(_ id: UUID, retry: Bool = false) {
        guard let m = macros.first(where: { $0.id == id }), m.schedule != nil else { pendingScheduled[id] = nil; return }
        if playingMacroID == id || backgroundRunning.contains(id) { pendingScheduled[id] = nil; return }
        if SystemState.screenIsLocked {
            pendingScheduled[id] = nil
            if !retry { setLastRun(id, Date()) }
            Notifier.post(m.name, "Skipped its scheduled run: the Mac was locked, so clicks can't reach apps.", enabled: true)
            return
        }
        if !m.runsInBackground, playingMacroID != nil || isRecording || isAutoClicking || countdown != nil {
            if pendingScheduled[id] == nil { pendingScheduled[id] = Date(); setLastRun(id, Date()) }
            return
        }
        pendingScheduled[id] = nil
        if !retry { setLastRun(id, Date()) }
        SystemState.wakeDisplay()
        scheduledRuns.insert(id)
        if m.runsInBackground { startBackground(id, quietly: true) } else { play(m) }
        guard playingMacroID == id || backgroundRunning.contains(id) else {
            scheduledRuns.remove(id)
            // Likely nobody is watching: say why in a notification, not only in a message that fades.
            let why = statusMessage ?? "it couldn't start."
            Notifier.post(m.name, "Didn't start on its schedule: " + why.prefix(1).lowercased() + why.dropFirst(), enabled: true)
            return
        }
        flash("“\(m.name)” started on its schedule.")
    }

    /// Called when any run ends: scheduled ones get a summary notification.
    private func finishScheduled(_ id: UUID, clicks: Int, seconds: Int) {
        guard scheduledRuns.remove(id) != nil else { return }
        let name = macros.first { $0.id == id }?.name ?? "Macro"
        let time = seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s"
        Notifier.post(name, "Scheduled run finished: \(clicks) click\(clicks == 1 ? "" : "s") in \(time).", enabled: true)
    }

    var isBusy: Bool { isAutoClicking || isRecording || playingMacroID != nil || countdown != nil || !backgroundRunning.isEmpty }

    var menuBarIcon: String {
        if isRecording || countdown != nil { return "record.circle.fill" }
        if playingMacroID != nil { return "play.circle.fill" }
        if isAutoClicking { return "cursorarrow.click.2" }
        if !backgroundRunning.isEmpty { return "eye.fill" }
        return "cursorarrow.click"
    }

    var selectedMacro: Macro? { macros.first { $0.id == selectedMacroID } }

    // MARK: - Messages, sounds, permissions

    func updateCompactToolbar(_ width: CGFloat) {
        let compact = width < 760
        if compactToolbar != compact { compactToolbar = compact }
    }

    func flash(_ message: String, action: StatusAction? = nil) {
        statusMessage = message
        statusAction = action
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil; self?.statusAction = nil }
        messageClear = work
        // Longer when there's a button to reach for.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 4 : 8), execute: work)
    }

    func dismissMessage() {
        messageClear?.cancel()
        statusMessage = nil
        statusAction = nil
    }

    /// “Can't find a window for X”, with a button that opens X.
    func flashMissingWindow(_ app: TargetApp, _ message: String? = nil) {
        let open = StatusAction(title: "Open \(app.name)") { [weak self] in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                self?.flash("Can't find \(app.name) on this Mac.")
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            self?.flash("Opening \(app.name)… Press Play again once its window is up.")
        }
        flash(message ?? "Can't find a window for \(app.name).", action: open)
    }

    private func sound(_ name: String) {
        guard prefs.playSounds else { return }
        NSSound(named: name)?.play()
    }

    func refreshPermissions() {
        let ax = Permissions.accessibility, im = Permissions.inputMonitoring
        if ax != hasAccessibility { hasAccessibility = ax }
        if im != hasInputMonitoring { hasInputMonitoring = im }
        let sr = ScreenReader.hasPermission
        if sr != hasScreenRecording { hasScreenRecording = sr }
    }

    private func requireAccessibility() -> Bool {
        refreshPermissions()
        if hasAccessibility { return true }
        flash("Accessibility permission is required — see the banner at the top.")
        sound("Basso")
        return false
    }

    // MARK: - Hotkeys

    func setHotkey(_ hk: Hotkey?, for action: HotkeyAction) {
        var h = hotkeys
        if let hk {
            // Avoid two actions sharing a shortcut.
            for (a, existing) in h where existing == hk && a != action { h[a] = nil }
        }
        h[action] = hk
        hotkeys = h
    }

    func resetHotkeys() { hotkeys = HotkeyAction.defaults }

    func suspendHotkeys() { HotkeyManager.shared.unregisterAll() }
    func resumeHotkeys() { registerHotkeys() }

    private func registerHotkeys() {
        // Screenshot copies show the hotkeys but never register them, so they can't take them from the real app.
        guard ProcessInfo.processInfo.environment["HERON_SCREENSHOTS"] == nil else { return }
        let bindings: [(Hotkey, () -> Void)] = HotkeyAction.allCases.compactMap { action in
            // Never take over standard Mac shortcuts like ⌘Q, even if one was saved.
            guard let hk = hotkeys[action], !hk.isReserved else { return nil }
            return (hk, { [weak self] in self?.perform(action) })
        }
        HotkeyManager.shared.register(bindings)
    }

    /// The hotkey that really works for an action: none when the saved one is a standard Mac shortcut (switched off).
    func liveHotkey(_ action: HotkeyAction) -> Hotkey? {
        hotkeys[action].flatMap { $0.isReserved ? nil : $0 }
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleAutoClick: toggleAutoClick()
        case .toggleRecording: toggleRecording(fromUI: false)
        case .togglePlayback: togglePlayback()
        case .stopAll: stopAll()
        case .capturePoint: addPoint(EventSynth.cursor)
        case .toggleWatchers: toggleAllBackground()
        case .toggleDoubleClick:
            prefs.doubleClickEverywhere.toggle()
            flash(prefs.doubleClickEverywhere ? "Double-click everywhere is on." : "Double-click everywhere is off.")
            sound(prefs.doubleClickEverywhere ? "Tink" : "Pop")
        }
    }

    // MARK: - Auto clicker

    func toggleAutoClick() {
        isAutoClicking ? stopAutoClick() : startAutoClick()
    }

    func startAutoClick() {
        guard !isAutoClicking, requireAccessibility() else { return }
        startClicker(autoClick)
    }

    private func startClicker(_ settings: AutoClickSettings) {
        if settings.location == .points && settings.points.isEmpty {
            flash("Add a spot to click first, or set Where to “Wherever the pointer is”.")
            return
        }
        if settings.target.delivery == .background && settings.location == .cursor {
            flash("Clicking in the background needs spots you pick (it doesn't use the pointer).")
            return
        }
        guard let prep = prepareTarget(settings.target) else { return }
        var run = settings
        run.startDelay = max(settings.startDelay, prep.startDelay)
        stopPlayback()
        isAutoClicking = true
        autoClickCount = 0
        autoClickSkipped = 0
        sound("Tink")
        clicker.start(run, onClick: { [weak self] n, skipped in
            self?.autoClickCount = n
            self?.autoClickSkipped = skipped
        }, finished: { [weak self] error in
            guard let self, !self.clicker.isRunning else { return }
            self.isAutoClicking = false
            if let error {
                self.flash(error); self.sound("Basso")
                Notifier.post("Auto clicker stopped", error, enabled: self.prefs.notifyWhenStopped)
            }
        })
    }

    /// Clicks point 1 once using the current delivery mode.
    /// `targetInFront`: bring the target app forward first, but keep the real cursor off its window,
    /// to tell "ignores clicks while in the background" apart from "ignores clicks not made by the real cursor".
    func testClick(targetInFront: Bool = false) {
        guard requireAccessibility() else { return }
        var s = autoClick
        s.location = .points
        s.stopMode = .afterClicks
        s.stopClicks = 1
        s.startDelay = 0
        s.points = Array(s.points.prefix(1))
        guard !s.points.isEmpty else {
            flash("Add a click point first: hover over the spot and press \(hotkeyDisplay(.capturePoint)).")
            return
        }
        guard targetInFront, let app = s.target.app, let running = app.runningApp, let win = WindowFinder.find(app) else {
            startClicker(s)
            flash("Test click sent. Did it register?")
            return
        }
        running.activate()
        let c = EventSynth.cursor
        if win.frame.insetBy(dx: -10, dy: -10).contains(c) {
            let x = win.frame.minX > 120 ? win.frame.minX - 80 : win.frame.maxX + 80
            EventSynth.warp(to: CGPoint(x: x, y: win.frame.midY))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.startClicker(s)
            self?.flash("Test click sent with \(app.name) in front. Did it register?")
        }
    }

    /// Human-readable playback progress, e.g. "loop 3/10 · step 12".
    var playStatus: String {
        let m = macros.first { $0.id == playingMacroID }
        var loop = "loop \(playLoop)"
        if let m {
            switch m.playback.repeatMode {
            case .once: loop = ""
            case .times: loop += "/\(m.playback.loops)"
            case .untilStopped, .duration: loop += " (until it stops)"
            }
        }
        let detail = playWaitingColor.map { "waiting for \($0)" }
            ?? playPausing.map { String(format: "pausing %.1fs", $0) } ?? "step \(playStep)"
        return [loop, detail].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private struct Prepared { var startDelay: Double }

    /// Checks the target window exists and brings the app forward if requested.
    private func prepareTarget(_ t: TargetOptions) -> Prepared? {
        guard let app = t.app else {
            if t.delivery == .background {
                flash("Background mode needs a target app.")
                return nil
            }
            return Prepared(startDelay: 0)
        }
        guard WindowFinder.find(app) != nil else {
            flashMissingWindow(app)
            sound("Basso")
            return nil
        }
        if t.activateFirst && t.delivery != .background, let running = app.runningApp, !running.isActive {
            running.activate()
            return Prepared(startDelay: 0.4)
        }
        return Prepared(startDelay: 0)
    }

    func stopAutoClick() {
        guard isAutoClicking else { return }
        clicker.stop()
        isAutoClicking = false
        sound("Pop")
    }

    func addPoint(_ screenPoint: CGPoint) {
        guard let p = relativePoint(screenPoint, to: autoClick.target.app, requireInside: true) else { return }
        let point = ClickPoint(x: Double(p.x.rounded()), y: Double(p.y.rounded()))
        autoClick.points.append(point)
        let suffix = autoClick.target.app.map { " in \($0.name)" } ?? ""
        flash("Added click point (\(Int(p.x)), \(Int(p.y)))\(suffix)")
        sound("Tink")
        // With color checks on, remember the color under the new point too.
        if autoClick.colorCheck {
            sampleColor(at: screenPoint) { [weak self] hex in
                guard let self, let hex, let i = self.autoClick.points.firstIndex(where: { $0.id == point.id }) else { return }
                self.autoClick.points[i].color = hex
            }
        }
    }

    // MARK: - Colors

    /// Reads the color at a screen point; reports a helpful message if it can't.
    func sampleColor(at screenPoint: CGPoint, _ done: @escaping (String?) -> Void) {
        Task { @MainActor in
            let c = await ScreenReader.colorAsync(at: screenPoint)
            if c == nil {
                self.flash("Couldn't read the screen color. Grant Screen Recording in the Settings tab, or use the eyedropper.")
            }
            done(c?.hex)
        }
    }

    /// Reads the color currently at a point given in `app`'s coordinates (screen if nil).
    func sampleColor(atRelative p: CGPoint, in app: TargetApp?, _ done: @escaping (String?) -> Void) {
        var screen = p
        if let app {
            guard let w = WindowFinder.find(app) else {
                flashMissingWindow(app); done(nil); return
            }
            screen = CGPoint(x: p.x + w.frame.minX, y: p.y + w.frame.minY)
        }
        sampleColor(at: screen, done)
    }

    /// Countdown, then capture the hovered position (relative to `app`) and the color under it.
    func captureSpot(in app: TargetApp?, _ done: @escaping (CGPoint, String?) -> Void) {
        flash("Hover over the spot…")
        runCountdown(3) { [weak self] in
            guard let self else { return }
            let screen = EventSynth.cursor
            guard let p = self.relativePoint(screen, to: app, requireInside: app != nil) else { return }
            self.sound("Tink")
            self.sampleColor(at: screen) { hex in
                done(CGPoint(x: p.x.rounded(), y: p.y.rounded()), hex)
            }
        }
    }

    // MARK: - Snapshots (picture of the target window behind the visual view)

    func snapshot(for id: UUID) -> NSImage? {
        if let cached = snapshotCache[id] { return cached }
        let img = store.loadSnapshot(id)
        snapshotCache[id] = img
        return img
    }

    func updateSnapshot(for m: Macro) {
        guard let app = m.target.app else { return }
        guard hasScreenRecording || ScreenReader.hasPermission else {
            flash("Snapshots need Screen Recording permission (Settings tab).")
            return
        }
        Task { @MainActor in
            guard let img = await ScreenReader.snapshot(of: app) else {
                self.flash("Couldn't capture \(app.name). Make sure its window is open.")
                return
            }
            self.setSnapshot(img, for: m.id)
        }
    }

    private func setSnapshot(_ img: NSImage?, for id: UUID) {
        if let img { store.saveSnapshot(img, for: id) } else { store.deleteSnapshot(id) }
        snapshotCache[id] = img
        snapshotVersion += 1
    }

    // MARK: - Targets & coordinates

    /// Converts a screen point to coordinates relative to the app's window (or returns it unchanged for no app).
    func relativePoint(_ p: CGPoint, to app: TargetApp?, requireInside: Bool = false) -> CGPoint? {
        guard let app else { return p }
        guard let w = WindowFinder.find(app) else {
            flashMissingWindow(app)
            return nil
        }
        if requireInside && !w.frame.contains(p) {
            flash("That position is outside the \(app.name) window.")
            sound("Basso")
            return nil
        }
        return CGPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
    }

    /// The current mouse position in the coordinate space of `app` (screen if nil).
    func currentPoint(relativeTo app: TargetApp?) -> CGPoint? {
        relativePoint(EventSynth.cursor, to: app)
    }

    /// Offset to convert coordinates when switching target: new = old + offset. nil = conversion impossible.
    private func conversionOffset(from old: TargetApp?, to new: TargetApp?) -> CGPoint? {
        func origin(_ a: TargetApp?) -> CGPoint?? {
            guard let a else { return .some(.zero) }
            return WindowFinder.find(a).map { $0.frame.origin }
        }
        guard let o = origin(old) ?? nil, let n = origin(new) ?? nil else { return nil }
        return CGPoint(x: o.x - n.x, y: o.y - n.y)
    }

    func setAutoClickTarget(_ app: TargetApp?) {
        guard app != autoClick.target.app else { return }
        var s = autoClick
        if !s.points.isEmpty {
            if let d = conversionOffset(from: s.target.app, to: app) {
                for i in s.points.indices { s.points[i].x += d.x; s.points[i].y += d.y }
            } else {
                flash("Couldn't find the window to convert existing points. They were kept as-is; re-check them.")
            }
        }
        s.target.app = app
        if app == nil && s.target.delivery == .background { s.target.delivery = .jumpReturn }
        autoClick = s
    }

    /// How a new macro's clicks are sent: in the background when it has an app (the pointer never moves), and
    /// Jump & return when it works on the whole screen (there's no app to send them to) or its app is known to
    /// ignore background clicks (BlueStacks).
    nonisolated static func startingDelivery(for app: TargetApp?) -> DeliveryMode {
        DeliveryMode.backgroundWorks(in: app) ? .background : .jumpReturn
    }

    func setMacroTarget(_ id: UUID, _ app: TargetApp?) {
        guard var m = macros.first(where: { $0.id == id }), app != m.target.app else { return }
        if let d = conversionOffset(from: m.target.app, to: app) {
            for i in m.steps.indices {
                if let p = m.steps[i].action.point {
                    m.steps[i].action.point = CGPoint(x: (p.x + d.x).rounded(), y: (p.y + d.y).rounded())
                }
            }
        } else if m.steps.contains(where: { $0.action.point != nil }) {
            flash("Couldn't find the window to convert coordinates. They were kept as-is; re-check them.")
        }
        let hadApp = m.target.app != nil
        m.target.app = app
        if app == nil && m.target.delivery == .background { m.target.delivery = .jumpReturn }
        // A macro's first app: clicks go to it in the background, so your pointer stays yours.
        if app != nil && !hadApp { m.target.delivery = Self.startingDelivery(for: app) }
        update(m)
    }

    /// Waits a few seconds so the user can position the mouse, then adds a point.
    func capturePointAfterDelay(_ seconds: Int = 3) {
        runCountdown(seconds) { [weak self] in self?.addPoint(EventSynth.cursor) }
    }

    /// Like `capturePointAfterDelay`, but the new spot replaces the ones there were (kept if it can't be used).
    func replacePointAfterDelay(_ seconds: Int = 3) {
        runCountdown(seconds) { [weak self] in
            guard let self else { return }
            let old = autoClick.points
            autoClick.points = []
            addPoint(EventSynth.cursor)
            if autoClick.points.isEmpty { autoClick.points = old }
        }
    }

    // MARK: - Recording

    func toggleRecording(fromUI: Bool) {
        if countdown != nil { cancelCountdown(); return }
        isRecording ? stopRecording(fromUI: fromUI) : beginRecording()
    }

    /// Recording for a template: the steps go into this macro, recorded inside this app.
    private var recordingInto: (id: UUID, app: TargetApp?)?
    /// Set when a recording into a macro has finished (the editor uses it to continue the template).
    @Published private(set) var recordedInto: UUID?

    func record(into id: UUID, app: TargetApp?) {
        guard !isRecording else { return }
        recordingInto = (id, app)
        recordedInto = nil
        beginRecording()
    }

    private var recordTargetNow: TargetApp? { recordingInto.map { $0.app } ?? prefs.recordTarget }

    private func beginRecording() {
        guard requireAccessibility() else { return }
        stopAutoClick()
        stopPlayback()
        if prefs.recordCountdown > 0 {
            runCountdown(prefs.recordCountdown) { [weak self] in self?.startRecordingNow() }
        } else {
            startRecordingNow()
        }
    }

    private func startRecordingNow() {
        let keys = Array(hotkeys.values)
        var opts = Recorder.Options(
            recordMouseMoves: prefs.recordMouseMoves,
            recordKeyboard: prefs.recordKeyboard,
            coalesceInterval: prefs.moveCoalesceMs / 1000,
            ignoreKey: { code, flags in keys.contains { $0.matches(keyCode: code, flags: flags) } },
            target: recordTargetNow
        )
        // Smart recording reads what's under each click, inside the chosen app's window.
        clickReader = nil
        if prefs.smartRecording, hasScreenRecording || ScreenReader.hasPermission {
            clickReader = ClickReader(target: recordTargetNow)
        }
        if let reader = clickReader { opts.onPress = { id, p in reader.notePress(id, at: p) } }
        if let t = recordTargetNow, WindowFinder.find(t) == nil {
            flashMissingWindow(t, "Can't find a window for \(t.name). Open it, or turn off “Record only in”.")
            sound("Basso")
            return
        }
        guard recorder.start(options: opts) else {
            flash("Couldn't start recording. Grant Accessibility and Input Monitoring, then try again.")
            sound("Basso")
            return
        }
        recordedSteps = 0
        isRecording = true
        sound("Tink")
        // Picture of the target as it looked when recording began, for the visual view.
        pendingSnapshot = nil
        if let t = recordTargetNow, ScreenReader.hasPermission {
            Task { @MainActor in self.pendingSnapshot = await ScreenReader.snapshot(of: t) }
        }
    }

    func stopRecording(fromUI: Bool) {
        guard isRecording else { return }
        var steps = recorder.stop(trimTrailingClick: fromUI)
        isRecording = false
        var smart = ClickReader.Result(steps: steps)
        if let reader = clickReader {
            smart = reader.finish(steps)
            steps = smart.steps
            clickReader = nil
        }
        sound("Pop")
        let into = recordingInto
        recordingInto = nil
        guard !steps.isEmpty else {
            flash("Nothing was recorded.")
            return
        }
        if let into, var m = macros.first(where: { $0.id == into.id }) {
            // Added after anything already there (say, a step added while recording), never replacing it.
            m.steps += steps
            let hadApp = m.target.app != nil
            m.target.app = into.app ?? smart.app ?? m.target.app
            if !hadApp { m.target.delivery = Self.startingDelivery(for: m.target.app) }
            m.target.windowSize = m.target.app.flatMap { WindowFinder.find($0)?.frame.size }
            update(m)
            if let snap = pendingSnapshot { setSnapshot(snap, for: m.id) }
            pendingSnapshot = nil
            show(m.id)
            recordedInto = m.id
            let n = ActionGrouper.groups(for: steps).count
            flash("Recorded \(n) step\(n == 1 ? "" : "s")" + smartSummary(smart))
            return
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm:ss"
        var m = Macro(name: "Recording \(df.string(from: Date()))", steps: steps)
        m.target.app = prefs.recordTarget ?? smart.app
        m.target.delivery = Self.startingDelivery(for: m.target.app)
        m.target.windowSize = m.target.app.flatMap { WindowFinder.find($0)?.frame.size }
        macros.append(m)
        store.save(m)
        if let snap = pendingSnapshot { setSnapshot(snap, for: m.id) }
        pendingSnapshot = nil
        show(m.id)
        flash("Saved “\(m.name)” — \(steps.count) steps, \(formatDuration(m.duration))"
              + smartSummary(smart))
    }

    private func smartSummary(_ r: ClickReader.Result) -> String {
        let n = r.words + r.pictures
        guard n > 0 else { return "" }
        return ". \(n) click\(n == 1 ? "" : "s") will find \(n == 1 ? "its" : "their") target wherever it is"
            + (r.app.map { " in \($0.name)" } ?? "") + "."
    }

    private func runCountdown(_ seconds: Int, then action: @escaping () -> Void) {
        cancelCountdown()
        countdown = seconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let c = self.countdown else { return }
                if c <= 1 {
                    self.cancelCountdown()
                    action()
                } else {
                    self.countdown = c - 1
                    self.sound("Morse")
                }
            }
        }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    // MARK: - Playback

    func togglePlayback() {
        if playingMacroID != nil { stopPlayback() } else if let m = selectedMacro { play(m) }
    }

    /// Saves where a “Type from a list” step is up to, so the next run carries on from there.
    private func setListNext(_ stepID: UUID, _ next: Int) {
        guard var m = macros.first(where: { $0.steps.contains { $0.id == stepID } }),
              let i = m.steps.firstIndex(where: { $0.id == stepID }), case .typeList(var l) = m.steps[i].action else { return }
        l.next = next
        m.steps[i].action = .typeList(l)
        update(m, bookkeeping: true)
    }

    /// Remembers the app window's size the first time a macro runs (older macros), so later runs can resize
    /// pictures and positions when the window is a different size.
    @discardableResult
    private func rememberWindowSize(_ id: UUID) -> Macro? {
        guard var m = macros.first(where: { $0.id == id }) else { return nil }
        guard m.target.windowSize == nil, let app = m.target.app, let win = WindowFinder.find(app) else { return m }
        m.target.windowSize = win.frame.size
        update(m)
        return m
    }

    /// `m` with each “Run another macro” step replaced by that macro's steps (and theirs, and so on), or why it
    /// can't be: a macro that would end up running itself, or one that was deleted.
    func expandingRuns(_ m: Macro) -> Result<Macro, RunProblem> {
        let all = macros
        return Self.expandingRuns(m) { id in all.first { $0.id == id } }
    }

    nonisolated static func expandingRuns(_ m: Macro, find: (UUID) -> Macro?) -> Result<Macro, RunProblem> {
        guard m.steps.contains(where: { if case .runMacro = $0.action { true } else { false } }) else { return .success(m) }
        var used = Set<UUID>()
        func fresh(_ st: MacroStep) -> MacroStep {
            // A macro run twice gets its own step ids the second time, so jumps and counts stay apart.
            guard used.insert(st.id).inserted else { var c = st; c.id = UUID(); used.insert(c.id); return c }
            return st
        }
        func expand(_ steps: [MacroStep], chain: [UUID]) throws -> [MacroStep] {
            var out: [MacroStep] = []
            for st in steps {
                guard case .runMacro(let id) = st.action, st.enabled else { out.append(fresh(st)); continue }
                guard let other = find(id) else {
                    throw RunProblem(message: "A Run step's macro was deleted. Pick another one in its settings.")
                }
                guard !chain.contains(id) else { throw RunProblem(message: "“\(other.name)” would end up running itself.") }
                guard chain.count < 8 else { throw RunProblem(message: "Macros run each other more than 8 deep.") }
                var inner = try expand(other.steps, chain: chain + [id])
                if !inner.isEmpty { inner[0].delay += st.delay }
                out += inner
            }
            return out
        }
        do {
            var copy = m
            copy.steps = try expand(m.steps, chain: [m.id])
            return .success(copy)
        } catch let p as RunProblem { return .failure(p) } catch { return .failure(RunProblem(message: "\(error)")) }
    }

    struct RunProblem: Error { let message: String }

    func play(_ macro: Macro) {
        var macro = rememberWindowSize(macro.id) ?? macro
        // Background macros run on their own player, with their own switch.
        if macro.runsInBackground { toggleBackground(macro.id); return }
        guard requireAccessibility() else { return }
        guard !macro.steps.isEmpty else { flash("This macro has no steps."); return }
        guard macro.steps.contains(where: \.enabled) else { flash("All of this macro's steps are switched off."); return }
        switch expandingRuns(macro) {
        case .success(let m): macro = m
        case .failure(let p): flash(p.message); sound("Basso"); return
        }
        if isRecording { stopRecording(fromUI: false) }
        guard let prep = prepareTarget(macro.target) else { return }
        if macro.target.delivery == .background, let app = macro.target.app, !DeliveryMode.backgroundWorks(in: app) {
            // It runs, but the clicks won't land: say so, with the fix one click away.
            let id = macro.id
            flash("\(app.name) ignores clicks sent in the background.", action: StatusAction(title: "Use Jump & Return") { [weak self] in
                guard let self, var m = self.macros.first(where: { $0.id == id }) else { return }
                m.target.delivery = .jumpReturn
                self.update(m)
                if self.playingMacroID == id { self.stopPlayback() }
                self.flash("Switched to Jump & return. Press Play again.")
            })
        }
        stopAutoClick()
        playingMacroID = macro.id
        playStep = 0
        playLoop = 1
        playPausing = nil
        sound("Tink")
        resetHits(for: macro)
        let macroID = macro.id
        player.play(macro, startDelay: prep.startDelay, progress: { [weak self] s, l, p in
            if let self, self.playStep != s { self.live[macroID]?.lastActivity = Date() }
            self?.playStep = s
            self?.playLoop = l
            self?.playPausing = p
        }, waiting: { [weak self] color in
            self?.playWaitingColor = color
        }, clicked: { [weak self] step, found in
            self?.recordHit(step, found)
        }, stuck: { [weak self] screen in
            self?.saveStuck(screen, macro: macroID)
        }, listAdvanced: { [weak self] step, next in
            self?.setListNext(step, next)
        }, counted: { [weak self] n in
            self?.live[macroID]?.rounds = n
        }, finished: { [weak self] error in
            guard let self, !self.player.isRunning else { return }
            self.saveRunReport(macroID)
            self.playingMacroID = nil
            self.playWaitingColor = nil
            if let error, Player.isDone(error) {
                let text = String(error.dropFirst(Player.donePrefix.count))
                self.flash(text); self.sound("Glass")
                Notifier.post(macro.name, text, enabled: self.prefs.notifyWhenStopped)
            } else if let error {
                // The target closed: offer to open it again.
                if let app = macro.target.app, WindowFinder.find(app) == nil { self.flashMissingWindow(app, error) }
                else { self.flash(error) }
                self.sound("Basso")
                Notifier.post(macro.name, error, enabled: self.prefs.notifyWhenStopped)
            }
        })
    }

    func stopPlayback() {
        guard let id = playingMacroID else { return }
        player.stop()
        saveRunReport(id)
        playingMacroID = nil
        sound("Pop")
    }

    func stopAll() {
        if !backgroundRunning.isEmpty { stopAllBackground() }
        cancelCountdown()
        stopAutoClick()
        stopPlayback()
        if isRecording { stopRecording(fromUI: false) }
    }

    /// One tap at a window point, with the target's delivery setting (for Autopilot). Returns an error message.
    func tapOnce(at p: CGPoint, target: TargetOptions) -> String? {
        guard requireAccessibility() else { return "Allow Accessibility so Heron can click." }
        let resolver = target.app.map { TargetResolver(app: $0) }
        switch RouteBuilder.route(for: target, resolver: resolver) {
        case .failure(let e): return e.message
        case .success(let route):
            let performer = Performer(route: route)
            performer.perform(.mouseDown(button: .left, x: Double(p.x), y: Double(p.y), clickCount: 1, flags: 0))
            performer.perform(.mouseUp(button: .left, x: Double(p.x), y: Double(p.y), clickCount: 1, flags: 0))
            return nil
        }
    }

    // MARK: - Run statistics and stuck screens

    private func resetHits(for m: Macro) {
        live[m.id] = LiveRun()
        for s in m.steps { stepHits[s.id] = nil; stepFound[s.id] = nil; stepFoundSize[s.id] = nil }
        runs[m.id] = RunLog(started: Date())
        _ = pressWatchers.removeValue(forKey: m.id)?.finish()
        if prefs.suggestFromMyPresses, hasInputMonitoring, let app = m.target.app {
            let w = PressWatcher(app: app, steps: m.steps)
            if w.start() { pressWatchers[m.id] = w }
        }
    }

    /// Stops noticing your presses for a macro and offers what you pressed.
    private func collectPresses(_ macroID: UUID) {
        guard let w = pressWatchers.removeValue(forKey: macroID) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = w.finish()
            guard !found.isEmpty else { return }
            Task { @MainActor in
                guard let self else { return }
                self.pressSuggestions[macroID] = PressSuggestion.merge(self.pressSuggestions[macroID] ?? [], found)
                let n = found.count
                self.flash("You pressed \(n) thing\(n == 1 ? "" : "s") yourself during the run. See “You pressed” to add \(n == 1 ? "it" : "them") as steps.")
            }
        }
    }

    func clearPressSuggestions(macro: UUID) {
        pressSuggestions[macro] = nil
    }

    func dismissPressSuggestion(_ id: UUID, macro: UUID) {
        pressSuggestions[macro]?.removeAll { $0.id == id }
        if pressSuggestions[macro]?.isEmpty == true { pressSuggestions[macro] = nil }
    }

    /// What happened during a run, saved as a report when it ends (Heron/Runs) so it can be studied later.
    private struct RunLog {
        let started: Date
        var events: [(t: Double, step: UUID?)] = [] // step nil = a “Tap when stuck” tap
    }
    private var runs: [UUID: RunLog] = [:]

    private func recordHit(_ step: UUID, _ found: CGRect?) {
        if let macro = macros.first(where: { $0.steps.contains { $0.id == step } })?.id, runs[macro] != nil {
            runs[macro]!.events.append((Date().timeIntervalSince(runs[macro]!.started), step))
        }
        stepHits[step, default: 0] += 1
        if let id = macros.first(where: { $0.steps.contains { $0.id == step } })?.id, live[id] != nil {
            live[id]!.lastFired = step
            live[id]!.lastFiredAt = Date()
            live[id]!.lastActivity = Date()
        }
        if let found {
            stepFound[step] = stepFound[step].map { $0.union(found) } ?? found
            let old = stepFoundSize[step] ?? .zero
            stepFoundSize[step] = CGSize(width: max(old.width, found.width), height: max(old.height, found.height))
        }
    }

    /// Where each step was found in earlier runs (from the saved reports): the spot and how many runs saw it.
    @Published private(set) var foundHistory: [UUID: (rect: CGRect, runs: Int, size: CGSize)] = [:]

    /// Reads where this macro's steps were found in its saved run reports.
    func loadFoundHistory(for m: Macro) {
        let dir = AppFolder.url.appendingPathComponent("Runs", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(m.steps.map(\.id))
        for s in m.steps { foundHistory[s.id] = nil }
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let steps = report["steps"] as? [[String: Any]] else { continue }
            if let id = report["macroID"] as? String { guard id == m.id.uuidString else { continue } }
            else {
                // Older reports: same name, same steps (they're listed by number then).
                guard report["macro"] as? String == m.name, steps.count == m.steps.count else { continue }
            }
            for (i, d) in steps.enumerated() {
                guard let f = d["foundIn"] as? [Double], f.count == 4 else { continue }
                let id = (d["id"] as? String).flatMap(UUID.init(uuidString:)) ?? m.steps[i].id
                guard ids.contains(id) else { continue }
                let r = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
                var size = CGSize.zero
                if let s = d["foundSize"] as? [Double], s.count == 2 { size = CGSize(width: s[0], height: s[1]) }
                let old = foundHistory[id]
                foundHistory[id] = (old.map { $0.rect.union(r) } ?? r, (old?.runs ?? 0) + 1,
                                    CGSize(width: max(size.width, old?.size.width ?? 0), height: max(size.height, old?.size.height ?? 0)))
            }
        }
    }

    /// The search area suggested for a step from where it showed up in every run so far (with some room
    /// around it): when it keeps appearing in one spot, searching just there is faster and avoids look-alikes.
    func suggestedArea(for step: UUID) -> CGRect? {
        let past = foundHistory[step]
        let now = stepFound[step]
        let seen = (past?.runs ?? 0) + (now != nil && (stepHits[step] ?? 0) >= 2 ? 1 : 0)
        let rects = [past?.rect, now].compactMap { $0 }
        guard seen >= 2 || (stepHits[step] ?? 0) >= 3, var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        // Only when it keeps showing up in one part of the window: matches scattered all over (say “1” found in
        // several different numbers) would make the “area” the whole window.
        var one = stepFoundSize[step] ?? .zero
        if let p = past?.size { one = CGSize(width: max(one.width, p.width), height: max(one.height, p.height)) }
        if let s = macros.lazy.flatMap(\.steps).first(where: { $0.id == step }), case .findImage(let p) = s.action, p.usesPicture {
            one = CGSize(width: max(one.width, p.width), height: max(one.height, p.height))
        }
        guard one.width > 0, one.height > 0, r.width * r.height <= 16 * one.width * one.height else { return nil }
        return r.insetBy(dx: -max(24, r.width * 0.25), dy: -max(24, r.height * 0.25)).integral
    }

    /// Picture and text steps whose search could be narrowed to where they always showed up.
    func narrowableSteps(in m: Macro) -> [(id: UUID, area: CGRect)] {
        m.steps.compactMap { s in
            guard case .findImage(let p) = s.action, let a = suggestedArea(for: s.id) else { return nil }
            guard p.area == nil else { return nil } // already limited
            return (s.id, a)
        }
    }

    private static func stuckFolder(_ macro: UUID) -> URL {
        AppFolder.url.appendingPathComponent("Stuck/\(macro.uuidString)", isDirectory: true)
    }

    func loadStuck(for macro: UUID) {
        let dir = Self.stuckFolder(macro)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
        stuckScreens[macro] = files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Writes the report of a finished run: how often each step fired, where, and every click's time.
    private func saveRunReport(_ macroID: UUID) {
        let rounds = live[macroID]?.rounds ?? 0
        if live[macroID] != nil, macros.first(where: { $0.id == macroID })?.playback.stopAfterStep != nil { lastRounds[macroID] = rounds }
        live[macroID] = nil
        collectPresses(macroID)
        if let log = runs[macroID] {
            finishScheduled(macroID, clicks: log.events.count, seconds: Int(Date().timeIntervalSince(log.started)))
        } else {
            finishScheduled(macroID, clicks: 0, seconds: 0)
        }
        guard let log = runs.removeValue(forKey: macroID), let m = macros.first(where: { $0.id == macroID }),
              !log.events.isEmpty else { return }
        let index = Dictionary(uniqueKeysWithValues: m.steps.enumerated().map { ($0.element.id, $0.offset + 1) })
        let steps: [[String: Any]] = m.steps.enumerated().map { i, s in
            var d: [String: Any] = ["step": i + 1, "id": s.id.uuidString, "hits": stepHits[s.id] ?? 0, "enabled": s.enabled]
            if case .findImage(let p) = s.action {
                d["looksFor"] = p.text.map { "text: \($0)" } ?? "picture \(Int(p.width))×\(Int(p.height))"
            }
            if let r = stepFound[s.id] { d["foundIn"] = [r.minX, r.minY, r.width, r.height].map { Int($0) } }
            if let z = stepFoundSize[s.id] { d["foundSize"] = [Int(z.width), Int(z.height)] }
            return d
        }
        let report: [String: Any] = [
            "macro": m.name, "macroID": m.id.uuidString, "started": ISO8601DateFormatter().string(from: log.started),
            "seconds": Int(Date().timeIntervalSince(log.started)),
            "stuckTaps": log.events.filter { $0.step == nil }.count,
            "rounds": m.playback.stopAfterStep == nil ? NSNull() : rounds as Any,
            "steps": steps,
            "clicks": log.events.map { ["t": (($0.t * 10).rounded() / 10), "step": $0.step.flatMap { index[$0] } ?? 0] },
        ]
        let dir = AppFolder.url.appendingPathComponent("Runs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: log.started).replacingOccurrences(of: ":", with: "-")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("\(m.name) \(stamp).json"))
        }
        loadFoundHistory(for: m)
    }

    private func saveStuck(_ screen: ScreenReader.WindowPixels, macro: UUID) {
        if runs[macro] != nil { runs[macro]!.events.append((Date().timeIntervalSince(runs[macro]!.started), nil)) }
        let dir = Self.stuckFolder(macro)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let cg = screen.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try? png.write(to: dir.appendingPathComponent("\(stamp).png"))
            // Keep the newest 24.
            let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in all.dropFirst(24) { try? FileManager.default.removeItem(at: old) }
            Task { @MainActor in self?.loadStuck(for: macro) }
        }
    }

    func deleteStuck(_ url: URL, macro: UUID) {
        try? FileManager.default.removeItem(at: url)
        loadStuck(for: macro)
    }

    /// Moves every stuck screen of a macro to the Trash (so a mistaken Clear All can be undone in Finder).
    func clearStuck(macro: UUID) {
        for url in stuckScreens[macro] ?? [] {
            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: url)
            }
        }
        loadStuck(for: macro)
    }

    // MARK: - Background macros

    func isRunningInBackground(_ id: UUID) -> Bool { backgroundRunning.contains(id) }

    func toggleBackground(_ id: UUID) {
        backgroundRunning.contains(id) ? stopBackground(id) : startBackground(id)
    }

    /// Why a background macro can't start, or nil if it's ready.
    func backgroundProblem(_ m: Macro) -> String? {
        if m.steps.filter(\.enabled).isEmpty { return "“\(m.name)” has no steps yet." }
        let pictures = m.steps.contains { if case .findImage = $0.action { true } else { false } }
        if pictures, m.target.app == nil { return "Choose the app for “\(m.name)” to watch (Target)." }
        // Screenshot copies have no permissions on purpose.
        if ProcessInfo.processInfo.environment["HERON_SCREENSHOTS"] != nil { return nil }
        if pictures, !(hasScreenRecording || ScreenReader.hasPermission) {
            return "Allow Screen Recording in Settings › Permissions so the window can be seen."
        }
        if !(hasAccessibility || Permissions.accessibility) { return "Allow Accessibility in Settings › Permissions so it can click." }
        return nil
    }

    func startBackground(_ id: UUID, quietly: Bool = false) {
        guard var m = rememberWindowSize(id), !backgroundRunning.contains(id) else { return }
        if let problem = backgroundProblem(m) {
            if !quietly { flash(problem); sound("Basso") }
            return
        }
        switch expandingRuns(m) {
        case .success(let expanded): m = expanded
        case .failure(let p):
            if !quietly { flash(p.message); sound("Basso") }
            return
        }
        let player = Player()
        backgroundPlayers[id] = player
        backgroundRunning.insert(id)
        backgroundClicks[id] = 0
        if !quietly { sound("Tink") }
        resetHits(for: m)
        player.play(m, progress: { _, _, _ in }, clicked: { [weak self] step, found in
            self?.backgroundClicks[id, default: 0] += 1
            self?.recordHit(step, found)
        }, stuck: { [weak self] screen in
            self?.saveStuck(screen, macro: id)
        }, listAdvanced: { [weak self] step, next in
            self?.setListNext(step, next)
        }, counted: { [weak self] n in
            self?.live[id]?.rounds = n
        }, finished: { [weak self, weak player] error in
            guard let self, player?.isRunning != true, self.backgroundPlayers[id] === player else { return }
            self.saveRunReport(id)
            self.backgroundPlayers[id] = nil
            self.backgroundRunning.remove(id)
            let name = self.macros.first { $0.id == id }?.name ?? "Macro"
            if let error, Player.isDone(error) {
                let text = String(error.dropFirst(Player.donePrefix.count))
                self.flash("“\(name)”: \(text)"); self.sound("Glass")
                Notifier.post(name, text, enabled: self.prefs.notifyWhenStopped)
            } else if let error {
                self.flash("“\(name)”: \(error)"); self.sound("Basso")
                Notifier.post(name, error, enabled: self.prefs.notifyWhenStopped)
            } else if m.playback.maxClicks > 0, (self.backgroundClicks[id] ?? 0) >= m.playback.maxClicks {
                self.flash("“\(name)” reached its click limit and stopped.")
                Notifier.post(name, "Reached its click limit and stopped.", enabled: self.prefs.notifyWhenStopped)
            }
        })
    }

    func stopBackground(_ id: UUID, quietly: Bool = false) {
        guard let player = backgroundPlayers.removeValue(forKey: id) else { return }
        player.stop()
        saveRunReport(id)
        backgroundRunning.remove(id)
        if !quietly { sound("Pop") }
    }

    /// The hotkey: stop every background macro if any runs, otherwise start all of them.
    func toggleAllBackground() {
        if !backgroundRunning.isEmpty { stopAllBackground(); return }
        let all = macros.filter(\.runsInBackground)
        guard !all.isEmpty else {
            flash("No background macros yet. Turn on “Keep running in the background” in a macro’s Playback settings.")
            sound("Basso")
            return
        }
        let ready = all.filter { backgroundProblem($0) == nil }
        guard !ready.isEmpty else { flash(backgroundProblem(all[0]) ?? "Not ready yet."); sound("Basso"); return }
        for m in ready { startBackground(m.id, quietly: true) }
        sound("Tink")
        flash("Started \(ready.count) background macro\(ready.count == 1 ? "" : "s").")
    }

    func stopAllBackground() {
        for id in backgroundRunning { stopBackground(id, quietly: true) }
        sound("Pop")
    }

    /// A background chain with one picture step: "whenever this shows up, click it".
    func newBackgroundChain() {
        var m = Macro(name: "Watch \(macros.filter(\.runsInBackground).count + 1)", steps: [])
        m.target.app = selectedMacro?.target.app ?? autoClick.target.app ?? prefs.recordTarget
        m.target.delivery = Self.startingDelivery(for: m.target.app)
        m.runsInBackground = true
        m.playback.order = .allAtOnce
        m.playback.repeatMode = .untilStopped
        macros.append(m)
        store.save(m)
        show(m.id)
    }

    /// Watchers used to be their own thing; each becomes a one-step background chain. The old file is kept
    /// next to the macros as a backup.
    private func convertOldWatchers() {
        let old = WatcherStore()
        let watchers = old.load()
        guard !watchers.isEmpty else { return }
        for w in watchers {
            var step = ImageStep(png: w.templatePNG ?? Data(), width: w.templateWidth, height: w.templateHeight,
                                 originX: 0, originY: 0)
            step.text = w.text
            step.area = w.area
            step.strictness = w.strictness
            step.button = w.button
            step.offsetX = w.offsetX
            step.offsetY = w.offsetY
            step.settle = w.firstClickDelay
            step.repeatUntilGone = true
            step.repeatEvery = w.interval
            var m = Macro(name: w.name, steps: [MacroStep(delay: 0, action: .findImage(step))])
            m.target = w.target
            m.runsInBackground = true
            m.playback.order = .allAtOnce
            m.playback.repeatMode = .untilStopped
            m.playback.maxClicks = w.maxClicks
            macros.append(m)
            store.save(m)
        }
        old.retire()
    }

    func testPicture(_ s: ImageStep, in app: TargetApp?) async -> String {
        await testMatch(Lookup(step: s), in: app)
    }

    private func testMatch(_ lookup: Lookup?, in app: TargetApp?) async -> String {
        guard let app else { return "Choose the app to watch first." }
        guard let win = WindowFinder.find(app) else { return "Can't find \(app.name)'s window. Is it open?" }
        guard let lookup else { return "The picture couldn't be read. Pick it again." }
        guard let shot = await ScreenReader.captureWindowAsync(win) else {
            return "Couldn't capture \(app.name). Allow Screen Recording in Permissions."
        }
        if lookup.isText, let text = lookup.text {
            let match = await Task.detached { lookup.matchText(in: shot) }.value
            guard let m = match else { return "“\(text)” isn't on screen right now." }
            return "Found “\(text)” at (\(Int(m.rect.midX)), \(Int(m.rect.midY)))."
        }
        let strictness = lookup.strictness
        let picture = await Task.detached { lookup.matchPicture(in: shot) }.value
        if let m = picture, m.score >= strictness {
            return "Found the picture at (\(Int(m.rect.midX)), \(Int(m.rect.midY))): \(Int((m.score * 100).rounded()))% match."
        }
        // “Both”: the picture isn't there, so try the words.
        if let text = lookup.text, lookup.hasText {
            let words = await Task.detached { lookup.matchText(in: shot) }.value
            let pictureNote = picture.map { " (the picture was only a \(Int(($0.score * 100).rounded()))% match)" } ?? ""
            if let w = words {
                return "Found “\(text)” at (\(Int(w.rect.midX)), \(Int(w.rect.midY)))\(pictureNote)."
            }
            return "Neither the picture nor “\(text)” is on screen right now\(pictureNote)."
        }
        guard let m = picture else { return "Not found." }
        let pct = Int((m.score * 100).rounded())
        if m.score >= strictness {
            return "Found at (\(Int(m.rect.midX)), \(Int(m.rect.midY))): \(pct)% match."
        }
        return "Not on screen right now. The closest thing was a \(pct)% match; it needs \(Int(strictness * 100))%."
    }

    /// A picture of the app's window to crop the button from.
    func windowPicture(for app: TargetApp?) async -> NSImage? {
        guard let app else { flash("Choose the app to watch first."); return nil }
        guard let img = await ScreenReader.snapshot(of: app) else {
            flash("Couldn't capture \(app.name). Make sure it's open and Screen Recording is allowed.")
            return nil
        }
        return img
    }

    // MARK: - Macro library

    func show(_ id: UUID) {
        selectedMacroID = id
        sidebar = .macro(id)
    }

    /// A binding to a macro. With an undo manager, every change can be undone (⌘Z) and redone (⇧⌘Z).
    func binding(for id: UUID, undoManager: UndoManager? = nil) -> Binding<Macro>? {
        guard macros.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.macros.first { $0.id == id } ?? Macro(name: "", steps: []) },
            set: { [weak self] in self?.update($0, undoManager: undoManager) }
        )
    }

    func update(_ m: Macro, undoManager: UndoManager?) {
        if let undoManager, let old = macros.first(where: { $0.id == m.id }), old != m {
            undoManager.registerUndo(withTarget: self) { model in
                // Registering again while undoing is what makes Redo work.
                model.update(old, undoManager: undoManager)
            }
            undoManager.setActionName("Edit Macro")
        }
        update(m)
    }

    /// `bookkeeping`: a change Heron makes itself (a list's position, words read from a picture), which a running
    /// background macro doesn't need to restart for.
    func update(_ m: Macro, bookkeeping: Bool = false) {
        guard let i = macros.firstIndex(where: { $0.id == m.id }) else { return }
        var m = m
        // “Stop after a step happens N times” on a step that was deleted would never stop: drop it.
        if let counted = m.playback.stopAfterStep, !m.steps.contains(where: { $0.id == counted }) {
            m.playback.stopAfterStep = nil
        }
        let old = macros[i]
        macros[i] = m
        if !bookkeeping { readPictureWords() }
        // A running background macro picks up edits by restarting with them.
        if !bookkeeping, backgroundRunning.contains(m.id), old.steps != m.steps || old.target != m.target || old.playback != m.playback {
            stopBackground(m.id, quietly: true)
            startBackground(m.id, quietly: true)
        }
        // Debounce disk writes while typing.
        pendingSaves[m.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let latest = self.macros.first(where: { $0.id == m.id }) else { return }
            self.store.save(latest)
            self.pendingSaves[m.id] = nil
        }
        pendingSaves[m.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Folder names in the macro list, sorted.
    var folders: [String] { Array(Set(macros.compactMap(\.folder))).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    func setFolder(_ folder: String?, for id: UUID) {
        guard var m = macros.first(where: { $0.id == id }) else { return }
        m.folder = folder
        update(m)
    }

    /// An empty macro meant to be built from picture steps.
    func newChain() {
        var m = Macro(name: "Chain \(macros.filter { $0.name.hasPrefix("Chain") }.count + 1)", steps: [])
        m.target.app = macros.last?.target.app ?? autoClick.target.app ?? prefs.recordTarget
        m.target.delivery = Self.startingDelivery(for: m.target.app)
        macros.append(m)
        store.save(m)
        show(m.id)
    }

    func newMacro() {
        var m = Macro(name: "New Macro", steps: [])
        // Same app as the macro you're looking at, so picture and text steps work right away.
        m.target.app = selectedMacro?.target.app ?? macros.last?.target.app ?? autoClick.target.app ?? prefs.recordTarget
        m.target.delivery = Self.startingDelivery(for: m.target.app)
        macros.append(m)
        store.save(m)
        show(m.id)
    }

    func duplicate(_ m: Macro) {
        var copy = m
        copy.id = UUID()
        copy.created = Date()
        copy.name = m.name + " copy"
        copy.steps = m.steps.map { var s = $0; s.id = UUID(); return s }
        macros.append(copy)
        store.save(copy)
        if let snap = snapshot(for: m.id) { setSnapshot(snap, for: copy.id) }
        show(copy.id)
    }

    func delete(_ m: Macro) {
        if playingMacroID == m.id { stopPlayback() }
        stopBackground(m.id, quietly: true)
        pendingSaves[m.id]?.cancel()
        store.delete(m)
        store.deleteSnapshot(m.id)
        macros.removeAll { $0.id == m.id }
        if selectedMacroID == m.id { selectedMacroID = macros.last?.id }
        if sidebar == .macro(m.id) { sidebar = macros.last.map { .macro($0.id) } ?? .macros }
        flash("Moved “\(m.name)” to the Trash.")
    }

    func export(_ m: Macro) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.name + ".json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(m, to: url); flash("Exported to \(url.lastPathComponent)") }
        catch { flash("Export failed: \(error.localizedDescription)") }
    }

    func importMacros() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var count = 0
        for url in panel.urls {
            if let m = try? store.importMacro(from: url) {
                macros.append(m)
                store.save(m)
                show(m.id)
                count += 1
            }
        }
        let scheduled = macros.suffix(count).contains { $0.schedule != nil }
        flash(count == 0 ? "None of those files is a Heron macro."
              : "Imported \(count) macro\(count == 1 ? "" : "s")." + (scheduled ? " Schedules stay off until you turn them on." : ""))
    }

    func revealMacroFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}

enum SidebarItem: Hashable {
    case autoClicker
    case macro(UUID)
    /// The Macros tab with nothing selected.
    case macros
    case hotkeys, recording, permissions, general
}
