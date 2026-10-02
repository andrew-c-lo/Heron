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
    @Published private(set) var macros: [Macro] = []
    @Published var selectedMacroID: UUID?
    /// Keeps the sidebar visible (it would otherwise collapse in narrower windows).
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// What the window's sidebar shows.
    @Published var sidebar: SidebarItem? = .autoClicker {
        didSet { if case .macro(let id) = sidebar, selectedMacroID != id { selectedMacroID = id } }
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

    // Watchers
    @Published private(set) var watchers: [Watcher] = []
    @Published private(set) var runningWatchers: Set<UUID> = []
    @Published private(set) var watcherStatus: [UUID: WatcherStatus] = [:]
    let watcherStore = WatcherStore()
    private let watcherEngine = WatcherEngine()
    private var watcherSave: DispatchWorkItem?
    @Published private(set) var hasAccessibility = false
    @Published private(set) var hasInputMonitoring = false
    @Published private(set) var hasScreenRecording = false
    /// Bumped whenever a macro snapshot image changes, so views reload it.
    @Published private(set) var snapshotVersion = 0
    private var snapshotCache: [UUID: NSImage?] = [:]
    private var pendingSnapshot: NSImage?
    @Published var statusMessage: String?
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
        hotkeys = loadedHotkeys
        macros = store.loadAll()
        selectedMacroID = macros.first?.id
        recorder.onChange = { [weak self] n in self?.recordedSteps = n }
        watchers = watcherStore.load()
        watcherEngine.onStatus = { [weak self] st in self?.watcherStatus = st }
        watcherEngine.onFinished = { [weak self] id in
            guard let self else { return }
            self.stopWatcher(id)
            let name = self.watchers.first { $0.id == id }?.name ?? "Watcher"
            self.flash("“\(name)” reached its click limit and stopped.")
            Notifier.post(name, "Reached its click limit and stopped.", enabled: self.prefs.notifyWhenStopped)
        }
        refreshPermissions()
        registerHotkeys()
        ScreenshotTour.runIfRequested(self)
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    var isBusy: Bool { isAutoClicking || isRecording || playingMacroID != nil || countdown != nil || !runningWatchers.isEmpty }

    var menuBarIcon: String {
        if isRecording || countdown != nil { return "record.circle.fill" }
        if playingMacroID != nil { return "play.circle.fill" }
        if isAutoClicking { return "cursorarrow.click.2" }
        if !runningWatchers.isEmpty { return "eye.fill" }
        return "cursorarrow.click"
    }

    var selectedMacro: Macro? { macros.first { $0.id == selectedMacroID } }

    // MARK: - Messages, sounds, permissions

    func updateCompactToolbar(_ width: CGFloat) {
        let compact = width < 760
        if compactToolbar != compact { compactToolbar = compact }
    }

    func flash(_ message: String) {
        statusMessage = message
        messageClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.statusMessage = nil }
        messageClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
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
        guard ProcessInfo.processInfo.environment["MACROCLICKER_SCREENSHOTS"] == nil else { return }
        let bindings: [(Hotkey, () -> Void)] = HotkeyAction.allCases.compactMap { action in
            // Never take over standard Mac shortcuts like ⌘Q, even if one was saved.
            guard let hk = hotkeys[action], !hk.isReserved else { return nil }
            return (hk, { [weak self] in self?.perform(action) })
        }
        HotkeyManager.shared.register(bindings)
    }

    func perform(_ action: HotkeyAction) {
        switch action {
        case .toggleAutoClick: toggleAutoClick()
        case .toggleRecording: toggleRecording(fromUI: false)
        case .togglePlayback: togglePlayback()
        case .stopAll: stopAll()
        case .capturePoint: addPoint(EventSynth.cursor)
        case .toggleWatchers: toggleAllWatchers()
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
            flash("Add at least one click point, or switch to “Follow cursor”.")
            return
        }
        if settings.target.delivery == .background && settings.location == .cursor {
            flash("Background mode needs fixed click points (the cursor isn't used).")
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
            case .untilStopped: loop += " (until stopped)"
            case .duration: loop += " (for \(formatDuration(m.playback.repeatDuration)))"
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
            flash("Can't find a window for \(app.name). Open it first.")
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
                flash("Can't find a window for \(app.name)."); done(nil); return
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
            flash("Can't find a window for \(app.name). Open it first.")
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
        m.target.app = app
        if app == nil && m.target.delivery == .background { m.target.delivery = .normal }
        update(m)
    }

    /// Waits a few seconds so the user can position the mouse, then adds a point.
    func capturePointAfterDelay(_ seconds: Int = 3) {
        runCountdown(seconds) { [weak self] in self?.addPoint(EventSynth.cursor) }
    }

    // MARK: - Recording

    func toggleRecording(fromUI: Bool) {
        if countdown != nil { cancelCountdown(); return }
        isRecording ? stopRecording(fromUI: fromUI) : beginRecording()
    }

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
        let opts = Recorder.Options(
            recordMouseMoves: prefs.recordMouseMoves,
            recordKeyboard: prefs.recordKeyboard,
            coalesceInterval: prefs.moveCoalesceMs / 1000,
            ignoreKey: { code, flags in keys.contains { $0.matches(keyCode: code, flags: flags) } },
            target: prefs.recordTarget
        )
        if let t = prefs.recordTarget, WindowFinder.find(t) == nil {
            flash("Can't find a window for \(t.name). Open it first, or turn off “Record only in”.")
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
        if let t = prefs.recordTarget, ScreenReader.hasPermission {
            Task { @MainActor in self.pendingSnapshot = await ScreenReader.snapshot(of: t) }
        }
    }

    func stopRecording(fromUI: Bool) {
        guard isRecording else { return }
        let steps = recorder.stop(trimTrailingClick: fromUI)
        isRecording = false
        sound("Pop")
        guard !steps.isEmpty else {
            flash("Nothing was recorded.")
            return
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm:ss"
        var m = Macro(name: "Recording \(df.string(from: Date()))", steps: steps)
        m.target.app = prefs.recordTarget
        macros.append(m)
        store.save(m)
        if let snap = pendingSnapshot { setSnapshot(snap, for: m.id) }
        pendingSnapshot = nil
        show(m.id)
        flash("Saved “\(m.name)” — \(steps.count) steps, \(formatDuration(m.duration))")
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

    func play(_ macro: Macro) {
        guard requireAccessibility() else { return }
        guard !macro.steps.isEmpty else { flash("This macro has no steps."); return }
        if isRecording { stopRecording(fromUI: false) }
        guard let prep = prepareTarget(macro.target) else { return }
        stopAutoClick()
        playingMacroID = macro.id
        playStep = 0
        playLoop = 1
        playPausing = nil
        sound("Tink")
        player.play(macro, startDelay: prep.startDelay, progress: { [weak self] s, l, p in
            self?.playStep = s
            self?.playLoop = l
            self?.playPausing = p
        }, waiting: { [weak self] color in
            self?.playWaitingColor = color
        }, finished: { [weak self] error in
            guard let self, !self.player.isRunning else { return }
            self.playingMacroID = nil
            self.playWaitingColor = nil
            if let error {
                self.flash(error); self.sound("Basso")
                Notifier.post(macro.name, error, enabled: self.prefs.notifyWhenStopped)
            }
        })
    }

    func stopPlayback() {
        guard playingMacroID != nil else { return }
        player.stop()
        playingMacroID = nil
        sound("Pop")
    }

    func stopAll() {
        if !runningWatchers.isEmpty { stopAllWatchers() }
        cancelCountdown()
        stopAutoClick()
        stopPlayback()
        if isRecording { stopRecording(fromUI: false) }
    }

    // MARK: - Watchers

    func watcherBinding(for id: UUID) -> Binding<Watcher>? {
        guard watchers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.watchers.first { $0.id == id } ?? Watcher(name: "") },
            set: { [weak self] in self?.updateWatcher($0) }
        )
    }

    func newWatcher() {
        var w = Watcher(name: "Watcher \(watchers.count + 1)")
        w.target.app = autoClick.target.app ?? prefs.recordTarget ?? macros.last?.target.app
        watchers.append(w)
        saveWatchers()
        sidebar = .watcher(w.id)
    }

    func updateWatcher(_ w: Watcher) {
        guard let i = watchers.firstIndex(where: { $0.id == w.id }) else { return }
        watchers[i] = w
        saveWatchers()
        if runningWatchers.contains(w.id) { watcherEngine.run(activeWatchers) }
    }

    func deleteWatcher(_ w: Watcher) {
        stopWatcher(w.id)
        watchers.removeAll { $0.id == w.id }
        saveWatchers()
        if sidebar == .watcher(w.id) { sidebar = .autoClicker }
        flash("Deleted “\(w.name)”.")
    }

    private var activeWatchers: [Watcher] { watchers.filter { runningWatchers.contains($0.id) } }

    private func saveWatchers() {
        watcherSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.watcherStore.save(self.watchers)
        }
        watcherSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Why a watcher can't run yet, or nil if it's ready.
    func watcherProblem(_ w: Watcher) -> String? {
        if w.target.app == nil { return "Choose the app to watch." }
        if !w.canSearch { return "Pick the picture or type the text to look for." }
        // Screenshot copies have no permissions on purpose.
        if ProcessInfo.processInfo.environment["MACROCLICKER_SCREENSHOTS"] != nil { return nil }
        if !(hasScreenRecording || ScreenReader.hasPermission) { return "Allow Screen Recording in Permissions so the window can be seen." }
        if !(hasAccessibility || Permissions.accessibility) { return "Allow Accessibility in Permissions so it can click." }
        return nil
    }

    func toggleWatcher(_ id: UUID) {
        runningWatchers.contains(id) ? stopWatcher(id) : startWatcher(id)
    }

    func startWatcher(_ id: UUID) {
        guard let w = watchers.first(where: { $0.id == id }) else { return }
        if let problem = watcherProblem(w) {
            flash(problem)
            sound("Basso")
            return
        }
        runningWatchers.insert(id)
        watcherStatus[id] = WatcherStatus()
        watcherEngine.run(activeWatchers)
        sound("Tink")
    }

    func stopWatcher(_ id: UUID) {
        guard runningWatchers.contains(id) else { return }
        runningWatchers.remove(id)
        watcherEngine.run(activeWatchers)
        sound("Pop")
    }

    func toggleAllWatchers() {
        if !runningWatchers.isEmpty { stopAllWatchers(); return }
        let ready = watchers.filter { watcherProblem($0) == nil }
        guard !ready.isEmpty else {
            flash(watchers.isEmpty ? "No watchers yet. Add one in the sidebar." : "No watcher is ready to run yet.")
            sound("Basso")
            return
        }
        for w in ready { runningWatchers.insert(w.id); watcherStatus[w.id] = WatcherStatus() }
        watcherEngine.run(activeWatchers)
        sound("Tink")
        flash("Started \(ready.count) watcher\(ready.count == 1 ? "" : "s").")
    }

    func stopAllWatchers() {
        runningWatchers.removeAll()
        watcherEngine.run([])
        sound("Pop")
    }

    /// Looks for the picture once and describes the result.
    func testWatcher(_ w: Watcher) async -> String {
        if let problem = watcherProblem(w), !problem.contains("Accessibility") { return problem }
        return await testMatch(Lookup(watcher: w), in: w.target.app)
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
        let match = await Task.detached { lookup.find(in: shot) }.value
        if let text = lookup.text, !text.isEmpty {
            guard let m = match else { return "“\(text)” isn't on screen right now." }
            return "Found “\(text)” at (\(Int(m.rect.midX)), \(Int(m.rect.midY)))."
        }
        let strictness = lookup.strictness
        guard let m = match else { return "Not found." }
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

    func update(_ m: Macro) {
        guard let i = macros.firstIndex(where: { $0.id == m.id }) else { return }
        macros[i] = m
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

    /// An empty macro meant to be built from picture steps.
    func newChain() {
        var m = Macro(name: "Chain \(macros.filter { $0.name.hasPrefix("Chain") }.count + 1)", steps: [])
        m.target.app = macros.last?.target.app ?? autoClick.target.app ?? prefs.recordTarget
        m.target.delivery = macros.last?.target.delivery ?? .jumpReturn
        macros.append(m)
        store.save(m)
        show(m.id)
    }

    func newMacro() {
        let m = Macro(name: "New Macro", steps: [])
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
        pendingSaves[m.id]?.cancel()
        store.delete(m)
        store.deleteSnapshot(m.id)
        macros.removeAll { $0.id == m.id }
        if selectedMacroID == m.id { selectedMacroID = macros.last?.id }
        if sidebar == .macro(m.id) { sidebar = macros.last.map { .macro($0.id) } ?? .autoClicker }
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
        flash(count > 0 ? "Imported \(count) macro\(count == 1 ? "" : "s")." : "No valid macro files selected.")
    }

    func revealMacroFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.directory])
    }
}

enum SidebarItem: Hashable {
    case autoClicker
    case watcher(UUID)
    case macro(UUID)
    case hotkeys, recording, permissions, general
}
