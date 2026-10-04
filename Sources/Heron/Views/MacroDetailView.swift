import SwiftUI

struct MacroDetailView: View {
    @EnvironmentObject var model: AppModel
    @Binding var macro: Macro
    /// Separate from `macro` so typing a name isn't an undo step per letter.
    @Binding var name: String
    @FocusState private var nameFocused: Bool
    @Environment(\.undoManager) private var undoManager
    // @State is a compiler-plugin macro that the Command Line Tools don't ship, so use an ObservableObject.
    @StateObject private var ui = DetailUIState()
    @AppStorage("stepsViewMode") private var viewMode = "visual"
    /// The step details panel beside the list; hide it to give the list the whole width.
    @AppStorage("showStepDetails") private var showDetails = true

    private enum Mode: String { case visual, actions, raw }

    /// Older versions stored "simple"/"detailed".
    private var mode: Mode {
        switch viewMode {
        case "actions", "simple": .actions
        case "raw", "detailed": .raw
        default: .visual
        }
    }

    private var isSimple: Bool { mode != .raw }

    private var editing: ActionEditing { ActionEditing(macro: $macro, ui: ui) }

    private var selection: Set<UUID> {
        get { ui.selection }
        nonmutating set { ui.selection = newValue }
    }

    private var isPlaying: Bool { model.playingMacroID == macro.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            toolbarRow
            if let run = model.live[macro.id] {
                liveStrip(run)
                    .transition(.opacity)
            }
            HStack(spacing: 0) {
                stepsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if mode != .raw, !macro.steps.isEmpty, showDetails {
                    Divider()
                    StepInspector(editing: editing, app: macro.target.app, allAtOnce: allAtOnce,
                                  onShowRaw: showRawSteps, onAddColorCheck: addColorCheck,
                                  onSampleColor: sampleColor, onDelete: deleteSelected)
                        .frame(width: ui.inspectorWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .frame(maxHeight: .infinity)
        }
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { updateCompact(g.size.width) }
                .onChange(of: g.size.width) { _, w in updateCompact(w) }
        })
        .focusedSceneValue(\.macroPanels, MacroPanels { panel in
            ui.showingTarget = panel == .target
            ui.showingPlayback = panel == .playback
            ui.showingStops = panel == .stops
            ui.showingSchedule = panel == .schedule
        })
        .onAppear { model.loadStuck(for: macro.id); model.loadFoundHistory(for: macro) }
        .onChange(of: model.recordedInto) { _, _ in finishTemplate() }
        .onChange(of: macro.steps.isEmpty) { _, empty in if empty { ui.blankChosen = false } }
        .onChange(of: macro.id) { _, _ in ui.blankChosen = false; ui.templateFollowUp = nil }
        .background {
            // Keyboard shortcuts for moving the selected steps.
            Group {
                Button("") { editing.move(nil, .up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("") { editing.move(nil, .down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("") { editing.move(nil, .top) }.keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                Button("") { editing.move(nil, .bottom) }.keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
                Button("") { showDetails.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .sheet(isPresented: $ui.showingPresses) {
            PressSuggestionsView(macroID: macro.id, inOrder: macro.playback.order != .allAtOnce, onAdd: { step in
                select(insert(.findImage(step), delay: 0.1))
            }, onDone: { ui.showingPresses = false })
        }
        .sheet(isPresented: $ui.showingStuck) {
            StuckScreensView(macroID: macro.id, onAdd: { step in
                select(insert(.findImage(step), delay: 0.1))
            }, onDone: { ui.showingStuck = false })
        }
        .sheet(isPresented: $ui.showingAutopilot) {
            AutopilotView(target: macro.target) { ui.showingAutopilot = false }
        }
        // QA tour: select an action by its position so the details panel can be checked.
        .onReceive(NotificationCenter.default.publisher(for: ScreenshotTour.selectAction)) { note in
            guard let i = note.object as? Int else { ui.selection = []; return }
            let groups = editing.groups
            if groups.indices.contains(i) { editing.select(groups[i]) }
        }
    }

    // MARK: Header: name (click to rename), stats, view and undo

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: $name, prompt: Text("Name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .help("Click to rename")
                    .focused($nameFocused)
                    // Left empty: it gets a name back, so it never shows as a blank row or “” in messages.
                    .onChange(of: nameFocused) { _, focused in if !focused { keepAName() } }
                    .onSubmit { keepAName() }
                    .onDisappear { keepAName() }
                Text(stats).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let n = model.pressSuggestions[macro.id]?.count, n > 0 {
                Button { ui.showingPresses = true } label: {
                    Label("You pressed \(n)", systemImage: "hand.tap")
                }
                .help("Things you pressed yourself while it played. Add them as steps.")
            }
            if let n = model.stuckScreens[macro.id]?.count, n > 0 {
                Button { ui.showingStuck = true } label: {
                    Label("\(n) Stuck Screen\(n == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                }
                .help("Screens where “Tap when stuck” had to step in. Turn them into steps.")
            }
            if mode == .raw {
                Button { viewMode = Mode.actions.rawValue } label: {
                    Label("Raw Events", systemImage: "xmark.circle.fill")
                }
                .help("Showing every recorded event. Click to go back to Steps.")
            } else {
            Picker("View", selection: Binding(get: { mode.rawValue }, set: { viewMode = $0 })) {
                Text("Visual").tag("visual")
                Text("Steps").tag("actions")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Visual: where and when things happen. Steps: a readable list.")
            }
            ControlGroup {
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)")
            }
            .fixedSize()
            if mode != .raw, !macro.steps.isEmpty {
                Toggle(isOn: $showDetails) { Image(systemName: "sidebar.right") }
                    .toggleStyle(.button)
                    .help(showDetails ? "Hide step details (⌥⌘I)" : "Show step details (⌥⌘I)")
                    .accessibilityLabel("Step details")
            }
        }
    }

    private func keepAName() {
        // One line (a pasted line break would break the list row), and never empty.
        if name.contains(where: \.isNewline) { name = name.split(whereSeparator: \.isNewline).joined(separator: " ") }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = "Untitled Macro" }
    }

    private var stats: String {
        let actions = ActionGrouper.groups(for: macro.steps).count
        var s = "\(actions) step\(actions == 1 ? "" : "s") · \(formatDuration(macro.duration))"
        if model.live[macro.id] == nil, let next = model.nextScheduledRun(macro) {
            s += " · next run " + next.formatted(.relative(presentation: .named))
        }
        return s
    }

    // MARK: Live strip: what a running macro is doing

    private func liveStrip(_ run: AppModel.LiveRun) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let pb = macro.playback
            HStack(spacing: 12) {
                LiveDot()
                VStack(alignment: .leading, spacing: 1) {
                    Text(liveHeadline(run, now: now)).fontWeight(.medium).lineLimit(1)
                    Text("Running for \(Self.clock(now.timeIntervalSince(run.started)))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if pb.stopAfterStep != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("Round \(min(run.rounds + 1, pb.stopAfterCount)) of \(pb.stopAfterCount)")
                            .font(.callout).monospacedDigit()
                        ProgressView(value: Double(run.rounds), total: Double(max(1, pb.stopAfterCount)))
                            .progressViewStyle(.linear).frame(width: 90)
                    }
                    .help("Stops after \(pb.stopAfterCount) rounds; \(run.rounds) done")
                }
                let quiet = now.timeIntervalSince(run.lastActivity)
                if pb.stopIfIdleMinutes > 0 || quiet >= 15 {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Quiet \(Self.clock(quiet))" + (pb.stopIfIdleMinutes > 0 ? " of \(Self.clock(pb.stopIfIdleMinutes * 60))" : ""))
                            .font(.callout).monospacedDigit()
                            .foregroundStyle(pb.stopIfIdleMinutes > 0 && quiet > pb.stopIfIdleMinutes * 45 ? Color.orange : Color.secondary)
                        Text("since the last step").font(.caption).foregroundStyle(.secondary)
                    }
                    .help(pb.stopIfIdleMinutes > 0 ? "Stops if nothing happens for \(Self.clock(pb.stopIfIdleMinutes * 60))" : "Time since a step last happened")
                }
                Button("Stop") {
                    if macro.runsInBackground { model.stopBackground(macro.id) } else { model.stopPlayback() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop this macro (⌘.)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.25)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Running. \(liveHeadline(run, now: now))")
        }
    }

    /// One line on what's happening right now.
    private func liveHeadline(_ run: AppModel.LiveRun, now: Date) -> String {
        if let p = model.playPausing, model.playingMacroID == macro.id {
            return "Next round in \(Int(p.rounded())) s"
        }
        if let id = run.lastFired, let at = run.lastFiredAt, now.timeIntervalSince(at) < 3,
           let i = editing.groups.firstIndex(where: { g in macro.steps[g.range.clamped(to: macro.steps.indices)].contains { $0.id == id } }) {
            return "\(editing.isTouch ? "Tapped" : "Clicked") step \(i + 1): \(editing.groups[i].title(touch: editing.isTouch))"
        }
        if model.playingMacroID == macro.id, let looking = model.playWaitingColor {
            return looking.hasPrefix("#") ? "Waiting for \(looking)" : "Looking for \(looking)"
        }
        if macro.playback.order == .allAtOnce || macro.runsInBackground { return "Watching for any of its steps" }
        return "Playing step \(max(1, model.playStep)) of \(macro.steps.count)"
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Toolbar: settings on the left (summaries; full controls in popovers), building on the right

    /// The four settings chips collapse together (summaries, then names, then icons), so they always read as one set.
    private var toolbarRow: some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(.full)
            toolbarRow(.title)
            toolbarRow(.icon)
        }
    }

    private func toolbarRow(_ style: SettingsChip.Style) -> some View {
        HStack(spacing: 8) {
            Button { ui.showingTarget = true } label: {
                SettingsChip(icon: "scope", title: "Target", value: macro.target.app?.name ?? "Whole screen",
                             isSet: macro.target.app != nil, style: style)
            }
            .buttonStyle(.plain)
            .help("Which app it works in, and how clicks reach it (⌘1): \(targetSummary)")
            .popover(isPresented: $ui.showingTarget, arrowEdge: .bottom) { targetPanel }

            Button { ui.showingPlayback = true } label: {
                SettingsChip(icon: "repeat", title: "Playback", value: playbackShort,
                             isSet: macro.runsInBackground || allAtOnce || macro.playback.repeatMode != .once, style: style)
            }
            .buttonStyle(.plain)
            .help("How it runs (⌘2): \(playbackSummary)")
            .popover(isPresented: $ui.showingPlayback, arrowEdge: .bottom) { playbackPanel }

            Button { ui.showingStops = true } label: {
                SettingsChip(icon: "stop.circle", title: "Stops", value: stopsSummary, isSet: hasAutoStop, style: style)
            }
            .buttonStyle(.plain)
            .help("When a run ends on its own (after a number of rounds, when something appears, after a set time, or if nothing happens) (⌘3): \(stopsSummary.lowercased())")
            .popover(isPresented: $ui.showingStops, arrowEdge: .bottom) { stopsPanel }

            Button { ui.showingSchedule = true } label: {
                SettingsChip(icon: "calendar.badge.clock", title: "Schedule", value: scheduleShort,
                             isSet: macro.schedule?.enabled == true, style: style)
            }
            .buttonStyle(.plain)
            .help("Start it on its own (at set times, every so often, or when its app opens) (⌘4): \(scheduleSummary)")
            .popover(isPresented: $ui.showingSchedule, arrowEdge: .bottom) { schedulePanel }

            Spacer(minLength: 8)
            buildControls
        }
    }

    private var hasPictureSteps: Bool {
        macro.steps.contains { if case .findImage = $0.action { true } else { false } }
    }

    private var allAtOnce: Bool { macro.playback.order == .allAtOnce }

    private var playbackSummary: String {
        let pb = macro.playback
        let bg = macro.runsInBackground ? "in the background · " : ""
        if pb.order == .allAtOnce {
            return bg + "all at once · until it stops"
        }
        var parts = [bg + "\(pb.speed.formatted())×"]
        switch pb.repeatMode {
        case .once: parts.append("once")
        case .times: parts.append("\(pb.loops) times")
        case .untilStopped, .duration: parts.append("until it stops")
        }
        if pb.repeatMode != .once, pb.loopDelay > 0 || pb.loopDelayRandom > 0 {
            let hi = pb.loopDelay + pb.loopDelayRandom
            parts.append(pb.loopDelayRandom > 0 ? "\(pb.loopDelay.formatted())–\(hi.formatted())s apart" : "\(pb.loopDelay.formatted())s apart")
        }
        if pb.skipMouseMoves { parts.append("no moves") }
        return parts.joined(separator: " · ")
    }

    /// Short enough to always fit in the chip: the first time, and how many more.
    private var scheduleShort: String {
        guard let s = macro.schedule, s.enabled else { return "Off" }
        if s.kind == .daily, s.times.count > 1 {
            var first = s; first.times = [s.times.sorted()[0]]
            return first.summary(appName: nil) + " +\(s.times.count - 1)"
        }
        return s.summary(appName: macro.target.app?.name)
    }

    /// The Playback chip's summary: how it repeats, in a word or two (the full summary is in its tooltip).
    private var playbackShort: String {
        let pb = macro.playback
        if macro.runsInBackground { return "In the background" }
        if pb.order == .allAtOnce { return "All at once" }
        switch pb.repeatMode {
        case .once: return "Once"
        case .times: return "\(pb.loops) times"
        case .untilStopped, .duration: return "Until it stops"
        }
    }

    private var scheduleSummary: String {
        guard let s = macro.schedule, s.enabled else { return "Off" }
        return s.summary(appName: macro.target.app?.name)
    }

    private var schedulePanel: some View {
        let on = Binding(get: { macro.schedule?.enabled == true }, set: { v in
            if macro.schedule == nil { macro.schedule = MacroSchedule() }
            macro.schedule?.enabled = v
            if v {
                Notifier.requestPermission()
                // Unattended runs that could go on forever get a time limit to start with (changeable in Stops).
                if canRunForever, macro.playback.stopAfterMinutes == 0 { macro.playback.stopAfterMinutes = 30 }
            }
        })
        let s = macro.schedule ?? MacroSchedule()
        func set<T>(_ kp: WritableKeyPath<MacroSchedule, T>, _ v: T) {
            var x = macro.schedule ?? MacroSchedule(); x[keyPath: kp] = v; macro.schedule = x
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Schedule").font(.headline)
            Toggle(isOn: on) {
                Text("Start on its own")
                Text("Heron starts it at the times you choose. Each run ends the way Stops says.")
            }
            if macro.schedule?.enabled == true {
                Picker("Start", selection: Binding(get: { s.kind }, set: { set(\.kind, $0) })) {
                    ForEach(MacroSchedule.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                switch s.kind {
                case .daily:
                    ForEach(Array(s.times.enumerated()), id: \.offset) { i, t in
                        HStack {
                            DatePicker("At", selection: Binding(
                                get: { Calendar.current.date(byAdding: .minute, value: t, to: Calendar.current.startOfDay(for: Date())) ?? Date() },
                                set: { d in
                                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                    var times = s.times; times[i] = (c.hour ?? 0) * 60 + (c.minute ?? 0); set(\.times, times)
                                }), displayedComponents: .hourAndMinute)
                            if s.times.count > 1 {
                                Button { var times = s.times; times.remove(at: i); set(\.times, times) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).help("Remove this time")
                            }
                        }
                    }
                    Button("Add a Time") { set(\.times, s.times + [min(23 * 60 + 59, (s.times.max() ?? 540) + 60)]) }
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { d in
                            let sym = Calendar.current.veryShortWeekdaySymbols[d - 1]
                            Toggle(sym, isOn: Binding(get: { s.weekdays.contains(d) }, set: { v in
                                var w = s.weekdays; if v { w.insert(d) } else { w.remove(d) }; set(\.weekdays, w)
                            }))
                            .toggleStyle(.button)
                            .help(Calendar.current.weekdaySymbols[d - 1])
                        }
                    }
                case .interval:
                    HStack {
                        Text("Every")
                        TextField("", value: Binding(get: { s.everyMinutes }, set: { set(\.everyMinutes, max(1, $0)) }), format: .number)
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        Text("minutes")
                    }
                case .appOpens:
                    Text(macro.target.app.map { "Starts a few seconds after \($0.name) opens." }
                         ?? "Choose a target app first (Target).")
                        .font(.callout).foregroundStyle(macro.target.app == nil ? .orange : .secondary)
                }
                HStack {
                    Label("Each run stops: \(stopsSummary.prefix(1).lowercased() + stopsSummary.dropFirst())", systemImage: "stop.circle")
                        .foregroundStyle(canRunForever && !hasAutoStop ? .orange : .secondary)
                    Spacer()
                    Button("Stops…") { ui.showingSchedule = false; DispatchQueue.main.async { ui.showingStops = true } }
                        .help("Change how each run ends (⌘3)")
                }
                if let next = model.nextScheduledRun(macro) {
                    Label("Next: \(next.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Toggle(isOn: Binding(get: { SystemState.opensAtLogin }, set: { v in
                    if let e = SystemState.setOpensAtLogin(v) { model.flash(e) }
                    ui.objectWillChange.send()
                })) {
                    Text("Open Heron at login")
                    Text("So schedules keep working after a restart.")
                }
                Picker(selection: $model.prefs.screenAwake) {
                    ForEach(ScreenAwake.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Keep the screen on")
                    Text("So the screen saver and auto-lock don't stop runs. Heron can't run while the Mac is locked, and anyone nearby can use an unlocked Mac.")
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var targetSummary: String {
        let app = macro.target.app?.name ?? "Whole screen"
        return "\(app) · \(macro.target.delivery.label)"
    }

    private var playbackPanel: some View {
        let pb = $macro.playback
        return VStack(alignment: .leading, spacing: 12) {
            Text("Playback").font(.headline)
            Toggle(isOn: Binding(get: { macro.runsInBackground }, set: { on in
                if !on { model.stopBackground(macro.id) }
                macro.runsInBackground = on
            })) {
                Text("Keep running in the background")
                Text("Gets its own on/off switch in the list and runs alongside whatever else is playing. Good for clicking pop-ups whenever they show up.")
            }
            Divider()
            if hasPictureSteps || allAtOnce {
                Picker("Steps run", selection: pb.order) {
                    ForEach(PlaybackOptions.StepOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(allAtOnce
                     ? "Every picture step is watched together, and whichever appears gets clicked, until one of the Stops is reached."
                     : "Steps play from top to bottom, each waiting for the one before it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if allAtOnce {
                Toggle(isOn: pb.prioritized) {
                    Text("Higher steps win")
                    Text("When several are on screen at once, click the one higher in the list (for example OK before Cancel) instead of taking turns.")
                }
                idleTapControls
            } else {
                inOrderPlayback
            }
            if hasPictureSteps {
                Toggle(isOn: $macro.playback.waitForStill) {
                    Text("Wait for things to stop moving")
                    Text("Clicks something only once it's in the same place twice in a row, so it doesn't miss things that slide or animate in.")
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    /// Every way a run ends, in one place.
    private var stopsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stops").font(.headline)
            Text("A run always stops when you press Stop. Add conditions so it stops on its own.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            killswitchControls
            if allAtOnce || macro.runsInBackground {
                Divider()
                Toggle(isOn: Binding(get: { macro.playback.maxClicks > 0 },
                                     set: { macro.playback.maxClicks = $0 ? 100 : 0 })) {
                    Text("After a number of clicks")
                    Text("Counts every click, from any step.")
                }
                if macro.playback.maxClicks > 0 {
                    IntField(title: "After", value: $macro.playback.maxClicks, unit: "clicks", range: 1...10_000_000)
                }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    /// Repeats with no end of its own: only Stops (or you) end it.
    private var canRunForever: Bool {
        allAtOnce || macro.runsInBackground || macro.playback.repeatMode == .untilStopped || macro.playback.repeatMode == .duration
    }

    private var hasAutoStop: Bool {
        let pb = macro.playback
        // A “stop when it appears” only counts once it has something to look for.
        let killswitch = pb.stopWhen.map { k in
            pb.stopAtNumber != nil || k.usesPicture || !(k.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        } ?? false
        return pb.stopAfterStep != nil || killswitch || pb.stopAfterMinutes > 0 || pb.stopIfIdleMinutes > 0
            || (pb.maxClicks > 0 && (allAtOnce || macro.runsInBackground))
    }

    /// The Stops chip's summary: the first condition set, and how many more.
    private var stopsSummary: String {
        let pb = macro.playback
        var parts: [String] = []
        if pb.stopAfterStep != nil { parts.append("after \(pb.stopAfterCount) rounds") }
        if let k = pb.stopWhen {
            if let n = pb.stopAtNumber, k.text != nil { parts.append("at \(n)") }
            else if let t = k.text, !t.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("at “\(t)”") }
            else if !k.png.isEmpty { parts.append("at a picture") }
        }
        if pb.maxClicks > 0, allAtOnce || macro.runsInBackground { parts.append("after \(pb.maxClicks) clicks") }
        if pb.stopAfterMinutes > 0 { parts.append("after \(formatSpan(pb.stopAfterMinutes * 60))") }
        if pb.stopIfIdleMinutes > 0 { parts.append("if idle \(pb.stopIfIdleMinutes.formatted()) min") }
        guard let first = parts.first else { return "When you stop it" }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        return parts.count > 1 ? "\(head) +\(parts.count - 1)" : head
    }

    /// “Stop when…”: a picture or words that end the run whenever they show up (a goal, like a “Finished” message).
    private var killswitchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("When something appears")
                Spacer()
                if macro.playback.stopWhen == nil {
                    Button("Picture…") { addPictureStep(for: .killswitch) }
                        .disabled(macro.target.app == nil)
                    Button("Words") {
                        var k = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
                        k.text = ""
                        k.mode = .stop
                        macro.playback.stopWhen = k
                    }
                    .disabled(macro.target.app == nil)
                } else {
                    Button("Remove") { macro.playback.stopWhen = nil }
                }
            }
            if let k = macro.playback.stopWhen {
                if k.text != nil && !k.usesPicture {
                    Picker("", selection: Binding(get: { macro.playback.stopAtNumber != nil },
                                                  set: { macro.playback.stopAtNumber = $0 ? (macro.playback.stopAtNumber ?? 10) : nil })) {
                        Text("These words").tag(false)
                        Text("A number reaching").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                HStack(spacing: 8) {
                    if k.text != nil && !k.usesPicture, let n = macro.playback.stopAtNumber {
                        Text("At least").foregroundStyle(.secondary)
                        TextField("", value: Binding(get: { n }, set: { macro.playback.stopAtNumber = max(0, $0) }), format: .number)
                            .frame(width: 70)
                        Text("in the area below").foregroundStyle(.secondary)
                    } else if k.text != nil {
                        TextField("", text: Binding(get: { macro.playback.stopWhen?.text ?? "" },
                                                    set: { macro.playback.stopWhen?.text = $0 }),
                                  prompt: Text("Finished"))
                        if k.usesPicture {
                            Text("or").foregroundStyle(.secondary)
                            PictureThumbnail(png: k.png, maxWidth: 80, maxHeight: 30)
                                .help("Stops when either the words or this picture show up")
                        }
                    } else {
                        PictureThumbnail(png: k.png, maxWidth: 140, maxHeight: 40)
                        Spacer()
                        Button("Pick Again…") { addPictureStep(for: .killswitch) }
                    }
                }
                HStack {
                    Text(k.area.map { "Looks in a \(Int($0.width)) × \(Int($0.height)) area" } ?? "Looks in the whole window")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(k.area == nil ? "Choose Area…" : "Change Area…") { addPictureStep(for: .killswitchArea) }
                    if k.area != nil { Button("Whole Window") { macro.playback.stopWhen?.area = nil } }
                }
                .font(.callout)
            }
            Text(macro.target.app == nil
                 ? "Choose a target app first; Heron watches its window."
                 : macro.playback.stopAtNumber != nil
                 ? "Heron reads the numbers in the area during the whole run and stops once one reaches your number, like a score or a level. Choose a small area around it."
                 : "Heron watches for it during the whole run and stops as soon as it shows up, like a “Finished” message or a final screen. A small area avoids look-alikes elsewhere on screen.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            // After a step has happened a number of times (one per appearance), e.g. 5 runs.
            let choices = editing.stepChoices()
            Toggle(isOn: Binding(get: { macro.playback.stopAfterStep != nil },
                                 set: { macro.playback.stopAfterStep = $0 ? choices.first?.id : nil })) {
                Text("Stop after a step happens a number of times")
                Text("Pick the step that happens once per round, like a Start button, to stop after that many rounds. Repeat taps and pop-ups don't count.")
            }
            .disabled(choices.isEmpty)
            if macro.playback.stopAfterStep != nil {
                HStack {
                    Picker("", selection: Binding(get: { macro.playback.stopAfterStep }, set: { macro.playback.stopAfterStep = $0 })) {
                        ForEach(choices, id: \.id) { c in Text(c.title).tag(Optional(c.id)) }
                    }
                    .labelsHidden()
                    TextField("", value: Binding(get: { macro.playback.stopAfterCount }, set: { macro.playback.stopAfterCount = max(1, $0) }), format: .number).frame(width: 50)
                    Text("times").foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { macro.playback.stopAfterMinutes > 0 },
                                 set: { macro.playback.stopAfterMinutes = $0 ? 30 : 0 })) {
                Text("After a set time")
                Text("Every run ends after this long, whether you started it or its schedule did.")
            }
            if macro.playback.stopAfterMinutes > 0 {
                NumberField(title: "After", value: Binding(get: { macro.playback.stopAfterMinutes },
                                                           set: { macro.playback.stopAfterMinutes = max(0.1, $0) }), unit: "min")
            }
            Divider()
            Toggle(isOn: Binding(get: { macro.playback.stopIfIdleMinutes > 0 },
                                 set: { macro.playback.stopIfIdleMinutes = $0 ? 5 : 0 })) {
                Text("Stop if nothing happens for a while")
                Text("A safety net for unattended runs: stops and notifies you if no step has happened for this long.")
            }
            if macro.playback.stopIfIdleMinutes > 0 {
                NumberField(title: "For", value: $macro.playback.stopIfIdleMinutes, unit: "min")
            }
        }
    }

    /// “If nothing shows up for a while, tap here”: gets past tap-to-continue screens and ones never seen before.
    private var idleTapControls: some View {
        let pb = $macro.playback
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { macro.playback.idleTapAfter > 0 },
                                 set: { macro.playback.idleTapAfter = $0 ? 4 : 0 })) {
                Text("Tap when stuck")
                Text("If nothing in the list shows up for a while, tap a spot you choose, like the middle of a “tap to continue” screen. Each time, the screen is kept under Stuck Screens.")
            }
            if macro.playback.idleTapAfter > 0 {
                HStack(spacing: 6) {
                    Text("After")
                    TextField("", value: pb.idleTapAfter, format: .number).frame(width: 44)
                    Text("s, tap")
                    if let x = macro.playback.idleTapX, let y = macro.playback.idleTapY {
                        Text("\(Int(x)), \(Int(y))").monospacedDigit().foregroundStyle(.secondary)
                    } else {
                        Text("a spot").foregroundStyle(.orange)
                    }
                    Button("Pick Spot…") {
                        model.captureSpot(in: macro.target.app) { p, _ in
                            macro.playback.idleTapX = Double(p.x.rounded())
                            macro.playback.idleTapY = Double(p.y.rounded())
                        }
                    }
                    .help("Hover over the spot; it's taken after a 3 second countdown")
                }
                .font(.callout)
            }
        }
    }

    /// “Describe”: a sentence becomes steps (on this Mac, with Apple Intelligence).
    private var describePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Describe what to do").font(.headline)
            TextField("", text: $ui.describeText, prompt: Text("Tap Claim, wait 2 seconds, then tap Close"), axis: .vertical)
                .lineLimit(3...5)
                .frame(width: 320)
            if !Assistant.modelAvailable {
                Text("Needs Apple Intelligence, which isn't available on this Mac.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("Steps are drafted on this Mac. Check them before playing.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ui.describing ? "Drafting…" : "Add Steps") { describe() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ui.describing || ui.describeText.trimmingCharacters(in: .whitespaces).isEmpty || !Assistant.modelAvailable)
            }
        }
        .padding(14)
    }

    private func describe() {
        ui.describing = true
        let text = ui.describeText, app = macro.target.app
        Task { @MainActor in
            // The words on the target window right now, so clicks use real labels.
            var labels: [String] = []
            if let app, let img = await model.windowPicture(for: app), let px = ScreenReader.WindowPixels(image: img) {
                labels = await Task.detached { TextFinder.read(px).map { $0.text } }.value
            }
            let planned = await Assistant.buildSteps(from: text, screenLabels: labels) ?? []
            ui.describing = false
            guard !planned.isEmpty else { model.flash("Couldn't turn that into steps. Try simpler wording, one step at a time."); return }
            var added: [UUID] = []
            for p in planned {
                switch p {
                case .click(let label):
                    var step = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
                    step.text = label
                    step.timeout = 10
                    step.otherwise = .stopMacro
                    added.append(insert(.findImage(step), delay: 0.1))
                case .wait(let s): added.append(insert(.wait, delay: s))
                case .type(let t): insertText(t)
                case .press(let k):
                    let code: UInt16 = switch k.lowercased() { case "tab": 48; case "space": 49; case "esc", "escape": 53; default: 36 }
                    insertKeyPress(code)
                }
            }
            ui.showingDescribe = false
            ui.describeText = ""
            if let first = added.first { ui.selection = [first] }
            model.flash("Added \(planned.count) step\(planned.count == 1 ? "" : "s"). Check them before playing.")
        }
    }

    private var inOrderPlayback: some View {
        let pb = $macro.playback
        return VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Speed") {
                HStack(spacing: 4) {
                    TextField("", value: pb.speed, format: .number).frame(width: 55)
                    Text("×").foregroundStyle(.secondary)
                    Menu("Presets") {
                        ForEach([0.25, 0.5, 1, 2, 4, 10], id: \.self) { v in
                            Button("\(v.formatted())×") { macro.playback.speed = v }
                        }
                    }
                    .fixedSize()
                }
            }
            Picker("Repeat", selection: pb.repeatMode) {
                ForEach([PlaybackOptions.RepeatMode.once, .times, .untilStopped]) { Text($0.label).tag($0) }
            }
            if macro.playback.repeatMode == .times {
                IntField(title: "Times", value: pb.loops, range: 1...1_000_000)
            } else if macro.playback.repeatMode == .untilStopped {
                Text("Repeats until one of the Stops is reached, or you press Stop. Time limits are in Stops (⌘3).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if macro.playback.repeatMode != .once {
                NumberField(title: "Wait between loops", value: pb.loopDelay, unit: "s")
                NumberField(title: "Plus a random extra of up to", value: pb.loopDelayRandom, unit: "s")
                if let first = editing.groups.first, case .image(let p) = first.kind, p.mode != .gone, p.mode != .stop,
                   p.untilAppears {
                    Label("Each loop starts when step 1 appears: Heron idles until then, however long the last run took.",
                          systemImage: "viewfinder")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Tip: make step 1 a picture that waits until it appears, and each loop starts when it shows up instead of on a timer.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            Toggle(isOn: Binding(get: { macro.playback.varyTiming > 0 },
                                 set: { macro.playback.varyTiming = $0 ? 0.2 : 0 })) {
                Text("Vary the timing")
                Text("Each wait between steps comes a little early or late, so the rhythm isn't exact.")
            }
            if macro.playback.varyTiming > 0 {
                NumberField(title: "By up to", value: Binding(get: { (macro.playback.varyTiming * 100).rounded() },
                                                            set: { macro.playback.varyTiming = min(max($0, 1), 90) / 100 }),
                            unit: "%")
            }
            Toggle("Skip mouse moves", isOn: pb.skipMouseMoves)
            Text("Only replay clicks, swipes, scrolls and keys. Timing stays the same.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var targetPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Target").font(.headline)
            TargetControls(target: $macro.target, onSelectApp: { model.setMacroTarget(macro.id, $0) })
        }
        .padding(16)
        .frame(width: 460)
    }

    // MARK: Editing toolbar

    /// Building: Find Picture (the main way) and one Add menu with every other kind of step, each named and grouped;
    /// the new step is selected so its settings show in the details panel.
    private var buildControls: some View {
        HStack(spacing: 6) {
            Button { addPictureStep() } label: {
                if ui.compactAdd { Image(systemName: "viewfinder") } else { Label("Find Picture", systemImage: "viewfinder") }
            }
            .fixedSize()
            .help("Box a picture on the window; Heron waits for it, then clicks it")
            .accessibilityLabel("Find Picture")

            Menu {
                Section("Find on screen") {
                    Button { addPictureStep() } label: { Label("Find Picture…", systemImage: "viewfinder") }
                    Button { addTextStep() } label: { Label("Find Text", systemImage: "text.viewfinder") }
                    Button {
                        model.captureSpot(in: macro.target.app) { p, hex in
                            select(insert(.waitForColor(at: p, .detect(hex ?? "#FFFFFF")), delay: 0.1))
                        }
                    } label: { Label("Wait for a Color… (hover, 3 s)", systemImage: "eyedropper") }
                }
                Section("Do") {
                    Button {
                        model.captureSpot(in: macro.target.app) { p, _ in
                            select(insert(.click(button: .left, x: Double(p.x.rounded()), y: Double(p.y.rounded()), count: 1)))
                        }
                    } label: { Label("Click a Spot… (hover, 3 s)", systemImage: "cursorarrow.click") }
                    Button { ui.showingType = true } label: { Label("Type Text…", systemImage: "keyboard") }
                    Button { select(insert(.typeList(TypeList()), delay: 0.1)) } label: {
                        Label("Type From a List", systemImage: "list.bullet.rectangle")
                    }
                    Menu {
                        Button("Return") { insertKeyPress(36) }
                        Button("Space") { insertKeyPress(49) }
                        Button("Tab") { insertKeyPress(48) }
                        Button("Esc") { insertKeyPress(53) }
                    } label: { Label("Press a Key", systemImage: "return") }
                    Menu {
                        Button("Scroll Down") { select(insert(.scroll(dx: 0, dy: -100))) }
                        Button("Scroll Up") { select(insert(.scroll(dx: 0, dy: 100))) }
                    } label: { Label("Scroll", systemImage: "scroll") }
                    Menu {
                        Button("Click") { select(insert(.click(button: .left, x: nil, y: nil, count: 1))) }
                        Button("Double-Click") { select(insert(.click(button: .left, x: nil, y: nil, count: 2))) }
                        Button("Right-Click") { select(insert(.click(button: .right, x: nil, y: nil, count: 1))) }
                    } label: { Label("Click Wherever the Pointer Is", systemImage: "cursorarrow") }
                }
                Section("Timing and flow") {
                    Button { select(insert(.wait, delay: 1)) } label: { Label("Wait a Second", systemImage: "clock") }
                    Button {
                        if let first = editing.groups.first.flatMap(editing.actionStepID) {
                            select(insert(.repeatFrom(step: first, times: 2), delay: 0))
                        }
                    } label: { Label("Repeat From an Earlier Step", systemImage: "arrow.counterclockwise") }
                    .disabled(macro.steps.isEmpty)
                }
                Section {
                    Button { ui.showingDescribe = true } label: { Label("Describe in Words… (Apple Intelligence)", systemImage: "sparkles") }
                }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .fixedSize()
            .help("Add a step after the selected one")
            .popover(isPresented: $ui.showingType, arrowEdge: .bottom) {
                TypeTextPopover { text in insertText(text); ui.showingType = false }
            }
            .popover(isPresented: $ui.showingDescribe, arrowEdge: .bottom) { describePopover }

            moreMenu
        }
        .popover(isPresented: $ui.showingBulkDelay) {
            HStack {
                Text("Delay")
                TextField("", value: $ui.bulkDelay, format: .number).frame(width: 60)
                Text("s")
                Button("Apply") {
                    for i in macro.steps.indices where selection.isEmpty || selection.contains(macro.steps[i].id) {
                        macro.steps[i].delay = max(0, ui.bulkDelay)
                    }
                    ui.showingBulkDelay = false
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    /// Everything else, grouped: the selected steps, timing, improving from past runs, and the macro itself.
    private var moreMenu: some View {
        Menu {
            Section("Selected steps") {
                Menu("Move") {
                    Button("To Top  ⌥⇧⌘↑") { editing.move(nil, .top) }.disabled(!editing.canMove(nil, .top))
                    Button("Up  ⌥⌘↑") { editing.move(nil, .up) }.disabled(!editing.canMove(nil, .up))
                    Button("Down  ⌥⌘↓") { editing.move(nil, .down) }.disabled(!editing.canMove(nil, .down))
                    Button("To Bottom  ⌥⇧⌘↓") { editing.move(nil, .bottom) }.disabled(!editing.canMove(nil, .bottom))
                }
                .disabled(selection.isEmpty)
                Button("Click Their Spots Instead") { editing.setSpotOnly(nil, true) }
                    .disabled(editing.clickFinders(nil).isEmpty)
                Button("Find Their Pictures Again") { editing.setSpotOnly(nil, false) }
                    .disabled(editing.clickFinders(nil).isEmpty)
                Button("Combine Pictures into One Step") { editing.combinePictures() }
                    .disabled(editing.combinablePictures.count < 2)
                Button("Delete", role: .destructive) { deleteSelected() }.disabled(selection.isEmpty)
                Button("Select All") { selection = Set(macro.steps.map(\.id)) }
            }
            Menu("Timing") {
                Button("Set Delay of \(selection.isEmpty ? "All" : "Selected") Steps…") { ui.showingBulkDelay = true }
                Button("Halve All Delays (2× faster)") { scaleDelays(0.5) }
                Button("Double All Delays (2× slower)") { scaleDelays(2) }
                Button("Cap Delays at 1 Second") { capDelays(1) }
                Divider()
                Button("Remove All Mouse Moves") {
                    macro.steps = Player.removingMoves(macro.steps)
                    selection.removeAll()
                }
            }
            Menu("Improve") {
                let narrow = model.narrowableSteps(in: macro)
                Button(narrow.isEmpty ? "Narrow Searches to Where Things Show Up"
                                      : "Narrow \(narrow.count) Search\(narrow.count == 1 ? "" : "es") to Where Things Show Up") {
                    narrowSearches(narrow)
                }
                .disabled(narrow.isEmpty)
                Button("Stuck Screens…") { ui.showingStuck = true }
                Button("Autopilot (Experimental)…") { ui.showingAutopilot = true }
            }
            Divider()
            Toggle("Show Raw Events", isOn: Binding(get: { mode == .raw }, set: { viewMode = $0 ? Mode.raw.rawValue : Mode.actions.rawValue }))
            Button("Duplicate Macro") { model.duplicate(macro) }
            Button("Export…") { model.export(macro) }
            Button("Show Macro Files in Finder") { model.revealMacroFolder() }
            Divider()
            Button("Delete Macro", role: .destructive) { model.delete(macro) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More: selected steps, timing, improving from past runs, and the macro")
    }

    // MARK: Steps

    private var stepsList: some View {
        Group {
            if macro.steps.isEmpty && !ui.blankChosen {
                TemplateChooser(app: macro.target.app, selected: $ui.template, isRecording: model.isRecording,
                                onSelectApp: { model.setMacroTarget(macro.id, $0) },
                                onStart: startTemplate)
            } else if macro.steps.isEmpty {
                EmptyMacroPrompt(appName: macro.target.app?.name, onAddPicture: { addPictureStep() },
                                 onRecord: { model.record(into: macro.id, app: macro.target.app) })
            } else {
                switch mode {
                case .visual:
                    VisualMacroView(editing: editing, ui: ui, onShowRaw: showRawSteps,
                                    onAddColorCheck: addColorCheck, onSampleColor: sampleColor, onEditPicture: editPicture)
                        .onDeleteCommand { deleteSelected() }
                case .actions:
                    SimpleStepsList(editing: editing, onShowRaw: showRawSteps, onDelete: deleteSelected,
                                    onAddColorCheck: addColorCheck, onSampleColor: sampleColor, onEditPicture: editPicture)
                case .raw:
                    detailedList
                }
            }
        }
        // Picking the picture for a new step.
        .sheet(item: Binding(get: { ui.pictureSource.map(ImageSheetItem.init) }, set: { ui.pictureSource = $0?.image })) { item in
            RegionPickerSheet(image: item.image) { rect in
                ui.pictureSource = nil
                guard let c = PictureCrop.crop(rect, from: item.image) else { return }
                var pic = ImageStep(png: c.png, width: c.width, height: c.height,
                                    originX: Double(rect.minX), originY: Double(rect.minY))
                // The window's size when picked, so the picture can be resized if the window changes size.
                pic.captureWindow = item.image.size
                if macro.target.windowSize == nil { macro.target.windowSize = item.image.size }
                switch ui.picking {
                case .step:
                    select(insert(.findImage(pic), delay: macro.steps.isEmpty ? 0 : 0.1))
                case .appearTemplate:
                    // “Click it whenever it appears”: watched all the time, clicked each time it shows up.
                    macro.playback.order = .allAtOnce
                    macro.playback.repeatMode = .untilStopped
                    select(insert(.findImage(pic), delay: 0))
                    model.flash("Ready. Press Play, and Heron clicks it whenever it shows up.")
                case .killswitch:
                    pic.mode = .stop
                    pic.area = macro.playback.stopWhen?.area
                    macro.playback.stopWhen = pic
                    ui.showingStops = true
                case .killswitchArea:
                    macro.playback.stopWhen?.area = rect.integral
                    ui.showingStops = true
                }
                ui.picking = .step
            } onCancel: {
                ui.pictureSource = nil
                if ui.picking == .killswitch || ui.picking == .killswitchArea { ui.showingStops = true }
                ui.picking = .step
            }
        }
    }

    /// Starts a template: box a picture, or record into this macro (the rest follows when recording ends).
    private func startTemplate(_ t: MacroTemplate) {
        switch t {
        case .blank:
            ui.blankChosen = true
        case .whenItAppears:
            addPictureStep(for: .appearTemplate)
        case .inOrder, .onSchedule, .untilDone:
            ui.templateFollowUp = t
            model.record(into: macro.id, app: macro.target.app)
        }
    }

    /// After a template's recording: set up what the template promised.
    private func finishTemplate() {
        guard let t = ui.templateFollowUp, model.recordedInto == macro.id, !macro.steps.isEmpty else { return }
        ui.templateFollowUp = nil
        switch t {
        case .onSchedule:
            macro.schedule = MacroSchedule()
            Notifier.requestPermission()
            ui.showingSchedule = true
        case .untilDone:
            macro.playback.repeatMode = .untilStopped
            ui.showingStops = true
            model.flash("Now choose what it shows when it's finished, under When something appears.")
        default:
            break
        }
    }

    /// Screenshot the target window, then let the user box the picture to look for (or the killswitch).
    private func addPictureStep(for purpose: DetailUIState.Picking = .step) {
        ui.picking = purpose
        if purpose != .step { ui.showingStops = false }
        guard let app = macro.target.app else {
            model.flash("Choose the app to watch first (Target button).")
            ui.showingTarget = true
            return
        }
        Task { @MainActor in
            if let img = await model.windowPicture(for: app) { ui.pictureSource = img }
        }
    }

    /// A step that reads the window for some text; the editor opens so it can be typed in.
    private func addTextStep() {
        var step = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
        step.text = ""
        select(insert(.findImage(step), delay: macro.steps.isEmpty ? 0 : 0.1))
    }

    /// Picture steps are edited in the details panel: selecting one shows it there.
    private func editPicture(_ g: ActionGroup) {
        editing.select(g)
        showDetails = true
    }

    private func updateCompact(_ width: CGFloat) {
        // The settings panel takes about a third of a wide editor (300 to 400 points).
        let inspector = min(400, max(300, (width * 0.3).rounded()))
        if ui.inspectorWidth != inspector { ui.inspectorWidth = inspector }
        let compact = width < 700
        if ui.compactAdd != compact { ui.compactAdd = compact }
    }

    private func select(_ id: UUID) {
        ui.selection = [id]
        ui.scrollTarget = id
    }

    private func addButton(_ title: String, _ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Narrow editor: icons only (the name is in the tooltip and for VoiceOver).
            if ui.compactAdd { Image(systemName: icon) } else { Label(title, systemImage: icon) }
        }
        .fixedSize()
        .help(ui.compactAdd ? "\(title): \(help)" : help)
        .accessibilityLabel(title)
    }

    /// "Type": each character becomes a key press (with Shift where needed).
    private func insertText(_ text: String) {
        var new: [MacroStep] = []
        var skipped = 0
        for ch in text {
            guard let k = KeyText.key(for: ch) else { skipped += 1; continue }
            let flags: UInt64 = k.shift ? CGEventFlags.maskShift.rawValue : 0
            new.append(MacroStep(delay: new.isEmpty ? 0.1 : 0.05, action: .key(keyCode: k.code, down: true, flags: flags)))
            new.append(MacroStep(delay: 0.03, action: .key(keyCode: k.code, down: false, flags: flags)))
        }
        guard !new.isEmpty else { model.flash("Those characters can't be typed with this keyboard layout."); return }
        let idx = macro.steps.lastIndex { selection.contains($0.id) }.map { $0 + 1 } ?? macro.steps.count
        macro.steps.insert(contentsOf: new, at: idx)
        ui.selection = Set(new.map(\.id))
        if skipped > 0 { model.flash("\(skipped) character\(skipped == 1 ? "" : "s") can't be typed with this keyboard layout and were left out.") }
    }

    private var detailedList: some View {
        ScrollViewReader { proxy in
            List(selection: $ui.selection) {
                ForEach($macro.steps) { $step in
                    StepRow(step: $step, index: (macro.steps.firstIndex { $0.id == step.id } ?? 0) + 1,
                            currentPoint: { [target = macro.target.app] in model.currentPoint(relativeTo: target) })
                        .tag(step.id)
                }
                .onMove { macro.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .onDeleteCommand { deleteSelected() }
            .overlay {
                if macro.steps.isEmpty {
                    Text("No steps. Record something, or use the buttons above.").foregroundStyle(.secondary)
                }
            }
            .onAppear {
                // Arriving from "Show raw steps": jump to the action's first step.
                guard let id = ui.scrollTarget else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .top)
                    ui.scrollTarget = nil
                }
            }
        }
    }

    private var selectionLabel: String {
        guard isSimple else { return "\(selection.count) selected" }
        let n = ActionGrouper.groups(for: macro.steps).filter { g in
            macro.steps[g.range].contains { selection.contains($0.id) }
        }.count
        return "\(n) selected"
    }

    private func showRawSteps(_ g: ActionGroup) {
        guard g.range.upperBound <= macro.steps.count else { return }
        selection = Set(macro.steps[g.range].map(\.id))
        ui.scrollTarget = g.id
        viewMode = Mode.raw.rawValue
    }

    /// "Only tap if the color matches": inserts a color check before the action, using the color there now.
    private func addColorCheck(_ g: ActionGroup) {
        guard let id = editing.addColorCheck(before: g), let p = g.editablePoint else { return }
        model.sampleColor(atRelative: p, in: macro.target.app) { [editing] hex in
            if let hex { editing.setColor(stepID: id, hex: hex) }
        }
    }

    /// Refresh a color check with whatever color is at its spot right now.
    private func sampleColor(_ g: ActionGroup) {
        guard let p = g.editablePoint, let binding = editing.colorBinding(g) else { return }
        model.sampleColor(atRelative: p, in: macro.target.app) { hex in
            if let hex { binding.wrappedValue.hex = hex }
        }
    }

    // MARK: Actions

    @discardableResult
    private func insert(_ action: StepAction, delay: Double = 0.1) -> UUID {
        let step = MacroStep(delay: delay, action: action)
        let idx = macro.steps.lastIndex { selection.contains($0.id) }.map { $0 + 1 } ?? macro.steps.count
        macro.steps.insert(step, at: idx)
        selection = [step.id]
        return step.id
    }

    private func insertKeyPress(_ code: UInt16) {
        let down = MacroStep(delay: 0.1, action: .key(keyCode: code, down: true, flags: 0))
        let up = MacroStep(delay: 0.05, action: .key(keyCode: code, down: false, flags: 0))
        let idx = macro.steps.lastIndex { selection.contains($0.id) }.map { $0 + 1 } ?? macro.steps.count
        macro.steps.insert(contentsOf: [down, up], at: idx)
        selection = [up.id]
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        macro.steps.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    private func narrowSearches(_ narrow: [(id: UUID, area: CGRect)]) {
        for n in narrow {
            if let i = macro.steps.firstIndex(where: { $0.id == n.id }), case .findImage(var p) = macro.steps[i].action {
                p.area = n.area
                macro.steps[i].action = .findImage(p)
            }
        }
        model.flash("Narrowed \(narrow.count) search\(narrow.count == 1 ? "" : "es"). Undo with ⌘Z.")
    }

    private func scaleDelays(_ f: Double) {
        for i in macro.steps.indices { macro.steps[i].delay *= f }
    }

    private func capDelays(_ cap: Double) {
        for i in macro.steps.indices { macro.steps[i].delay = min(macro.steps[i].delay, cap) }
    }
}

final class DetailUIState: ObservableObject {
    @Published var selection = Set<UUID>()
    @Published var bulkDelay: Double = 0.1
    @Published var showingBulkDelay = false
    @Published var showingType = false
    /// The editor is too narrow for labelled Add buttons.
    @Published var compactAdd = false
    @Published var inspectorWidth: CGFloat = 300
    @Published var showingDescribe = false
    @Published var describeText = ""
    @Published var describing = false
    @Published var showingStuck = false
    @Published var showingSchedule = false
    @Published var showingStops = false
    @Published var showingPresses = false
    @Published var showingAutopilot = false
    /// Step to scroll to when the detailed list appears.
    var scrollTarget: UUID?
    /// Marker being dragged in the visual view, and how far.
    @Published var dragging: UUID?
    @Published var showingPlayback = false
    /// Screenshot to pick a new picture step from.
    @Published var pictureSource: NSImage?
    /// What the picture being boxed is for.
    enum Picking { case step, appearTemplate, killswitch, killswitchArea }
    /// Template picked in an empty macro, “Blank” chosen, and the template waiting for its recording to end.
    @Published var template = MacroTemplate.whenItAppears
    @Published var blankChosen = false
    var templateFollowUp: MacroTemplate?
    var picking = Picking.step
    /// Picture step whose editor is open.
    @Published var editingPicture: UUID?
    @Published var showingTarget = false
    @Published var dragOffset: CGSize = .zero
}

struct StepRow: View {
    @Binding var step: MacroStep
    let index: Int
    let currentPoint: () -> CGPoint?

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            HStack(spacing: 2) {
                Text("+").foregroundStyle(.secondary)
                TextField("", value: $step.delay, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("s").foregroundStyle(.secondary)
            }
            .help("Wait this long before the step")
            Image(systemName: step.action.icon)
                .frame(width: 20)
                .foregroundStyle(.tint)
            Text(step.action.summary)
                .lineLimit(1)
            Spacer()
            if step.action.hasEditablePoint {
                if let p = step.action.point {
                    Text("x").foregroundStyle(.secondary)
                    TextField("", value: coord(\.x, p), format: .number.precision(.fractionLength(0))).frame(width: 60)
                    Text("y").foregroundStyle(.secondary)
                    TextField("", value: coord(\.y, p), format: .number.precision(.fractionLength(0))).frame(width: 60)
                } else {
                    Button("Set to current mouse") {
                        if let p = currentPoint() {
                            step.action.point = CGPoint(x: p.x.rounded(), y: p.y.rounded())
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.callout)
    }

    private func coord(_ kp: WritableKeyPath<CGPoint, CGFloat>, _ p: CGPoint) -> Binding<Double> {
        Binding(
            get: { Double(step.action.point?[keyPath: kp] ?? 0) },
            set: { v in
                var np = step.action.point ?? p
                np[keyPath: kp] = CGFloat(v)
                step.action.point = np
            }
        )
    }
}

/// Compact button face: icon, title and a one-line summary.
struct SettingsChip: View {
    enum Style { case full, title, icon }
    let icon: String
    let title: String
    let value: String
    /// Changed from the default: the icon takes the accent colour, so chips read apart even as icons alone.
    var isSet = false
    /// With the summary when it fits; just the name, or just the icon, when space is short (the details are one click away).
    var style: Style = .full

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(isSet ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .symbolVariant(isSet && style == .icon ? .fill : .none)
            if style != .icon { Text(title).fontWeight(.medium) }
            if style == .full { Text(value).foregroundStyle(.secondary) }
            if style == .full { Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary) }
        }
        .lineLimit(1)
        .fixedSize()
        .font(.callout)
        .padding(.horizontal, style == .full ? 10 : 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// A small green dot that breathes while a macro runs (still, with Reduce Motion).
struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state = Pulse()
    final class Pulse: ObservableObject { @Published var on = false }

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 9, height: 9)
            .opacity(reduceMotion ? 1 : (state.on ? 1 : 0.4))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { state.on = true }
            }
            .accessibilityHidden(true)
    }
}


/// Opens one of the open macro's settings panels; the Macro menu's ⌘1–⌘4 use it.
struct MacroPanels {
    enum Panel: CaseIterable { case target, playback, stops, schedule
        var title: String {
            switch self { case .target: "Target…"; case .playback: "Playback…"; case .stops: "Stops…"; case .schedule: "Schedule…" }
        }
    }
    let open: (Panel) -> Void
}

private struct MacroPanelsKey: FocusedValueKey { typealias Value = MacroPanels }

extension FocusedValues {
    var macroPanels: MacroPanels? {
        get { self[MacroPanelsKey.self] }
        set { self[MacroPanelsKey.self] = newValue }
    }
}

/// The Macro menu: the open macro's settings, each a keystroke away.
struct MacroCommands: Commands {
    @FocusedValue(\.macroPanels) private var panels

    var body: some Commands {
        CommandMenu("Macro") {
            ForEach(Array(MacroPanels.Panel.allCases.enumerated()), id: \.offset) { i, p in
                Button(p.title) { panels?.open(p) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(panels == nil)
            }
        }
    }
}
