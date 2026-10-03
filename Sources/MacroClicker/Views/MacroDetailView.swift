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
            toolbar
            if hasPictureSteps { orderBar }
            stepsList
                .frame(maxHeight: .infinity)
        }
        .padding(.leading, 10)
        .padding(.bottom, 8)
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

    /// In order vs. all at once, right above the steps it affects.
    private var orderBar: some View {
        HStack(spacing: 10) {
            Text("Steps run").foregroundStyle(.secondary)
            Picker("Steps run", selection: $macro.playback.order) {
                ForEach(PlaybackOptions.StepOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // The explanation is one hover away instead of always on screen.
            .help(allAtOnce
                  ? "Every picture is watched at the same time; whichever appears gets \(editing.isTouch ? "tapped" : "clicked"). Runs until stopped."
                  : "One after another, top to bottom.")
            Spacer(minLength: 0)
        }
    }

    private var playbackSummary: String {
        let pb = macro.playback
        if pb.order == .allAtOnce {
            return "all at once · " + (pb.repeatMode == .duration ? "for \(formatDuration(pb.repeatDuration))" : "until stopped")
        }
        var parts = ["\(pb.speed.formatted())×"]
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
                Text("All at once watches every picture step together and clicks whichever appears. Step order, waits and time limits don't apply.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                inOrderPlayback
            }
        }
        .padding(16)
        .frame(width: 380)
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

    private var toolbar: some View {
        HStack {
            Menu {
                Button("Picture step… (wait for a picture, then click it)") { addPictureStep() }
                Button("Text step… (wait for some text, then click it)") { addTextStep() }
                Divider()
                Button("Wait (1s)") { insert(.wait, delay: 1) }
                Button("Wait for a color… (hover the spot, 3s countdown)") {
                    model.captureSpot(in: macro.target.app) { p, hex in
                        insert(.waitForColor(at: p, .detect(hex ?? "#FFFFFF")), delay: 0.1)
                    }
                }
                Divider()
                Button("Left click at cursor (wherever it is)") { insert(.click(button: .left, x: nil, y: nil, count: 1)) }
                Button("Left click at current mouse position") {
                    if let p = model.currentPoint(relativeTo: macro.target.app) {
                        insert(.click(button: .left, x: Double(p.x.rounded()), y: Double(p.y.rounded()), count: 1))
                    }
                }
                Button("Double click at cursor") { insert(.click(button: .left, x: nil, y: nil, count: 2)) }
                Button("Right click at cursor") { insert(.click(button: .right, x: nil, y: nil, count: 1)) }
                Divider()
                Button("Scroll down") { insert(.scroll(dx: 0, dy: -100)) }
                Button("Scroll up") { insert(.scroll(dx: 0, dy: 100)) }
                Divider()
                Button("Press Return") { insertKeyPress(36) }
                Button("Press Space") { insertKeyPress(49) }
                Button("Press Tab") { insertKeyPress(48) }
                Button("Press Esc") { insertKeyPress(53) }
            } label: {
                Label("Insert", systemImage: "plus")
            }
            .fixedSize()
            .help("Inserts after the selection (or at the end)")

            Button(role: .destructive) { deleteSelected() } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)

            Menu {
                Button("Remove all mouse moves") {
                    macro.steps = Player.removingMoves(macro.steps)
                    selection.removeAll()
                }
                Divider()
                Button("Halve all delays (2× faster)") { scaleDelays(0.5) }
                Button("Double all delays (2× slower)") { scaleDelays(2) }
                Button("Cap delays at 1 second") { capDelays(1) }
                Button("Set delay of \(selection.isEmpty ? "all" : "selected") steps…") { ui.showingBulkDelay = true }
                Divider()
                Button("Select all") { selection = Set(macro.steps.map(\.id)) }
                Button("Duplicate macro") { model.duplicate(macro) }
                Button("Export…") { model.export(macro) }
                Divider()
                Button("Delete macro", role: .destructive) { model.delete(macro) }
            } label: {
                Label("Tools", systemImage: "wand.and.stars")
            }
            .fixedSize()

            Spacer(minLength: 4)
            if !selection.isEmpty {
                Text(selectionLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
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
                EmptyMacroPrompt(appName: macro.target.app?.name, onAddPicture: addPictureStep,
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
                let pic = ImageStep(png: c.png, width: c.width, height: c.height,
                                    originX: Double(rect.minX), originY: Double(rect.minY))
                let id = insert(.findImage(pic), delay: macro.steps.isEmpty ? 0 : 0.1)
                ui.editingPicture = id
            } onCancel: {
                ui.pictureSource = nil
            }
        }
        // Editing a picture step.
        .sheet(item: Binding(get: { ui.editingPicture.map(StepSheetItem.init) }, set: { ui.editingPicture = $0?.id })) { item in
            if let binding = editing.imageBinding(stepID: item.id) {
                PictureStepEditor(step: binding, app: macro.target.app, touch: editing.isTouch,
                                  allAtOnce: allAtOnce) { ui.editingPicture = nil }
            }
        }
    }

    /// Screenshot the target window, then let the user box the picture to look for.
    private func addPictureStep() {
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
        ui.editingPicture = insert(.findImage(step), delay: macro.steps.isEmpty ? 0 : 0.1)
    }

    private func editPicture(_ g: ActionGroup) {
        ui.editingPicture = editing.actionStepID(g)
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
                    Text("No steps. Record something, or use Insert.").foregroundStyle(.secondary)
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
    /// Step to scroll to when the detailed list appears.
    var scrollTarget: UUID?
    /// Marker being dragged in the visual view, and how far.
    @Published var dragging: UUID?
    @Published var showingPlayback = false
    /// Screenshot to pick a new picture step from.
    @Published var pictureSource: NSImage?
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
