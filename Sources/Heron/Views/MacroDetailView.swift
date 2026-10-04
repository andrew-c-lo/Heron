import SwiftUI

struct MacroDetailView: View {
    @EnvironmentObject var model: AppModel
    @Binding var macro: Macro
    /// Separate from `macro` so typing a name isn't an undo step per letter.
    @Binding var name: String
    @Environment(\.undoManager) private var undoManager
    // @State is a compiler-plugin macro that the Command Line Tools don't ship, so use an ObservableObject.
    @StateObject private var ui = DetailUIState()
    @AppStorage("stepsViewMode") private var viewMode = "visual"

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
            settingsBar
            addBar
            HStack(spacing: 0) {
                stepsList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if mode != .raw, !macro.steps.isEmpty {
                    Divider()
                    StepInspector(editing: editing, app: macro.target.app, allAtOnce: allAtOnce,
                                  onShowRaw: showRawSteps, onAddColorCheck: addColorCheck,
                                  onSampleColor: sampleColor, onDelete: deleteSelected)
                        .frame(width: 300)
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
        .onAppear { model.loadStuck(for: macro.id); model.loadFoundHistory(for: macro) }
        .background {
            // Keyboard shortcuts for moving the selected steps.
            Group {
                Button("") { editing.move(nil, .up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("") { editing.move(nil, .down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Button("") { editing.move(nil, .top) }.keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                Button("") { editing.move(nil, .bottom) }.keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
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
                    Label("Stuck \(n)×", systemImage: "exclamationmark.triangle")
                }
                .help("Screens where “Tap when stuck” had to step in. Turn them into steps.")
            }
            Picker("View", selection: Binding(get: { mode.rawValue }, set: { viewMode = $0 })) {
                Text("Visual").tag("visual")
                Text("Actions").tag("actions")
                Text("Raw").tag("raw")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Visual: where and when things happen. Actions: a readable list. Raw: every recorded event.")
            ControlGroup {
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)")
            }
            .fixedSize()
        }
    }

    private var stats: String {
        let actions = ActionGrouper.groups(for: macro.steps).count
        var s = "\(actions) action\(actions == 1 ? "" : "s") (\(macro.steps.count) raw steps) · \(formatDuration(macro.duration)) at 1×"
        if isPlaying {
            s += " · playing " + model.playStatus
        }
        return s
    }

    // MARK: Settings bar (summaries; full controls open in popovers to save space)

    private var settingsBar: some View {
        HStack(spacing: 8) {
            Button { ui.showingPlayback = true } label: {
                SettingsChip(icon: "repeat", title: "Playback", value: playbackSummary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $ui.showingPlayback, arrowEdge: .bottom) { playbackPanel }

            Button { ui.showingTarget = true } label: {
                SettingsChip(icon: "scope", title: "Target", value: targetSummary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $ui.showingTarget, arrowEdge: .bottom) { targetPanel }

            Spacer(minLength: 0)
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
            return bg + "all at once · " + (pb.repeatMode == .duration ? "for \(formatDuration(pb.repeatDuration))" : "until stopped")
                + (pb.maxClicks > 0 ? " · up to \(pb.maxClicks) clicks" : "")
        }
        var parts = [bg + "\(pb.speed.formatted())×"]
        switch pb.repeatMode {
        case .once: parts.append("once")
        case .times: parts.append("\(pb.loops) times")
        case .untilStopped: parts.append("until stopped")
        case .duration: parts.append("for \(formatDuration(pb.repeatDuration))")
        }
        if pb.repeatMode != .once, pb.loopDelay > 0 || pb.loopDelayRandom > 0 {
            let hi = pb.loopDelay + pb.loopDelayRandom
            parts.append(pb.loopDelayRandom > 0 ? "\(pb.loopDelay.formatted())–\(hi.formatted())s apart" : "\(pb.loopDelay.formatted())s apart")
        }
        if pb.skipMouseMoves { parts.append("no moves") }
        return parts.joined(separator: " · ")
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
            }
            if allAtOnce {
                Picker("Run", selection: Binding(
                    get: { macro.playback.repeatMode == .duration ? PlaybackOptions.RepeatMode.duration : .untilStopped },
                    set: { macro.playback.repeatMode = $0 })) {
                    Text("Until stopped").tag(PlaybackOptions.RepeatMode.untilStopped)
                    Text("For a duration").tag(PlaybackOptions.RepeatMode.duration)
                }
                if macro.playback.repeatMode == .duration {
                    NumberField(title: "Minutes", value: Binding(get: { macro.playback.repeatDuration / 60 },
                                                               set: { macro.playback.repeatDuration = max(0, $0) * 60 }))
                }
                IntField(title: "Stop after (0 = never)", value: pb.maxClicks, unit: "clicks", range: 0...10_000_000)
                Toggle(isOn: pb.prioritized) {
                    Text("Higher steps win")
                    Text("When several are on screen at once, click the one higher in the list (for example OK before Cancel) instead of taking turns.")
                }
                idleTapControls
                Text("All at once watches every picture step together and clicks whichever appears. Step order, waits and time limits don't apply.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                inOrderPlayback
            }
        }
        .padding(16)
        .frame(width: 380)
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
            guard !planned.isEmpty else { model.flash("Couldn't turn that into steps. Try simpler wording, one action at a time."); return }
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
                ForEach(PlaybackOptions.RepeatMode.allCases) { Text($0.label).tag($0) }
            }
            switch macro.playback.repeatMode {
            case .times:
                IntField(title: "Times", value: pb.loops, range: 1...1_000_000)
            case .duration:
                NumberField(title: "Minutes", value: Binding(get: { macro.playback.repeatDuration / 60 },
                                                           set: { macro.playback.repeatDuration = max(0, $0) * 60 }))
                Text("No new loop starts after this; the loop in progress finishes first.")
                    .font(.caption).foregroundStyle(.secondary)
            case .once, .untilStopped:
                EmptyView()
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

    /// The main way to build a macro: one click per kind of step. The new step is selected so its
    /// settings show in the details panel.
    private var addBar: some View {
        HStack(spacing: 6) {
            addButton("Click", "cursorarrow.click", "Hover over the spot; it's added after a 3 second countdown") {
                model.captureSpot(in: macro.target.app) { p, _ in
                    select(insert(.click(button: .left, x: Double(p.x.rounded()), y: Double(p.y.rounded()), count: 1)))
                }
            }
            addButton("Type", "keyboard", "Type some text") { ui.showingType = true }
                .popover(isPresented: $ui.showingType, arrowEdge: .bottom) {
                    TypeTextPopover { text in insertText(text); ui.showingType = false }
                }
            addButton("Wait", "clock", "Pause for a second") { select(insert(.wait, delay: 1)) }
            addButton("Find Picture", "viewfinder", "Wait for a picture to appear, then click it") { addPictureStep() }
            addButton("Find Text", "text.viewfinder", "Wait for some words to appear, then click them") { addTextStep() }
            addButton("Describe", "sparkles", "Describe what to do in words; Apple Intelligence on this Mac drafts the steps") {
                ui.showingDescribe = true
            }
            .popover(isPresented: $ui.showingDescribe, arrowEdge: .bottom) { describePopover }
            Menu {
                Button("Wait for a Color… (hover the spot, 3 s countdown)") {
                    model.captureSpot(in: macro.target.app) { p, hex in
                        select(insert(.waitForColor(at: p, .detect(hex ?? "#FFFFFF")), delay: 0.1))
                    }
                }
                Divider()
                Button("Click Wherever the Pointer Is") { select(insert(.click(button: .left, x: nil, y: nil, count: 1))) }
                Button("Double-Click Wherever the Pointer Is") { select(insert(.click(button: .left, x: nil, y: nil, count: 2))) }
                Button("Right-Click Wherever the Pointer Is") { select(insert(.click(button: .right, x: nil, y: nil, count: 1))) }
                Button("Stop When Words Appear…") {
                    var step = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
                    step.text = ""
                    select(insert(.findImage(Self.stopStep(step)), delay: 0))
                }
                Button("Stop When a Picture Appears…") { addPictureStep(stop: true) }
                Button("Repeat From an Earlier Step") {
                    if let first = editing.groups.first.flatMap(editing.actionStepID) {
                        select(insert(.repeatFrom(step: first, times: 2), delay: 0))
                    }
                }
                .disabled(macro.steps.isEmpty)
                Divider()
                Button("Scroll Down") { select(insert(.scroll(dx: 0, dy: -100))) }
                Button("Scroll Up") { select(insert(.scroll(dx: 0, dy: 100))) }
                Divider()
                Button("Press Return") { insertKeyPress(36) }
                Button("Press Space") { insertKeyPress(49) }
                Button("Press Tab") { insertKeyPress(48) }
                Button("Press Esc") { insertKeyPress(53) }
            } label: {
                Text("More")
            }
            .fixedSize()
            .help("Other kinds of steps")

            Spacer(minLength: 4)
            Menu {
                Button("Remove All Mouse Moves") {
                    macro.steps = Player.removingMoves(macro.steps)
                    selection.removeAll()
                }
                Divider()
                Button("Halve All Delays (2× faster)") { scaleDelays(0.5) }
                Button("Double All Delays (2× slower)") { scaleDelays(2) }
                Button("Cap Delays at 1 Second") { capDelays(1) }
                Button("Set Delay of \(selection.isEmpty ? "All" : "Selected") Steps…") { ui.showingBulkDelay = true }
                Divider()
                Button("Select All") { selection = Set(macro.steps.map(\.id)) }
                Button("Combine Selected Pictures into One Step") { editing.combinePictures() }
                    .disabled(editing.combinablePictures.count < 2)
                Menu("Move Selected Steps") {
                    Button("To Top  ⌥⇧⌘↑") { editing.move(nil, .top) }.disabled(!editing.canMove(nil, .top))
                    Button("Up  ⌥⌘↑") { editing.move(nil, .up) }.disabled(!editing.canMove(nil, .up))
                    Button("Down  ⌥⌘↓") { editing.move(nil, .down) }.disabled(!editing.canMove(nil, .down))
                    Button("To Bottom  ⌥⇧⌘↓") { editing.move(nil, .bottom) }.disabled(!editing.canMove(nil, .bottom))
                }
                .disabled(selection.isEmpty)
                Button("Delete Selected Steps", role: .destructive) { deleteSelected() }.disabled(selection.isEmpty)
                Divider()
                let narrow = model.narrowableSteps(in: macro)
                Button(narrow.isEmpty ? "Narrow Searches to Where Things Show Up"
                                      : "Narrow \(narrow.count) Search\(narrow.count == 1 ? "" : "es") to Where Things Show Up") {
                    narrowSearches(narrow)
                }
                .disabled(narrow.isEmpty)
                .help("Steps that kept showing up in one part of the window will only look there: faster, and fewer look-alikes.")
                Button("Stuck Screens…") { ui.showingStuck = true }
                Button("Autopilot (Experimental)…") { ui.showingAutopilot = true }
                Divider()
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
            .help("More actions")
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

    // MARK: Steps

    private var stepsList: some View {
        Group {
            if macro.steps.isEmpty {
                EmptyMacroPrompt(appName: macro.target.app?.name, onAddPicture: { addPictureStep() },
                                 onRecord: { model.toggleRecording(fromUI: true) })
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
                if ui.addingStop { pic = Self.stopStep(pic) }
                ui.addingStop = false
                select(insert(.findImage(pic), delay: macro.steps.isEmpty ? 0 : 0.1))
            } onCancel: {
                ui.pictureSource = nil
                ui.addingStop = false
            }
        }
    }

    /// A stop condition: looks briefly each time it's reached, and ends the macro if it's there.
    static func stopStep(_ s: ImageStep) -> ImageStep {
        var s = s
        s.mode = .stop
        s.timeout = 1
        s.otherwise = .continueAnyway
        return s
    }

    /// Screenshot the target window, then let the user box the picture to look for.
    private func addPictureStep(stop: Bool = false) {
        ui.addingStop = stop
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
    }

    private func updateCompact(_ width: CGFloat) {
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
    @Published var showingDescribe = false
    @Published var describeText = ""
    @Published var describing = false
    @Published var showingStuck = false
    @Published var showingPresses = false
    @Published var showingAutopilot = false
    /// Step to scroll to when the detailed list appears.
    var scrollTarget: UUID?
    /// Marker being dragged in the visual view, and how far.
    @Published var dragging: UUID?
    @Published var showingPlayback = false
    /// Screenshot to pick a new picture step from.
    @Published var pictureSource: NSImage?
    /// The picture being picked is for a “Stop when it appears” step.
    var addingStop = false
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
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(value).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.6)))
        .contentShape(Rectangle())
    }
}
