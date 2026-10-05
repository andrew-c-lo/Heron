import SwiftUI

/// Edits that map a human-level action back onto its raw steps. Shared by the Actions list and the Visual view.
struct ActionEditing {
    let macro: Binding<Macro>
    let ui: DetailUIState

    private var steps: [MacroStep] { macro.wrappedValue.steps }

    var groups: [ActionGroup] { ActionGrouper.groups(for: steps) }

    var isTouch: Bool { macro.wrappedValue.target.app?.bundleID == "com.apple.ScreenContinuity" }

    func isSelected(_ g: ActionGroup) -> Bool {
        steps[g.range.clamped(to: steps.indices)].contains { ui.selection.contains($0.id) }
    }

    func select(_ g: ActionGroup) {
        ui.selection = Set(steps[g.range.clamped(to: steps.indices)].map(\.id))
    }

    /// Selecting an action selects all of its raw steps, so Insert/Delete/Tools work in every view.
    func selectionBinding(_ groups: [ActionGroup]) -> Binding<Set<UUID>> {
        Binding(
            get: { Set(groups.filter(isSelected).map(\.id)) },
            set: { ids in
                ui.selection = Set(groups.filter { ids.contains($0.id) }
                    .flatMap { steps[$0.range.clamped(to: steps.indices)].map(\.id) })
            }
        )
    }

    /// Changing the wait rescales the travel delays before the action, so cursor movement keeps its shape.
    func waitBinding(_ g: ActionGroup) -> Binding<Double> {
        Binding(
            get: { g.wait },
            set: { v in
                guard g.lead.upperBound < steps.count else { return }
                let new = max(0, v)
                var s = steps
                if g.wait > 0 {
                    let f = new / g.wait
                    for k in g.lead { s[k].delay *= f }
                } else {
                    s[g.actionIndex].delay = new
                }
                macro.wrappedValue.steps = s
            }
        )
    }

    func pointBinding(_ g: ActionGroup) -> Binding<CGPoint> {
        Binding(
            get: { g.editablePoint ?? .zero },
            set: { p in
                guard let old = g.editablePoint else { return }
                translate(g, by: CGSize(width: p.x - old.x, height: p.y - old.y))
            }
        )
    }

    /// Moves every position in the action (not the cursor travel before it).
    func translate(_ g: ActionGroup, by d: CGSize) {
        guard g.range.upperBound <= steps.count, d != .zero else { return }
        var s = steps
        for k in g.actionIndex..<g.range.upperBound {
            guard !s[k].action.isMouseMove, let p = s[k].action.point else { continue }
            s[k].action.point = CGPoint(x: (p.x + d.width).rounded(), y: (p.y + d.height).rounded())
        }
        macro.wrappedValue.steps = s
    }

    func colorBinding(_ g: ActionGroup) -> Binding<ColorWait>? {
        guard g.actionIndex < steps.count, let initial = steps[g.actionIndex].action.colorWait else { return nil }
        let id = steps[g.actionIndex].id
        return Binding(
            get: { steps.first { $0.id == id }?.action.colorWait ?? initial },
            set: { c in
                guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
                macro.wrappedValue.steps[i].action.colorWait = c
            }
        )
    }

    /// How a picture step behaves when the chain runs All at once (nil otherwise).
    func allAtOnceDetail(_ g: ActionGroup) -> String? {
        guard macro.wrappedValue.playback.order == .allAtOnce, case .image(let s) = g.kind else { return nil }
        if s.mode == .stop { return "Stops the chain as soon as it appears" }
        if s.spotOnly { return "Skipped in All at once (set to a fixed spot)" }
        guard s.mode == .click else { return "Skipped in All at once (only steps that click or stop are used)" }
        // The title already says when it's tapped; this is the rhythm and how close a match counts.
        let how = s.repeatUntilGone ? "every \(s.repeatEvery.formatted())s" : "each time it shows"
        return how + (!s.usesPicture ? "" : " · \(Int((s.strictness * 100).rounded()))% match")
    }

    /// The id of the step that holds a group's main action (e.g. the picture step itself).
    func actionStepID(_ g: ActionGroup) -> UUID? {
        g.actionIndex < steps.count ? steps[g.actionIndex].id : nil
    }

    /// The name given to an action (empty = use what it does as its title).
    func nameBinding(_ g: ActionGroup) -> Binding<String> {
        let id = actionStepID(g)
        return Binding(
            get: { id.flatMap { id in steps.first { $0.id == id }?.name } ?? "" },
            set: { v in
                guard let id, let i = steps.firstIndex(where: { $0.id == id }) else { return }
                let t = v.trimmingCharacters(in: .whitespaces)
                macro.wrappedValue.steps[i].name = t.isEmpty ? nil : v
            }
        )
    }

    /// The list of a “Type from a list” action.
    // MARK: If blocks

    /// Where each If's Otherwise and End are, and how deeply each step is nested.
    var blocks: IfBlocks { IfBlocks(steps.map(\.action)) }

    func conditionBinding(_ g: ActionGroup) -> Binding<StepCondition>? {
        guard g.actionIndex < steps.count, case .ifStart(let initial) = steps[g.actionIndex].action else { return nil }
        let id = steps[g.actionIndex].id
        return Binding(
            get: {
                if let s = steps.first(where: { $0.id == id }), case .ifStart(let v) = s.action { return v }
                return initial
            },
            set: { v in
                guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
                macro.wrappedValue.steps[i].action = .ifStart(v)
            }
        )
    }

    func runMacroBinding(_ g: ActionGroup) -> Binding<UUID>? {
        guard g.actionIndex < steps.count, case .runMacro(let initial) = steps[g.actionIndex].action else { return nil }
        let id = steps[g.actionIndex].id
        return Binding(
            get: {
                if let s = steps.first(where: { $0.id == id }), case .runMacro(let v) = s.action { return v }
                return initial
            },
            set: { v in
                guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
                macro.wrappedValue.steps[i].action = .runMacro(v)
            }
        )
    }

    /// The If a marker row belongs to (the row itself for an If).
    func ifIndex(of g: ActionGroup) -> Int? {
        let b = blocks, i = g.actionIndex
        switch g.kind {
        case .ifStart: return i
        case .otherwise: return b.otherwise.first { $0.value == i }?.key
        case .endIf: return b.end.first { $0.value == i }?.key
        default: return nil
        }
    }

    func hasOtherwise(_ g: ActionGroup) -> Bool { ifIndex(of: g).map { blocks.otherwise[$0] != nil } ?? false }

    /// Adds an Otherwise (just before the End), or removes it with the steps under it. Returns how many were removed.
    @discardableResult
    func setOtherwise(_ g: ActionGroup, _ on: Bool) -> Int {
        guard let start = ifIndex(of: g) else { return 0 }
        let b = blocks
        var all = steps
        if on {
            guard b.otherwise[start] == nil else { return 0 }
            all.insert(MacroStep(delay: 0, action: .otherwise), at: b.end[start] ?? all.count)
            macro.wrappedValue.steps = all
            return 0
        }
        guard let o = b.otherwise[start] else { return 0 }
        let end = b.end[start] ?? all.count
        all.removeSubrange(o..<end)
        macro.wrappedValue.steps = all
        return end - o - 1
    }

    /// Removes an If's If, Otherwise and End rows, keeping the steps that were inside.
    func unwrap(_ g: ActionGroup) {
        guard let start = ifIndex(of: g) else { return }
        let b = blocks
        let drop = Set([start, b.otherwise[start], b.end[start]].compactMap { $0 })
        macro.wrappedValue.steps = steps.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        ui.selection.removeAll()
    }

    func typeListBinding(_ g: ActionGroup) -> Binding<TypeList>? {
        guard g.actionIndex < steps.count, case .typeList(let initial) = steps[g.actionIndex].action else { return nil }
        let id = steps[g.actionIndex].id
        return Binding(
            get: {
                if let s = steps.first(where: { $0.id == id }), case .typeList(let v) = s.action { return v }
                return initial
            },
            set: { v in
                guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
                macro.wrappedValue.steps[i].action = .typeList(v)
            }
        )
    }

    func imageBinding(stepID: UUID) -> Binding<ImageStep>? {
        guard let i = steps.firstIndex(where: { $0.id == stepID }), case .findImage(let initial) = steps[i].action else { return nil }
        return Binding(
            get: {
                if let s = steps.first(where: { $0.id == stepID }), case .findImage(let v) = s.action { return v }
                return initial
            },
            set: { v in
                guard let i = steps.firstIndex(where: { $0.id == stepID }) else { return }
                macro.wrappedValue.steps[i].action = .findImage(v)
            }
        )
    }

    /// Selected picture steps (not text) that can be combined into one.
    var combinablePictures: [ActionGroup] {
        groups.filter { g in
            guard isSelected(g), case .image(let s) = g.kind else { return false }
            return s.text == nil && !s.png.isEmpty
        }
    }

    /// Makes the first selected picture step also match the others' pictures, and removes the others.
    func combinePictures() {
        let picked = combinablePictures
        guard picked.count >= 2, let keepID = actionStepID(picked[0]),
              let keep = steps.firstIndex(where: { $0.id == keepID }),
              case .findImage(var first) = steps[keep].action else { return }
        var drop = Set<UUID>()
        for g in picked.dropFirst() {
            guard let id = actionStepID(g), let i = steps.firstIndex(where: { $0.id == id }),
                  case .findImage(let other) = steps[i].action else { continue }
            first.variants.append(PictureVariant(png: other.png, width: other.width, height: other.height))
            first.variants.append(contentsOf: other.variants)
            drop.formUnion(steps[g.range.clamped(to: steps.indices)].map(\.id))
        }
        var s = steps
        s[keep].action = .findImage(first)
        s.removeAll { drop.contains($0.id) }
        macro.wrappedValue.steps = s
        ui.selection = [keepID]
    }

    /// Changes a “Repeat from” step.
    func setRepeat(_ g: ActionGroup, target: UUID, times: Int) {
        guard g.actionIndex < steps.count else { return }
        macro.wrappedValue.steps[g.actionIndex].action = .repeatFrom(step: target, times: times)
    }

    /// The step id an action starts at, for choosing jump targets.
    func stepChoices(before g: ActionGroup? = nil) -> [(id: UUID, title: String)] {
        groups.enumerated().compactMap { i, e in
            guard let id = actionStepID(e), g.map({ e.range.upperBound <= $0.range.lowerBound }) ?? true,
                  !e.isBlockMarker || e.kind.isIf else { return nil }
            return (id, "\(i + 1). \(e.title(touch: isTouch))")
        }
    }

    /// Switching an action off switches off all of its raw steps (and its wait), so playback skips it whole.
    func enabledBinding(_ g: ActionGroup) -> Binding<Bool> {
        Binding(
            get: { g.enabled },
            set: { on in
                guard g.range.upperBound <= steps.count else { return }
                var s = steps
                for k in g.range { s[k].enabled = on }
                macro.wrappedValue.steps = s
            }
        )
    }

    func delete(_ g: ActionGroup) {
        // Deleting an If, Otherwise or End row removes that If's rows and keeps the steps inside.
        if g.isBlockMarker { unwrap(g); return }
        guard g.range.upperBound <= steps.count else { return }
        macro.wrappedValue.steps.removeSubrange(g.range)
        ui.selection.removeAll()
    }

    /// Picture/text steps that click, among the selection (or just `g` when it isn't selected).
    func clickFinders(_ g: ActionGroup?) -> [ActionGroup] {
        let gs = groups
        let chosen = g.map { isSelected($0) ? gs.filter(isSelected) : [$0] } ?? gs.filter(isSelected)
        return chosen.filter { if case .image(let s) = $0.kind { return s.mode == .click }; return false }
    }

    /// Switches steps between clicking their fixed spot and finding their picture or words.
    func setSpotOnly(_ g: ActionGroup?, _ on: Bool) {
        var steps = self.steps
        for c in clickFinders(g) {
            guard c.actionIndex < steps.count, case .findImage(var s) = steps[c.actionIndex].action else { continue }
            s.setSpotOnly(on)
            steps[c.actionIndex].action = .findImage(s)
        }
        macro.wrappedValue.steps = steps
    }

    enum MoveDirection { case top, up, down, bottom }

    /// The positions (in `groups`) of what a move acts on: `g` alone unless it's part of the selection.
    private func moving(_ g: ActionGroup?, in gs: [ActionGroup]) -> IndexSet {
        if let g, !isSelected(g) { return IndexSet(gs.firstIndex { $0.id == g.id }.map { [$0] } ?? []) }
        return IndexSet(gs.indices.filter { isSelected(gs[$0]) })
    }

    func canMove(_ g: ActionGroup?, _ d: MoveDirection) -> Bool {
        let gs = groups, idx = moving(g, in: gs)
        guard let first = idx.first, let last = idx.last else { return false }
        let block = last - first + 1 == idx.count
        switch d {
        case .top, .up: return first > 0 || !block
        case .down, .bottom: return last < gs.count - 1 || !block
        }
    }

    /// Moves an action (or the selected ones, together) to the top, up one, down one or to the bottom.
    func move(_ g: ActionGroup?, _ d: MoveDirection) {
        let gs = groups, idx = moving(g, in: gs)
        guard let first = idx.first, let last = idx.last else { return }
        let to: Int
        switch d {
        case .top: to = 0
        case .up: to = max(0, first - 1)
        case .down: to = min(gs.count, last + 2)
        case .bottom: to = gs.count
        }
        move(gs, from: idx, to: to)
    }

    func move(_ groups: [ActionGroup], from: IndexSet, to: Int) {
        var reordered = groups
        reordered.move(fromOffsets: from, toOffset: to)
        let s = steps
        macro.wrappedValue.steps = reordered.flatMap { s[$0.range.clamped(to: s.indices)] }
    }

    /// Inserts a "wait for color" check right before the action (after the cursor travel), at the action's position.
    /// Returns the new step's id so the caller can fill in the sampled color.
    @discardableResult
    func addColorCheck(before g: ActionGroup, hex: String = "#FFFFFF") -> UUID? {
        guard let p = g.editablePoint, g.actionIndex <= steps.count else { return nil }
        var s = steps
        let check = MacroStep(delay: s[g.actionIndex].delay, action: .waitForColor(at: p, .detect(hex)))
        s[g.actionIndex].delay = 0
        s.insert(check, at: g.actionIndex)
        macro.wrappedValue.steps = s
        return check.id
    }

    func setColor(stepID: UUID, hex: String) {
        guard let i = steps.firstIndex(where: { $0.id == stepID }) else { return }
        macro.wrappedValue.steps[i].action.colorWait?.hex = hex
    }

    func summary(_ groups: [ActionGroup]) -> String {
        let touch = isTouch
        var clicks = 0, drags = 0, scrolls = 0, keys = 0, pauses = 0, colors = 0, pictures = 0, texts = 0, ifs = 0, runs = 0
        // If, Otherwise and End rows aren't steps of their own: the count is of steps that do something.
        let real = groups.filter { !$0.isBlockMarker || $0.kind.isIf }
        for g in groups {
            switch g.kind {
            case .click: clicks += 1
            case .drag: drags += 1
            case .scroll: scrolls += 1
            case .keys: keys += 1
            case .wait: pauses += 1
            case .colorWait: colors += 1
            case .image(let s): if s.text != nil { texts += 1 } else { pictures += 1 }
            case .ifStart: ifs += 1
            case .runMacro: runs += 1
            default: break
            }
        }
        func n(_ count: Int, _ word: String) -> String? {
            count == 0 ? nil : "\(count) \(word)\(count == 1 ? "" : "s")"
        }
        let parts = [n(pictures, "picture step"), n(texts, "text step"), n(clicks, touch ? "tap" : "click"), n(drags, touch ? "swipe" : "drag"), n(scrolls, "scroll"),
                     n(keys, "keyboard step"), n(colors, "color check"), n(pauses, "pause"),
                     ifs == 0 ? nil : "\(ifs) If\(ifs == 1 ? "" : "s")", n(runs, "other macro")].compactMap { $0 }
        let head = "\(real.count) step\(real.count == 1 ? "" : "s")"
        return parts.isEmpty ? head : head + ": " + parts.joined(separator: ", ")
    }
}

/// Readable list of a macro: raw events grouped into actions like "Tap", "Swipe up", "Type “hi”".
struct SimpleStepsList: View {
    @EnvironmentObject var model: AppModel
    let editing: ActionEditing
    let onShowRaw: (ActionGroup) -> Void
    let onDelete: () -> Void
    let onAddColorCheck: (ActionGroup) -> Void
    let onSampleColor: (ActionGroup) -> Void
    let onEditPicture: (ActionGroup) -> Void

    /// After a run: how often each action fired (nil before any run).
    private var ran: Bool {
        editing.macro.wrappedValue.steps.contains { model.stepHits[$0.id] != nil }
    }

    /// The step a running macro is on (in order) or last clicked (all at once), to light up in the list.
    private var liveStep: UUID? {
        let m = editing.macro.wrappedValue
        guard let run = model.live[m.id] else { return nil }
        if m.playback.order == .allAtOnce || m.runsInBackground { return run.lastFired }
        let steps = m.steps.filter(\.enabled)
        let i = model.playStep - 1
        return model.playingMacroID == m.id && steps.indices.contains(i) ? steps[i].id : run.lastFired
    }

    private func hits(_ g: ActionGroup, ran: Bool) -> Int? {
        guard ran, let id = editing.actionStepID(g) else { return nil }
        return model.stepHits[id] ?? 0
    }

    var body: some View {
        let groups = editing.groups
        let touch = editing.isTouch
        let live = liveStep
        let steps = editing.macro.wrappedValue.steps

        let blocks = editing.blocks
        VStack(alignment: .leading, spacing: 6) {
            Text(editing.summary(groups))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            List(selection: editing.selectionBinding(groups)) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    ActionRow(group: g, number: i + 1, touch: touch,
                              // Otherwise and End go with their If: switching the If off skips the whole block.
                              enabled: g.isBlockMarker && !(g.kind.isIf) ? nil : editing.enabledBinding(g),
                              wait: editing.waitBinding(g),
                              point: nil,
                              color: nil,
                              onSampleColor: { onSampleColor(g) },
                              onEditPicture: { onEditPicture(g) },
                              detailOverride: editing.allAtOnceDetail(g),
                              compact: true,
                              hits: hits(g, ran: ran),
                              live: live.map { id in steps[g.range.clamped(to: steps.indices)].contains { $0.id == id } } ?? false,
                              depth: g.actionIndex < blocks.depth.count ? blocks.depth[g.actionIndex] : 0)
                        .tag(g.id)
                        .listRowSeparator(.visible)
                }
                .onMove { editing.move(groups, from: $0, to: $1) }
            }
            // The list's own right-click menu and double-click keep single-click selection and dragging working.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let g = groups.first(where: { ids.contains($0.id) }) {
                    ActionMenu(group: g, editing: editing, onShowRaw: onShowRaw, onAddColorCheck: onAddColorCheck,
                               onEditPicture: onEditPicture)
                }
            } primaryAction: { ids in
                if let g = groups.first(where: { ids.contains($0.id) }), case .image = g.kind { onEditPicture(g) }
            }
            // Separators, not alternating shading: shading carried on below the last step as empty grey rows,
            // which made a short macro look unfinished.
            .listStyle(.inset(alternatesRowBackgrounds: false))
            .onDeleteCommand(perform: onDelete)
            .overlay {
                if groups.isEmpty {
                    Text("No steps yet. Record something, or use Find Picture and Add above.").foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Right-click menu for an action (Actions list and Visual view).
struct ActionMenu: View {
    let group: ActionGroup
    let editing: ActionEditing
    let onShowRaw: (ActionGroup) -> Void
    let onAddColorCheck: (ActionGroup) -> Void
    var onEditPicture: (ActionGroup) -> Void = { _ in }

    var body: some View {
        if case .image(let s) = group.kind {
            Button("Show Settings") { onEditPicture(group) }
        }
        Toggle("On", isOn: editing.enabledBinding(group))
        if case .image(let s) = group.kind, s.mode == .click {
            let n = editing.clickFinders(group).count
            let many = n > 1 ? " (\(n) Steps)" : ""
            if s.spotOnly {
                Button("Find It Instead" + many) { editing.setSpotOnly(group, false) }
            } else {
                Button("Click Its Spot Instead" + many) { editing.setSpotOnly(group, true) }
            }
        }
        if editing.combinablePictures.count >= 2 && editing.isSelected(group) {
            Button("Combine \(editing.combinablePictures.count) Pictures into One Step") { editing.combinePictures() }
        }
        if case .click = group.kind, group.editablePoint != nil {
            Button(editing.isTouch ? "Only Tap If the Color Matches…" : "Only Click If the Color Matches…") { onAddColorCheck(group) }
        }
        Button("Show Raw Events") { onShowRaw(group) }
        Divider()
        Button("Move to Top") { editing.move(group, .top) }.disabled(!editing.canMove(group, .top))
        Button("Move Up") { editing.move(group, .up) }.disabled(!editing.canMove(group, .up))
        Button("Move Down") { editing.move(group, .down) }.disabled(!editing.canMove(group, .down))
        Button("Move to Bottom") { editing.move(group, .bottom) }.disabled(!editing.canMove(group, .bottom))
        Divider()
        Button("Delete", role: .destructive) { editing.delete(group) }
    }
}

struct ActionRow: View {
    let group: ActionGroup
    let number: Int
    let touch: Bool
    var enabled: Binding<Bool>? = nil
    let wait: Binding<Double>
    let point: Binding<CGPoint>?
    var color: Binding<ColorWait>? = nil
    var onSampleColor: () -> Void = {}
    var onEditPicture: () -> Void = {}
    /// Replaces the generated detail line (e.g. for picture steps in an All at once chain).
    var detailOverride: String? = nil
    /// In the macro editor's list the details panel shows the wait, position and settings, so rows stay short.
    var compact = false
    /// How often it fired last run (nil = no run yet).
    var hits: Int? = nil
    /// The running macro is on this step (or just clicked it).
    var live = false
    /// How many Ifs it's inside: drawn as guides down the left, so each If's steps read as one block.
    var depth = 0
    @StateObject private var hover = HoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if let enabled {
                Toggle("", isOn: enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(enabled.wrappedValue ? "On. Uncheck to skip this step when the macro plays."
                                               : "Off. This step is skipped when the macro plays.")
            }
            Text("\(number)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)
            if depth > 0 {
                HStack(spacing: 12) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle().fill(Color.accentColor.opacity(0.35)).frame(width: 2).frame(maxHeight: .infinity)
                    }
                }
                .padding(.vertical, -6)
                .accessibilityHidden(true)
            }

            if !compact {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
                TextField("", value: wait, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text("s").foregroundStyle(.secondary)
            }
            .help(isPause ? "How long to pause" : "How long to wait before this step")
            }

            Image(systemName: group.icon(touch: touch))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title(touch: touch))
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
                if let color {
                    ColorWaitControls(wait: color, onSampleColor: onSampleColor)
                } else if case .image(let pic) = group.kind {
                    // Narrow list: the detail gets its own line under the picture, so it isn't cut short.
                    let detailLine = compact ? withAction(detailOverride ?? group.detail) : nil
                    VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        if pic.usesPicture {
                            PictureThumbnail(png: pic.png, maxWidth: 110, maxHeight: 26)
                                .opacity(pic.spotOnly ? 0.35 : 1)
                            if !pic.variants.isEmpty {
                                Text("+\(pic.variants.count)")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                    .help("Also matches \(pic.variants.count) more picture\(pic.variants.count == 1 ? "" : "s")")
                            }
                        }
                        if !compact, let d = withAction(detailOverride ?? group.detail) {
                            Text(d).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                .help(d)
                        }
                        if !compact {
                        // Shown on the row under the pointer only (double-click or right-click also edits).
                        Button("Edit…", action: onEditPicture)
                            .controlSize(.small)
                            .opacity(hover.hovering ? 1 : 0)
                            .allowsHitTesting(hover.hovering)
                        }
                    }
                    if let d = detailLine {
                        Text(d).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .help(d)
                    }
                    }
                } else if let d = withAction(group.detail) {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            if let point {
                HStack(spacing: 4) {
                    Text("x").foregroundStyle(.secondary)
                    TextField("", value: coord(point, \.x), format: .number.precision(.fractionLength(0))).frame(width: 48)
                    Text("y").foregroundStyle(.secondary)
                    TextField("", value: coord(point, \.y), format: .number.precision(.fractionLength(0))).frame(width: 48)
                }
            }

            if let hits {
                Text("\(hits)×")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(hits == 0 ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.15)))
                    .foregroundStyle(hits == 0 ? Color.orange : Color.secondary)
                    .help(hits == 0 ? "Never fired last run" : "Fired \(hits) time\(hits == 1 ? "" : "s") last run")
            }
            if !compact {
            Text(Self.timestamp(group.start))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
                .help("When this happens, counted from the start of the macro at 1× speed")
            }
        }
        .padding(.vertical, 3)
        .background {
            if live {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.16))
                    .padding(.horizontal, -6)
                    .transition(.opacity)
            }
        }
        .animation(Motion.snap(reduceMotion), value: live)
        .accessibilityValue(live ? "Running now" : "")
        .opacity(group.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.snap(reduceMotion)) { hover.hovering = h } }
        // No tap gestures here: in a List they take the mouse away from row selection and drag-to-reorder.
        // Double-click is the list's primary action instead.
    }

    /// A named step's detail line starts with what it does (the title shows the name).
    private func withAction(_ detail: String?) -> String? {
        guard let n = group.name, !n.trimmingCharacters(in: .whitespaces).isEmpty else { return detail }
        let action = group.actionTitle(touch: touch)
        return detail.map { "\(action) · \($0)" } ?? action
    }

    private var isPause: Bool {
        if case .wait = group.kind { return true }
        return false
    }

    private func coord(_ p: Binding<CGPoint>, _ kp: WritableKeyPath<CGPoint, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(p.wrappedValue[keyPath: kp]) },
            set: { v in
                var np = p.wrappedValue
                np[keyPath: kp] = CGFloat(v)
                p.wrappedValue = np
            }
        )
    }

    static func timestamp(_ t: Double) -> String {
        let m = Int(t) / 60
        return String(format: "%d:%04.1f", m, t - Double(m * 60))
    }
}

/// Swatch + hex + tolerance + timeout + fallback for a "wait for color" action.
struct ColorWaitControls: View {
    let wait: Binding<ColorWait>
    let onSampleColor: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { colorPart; timingPart }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) { colorPart }
                HStack(spacing: 6) { timingPart }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }

    @ViewBuilder
    private var colorPart: some View {
            ColorSwatch(hex: wait.wrappedValue.hex) { wait.wrappedValue.hex = $0 }
            HexField(hex: Binding(get: { wait.wrappedValue.hex }, set: { wait.wrappedValue.hex = $0 }))
            Button { onSampleColor() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .buttonStyle(.borderless)
                .help("Use the color that's at this spot right now")
            Text("±").foregroundStyle(.secondary)
            TextField("", value: wait.tolerance, format: .number).frame(width: 30)
                .help("How far each of red/green/blue may differ (0–255). 0 = exact match.")
    }

    @ViewBuilder
    private var timingPart: some View {
            Picker("", selection: wait.untilAppears) {
                Text("until it appears").tag(true)
                Text("for up to…").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .help("Keep checking until the color shows up, or give up after a set time")
            if !wait.wrappedValue.untilAppears {
                TextField("", value: wait.timeout, format: .number).frame(width: 34)
                    .help("Seconds to keep checking. 0 = check once.")
                Text("s").foregroundStyle(.secondary)
                Picker("", selection: wait.otherwise) {
                    ForEach(ColorFallback.allCases.filter { $0 != .goToStep }) { Text("else " + $0.shortLabel).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("What to do if the color never appears")
            }
            Toggle(isOn: wait.immediate) {
                Label("Ignore timing", systemImage: "bolt.fill")
            }
            .toggleStyle(.button)
            .help("Ignore the recorded waits around this check: start checking right after the previous step, and do the next step the moment the color appears. Good when lag makes timing unpredictable.")
    }
}

/// Click to pick a color from anywhere on screen with the system eyedropper.
struct ColorSwatch: View {
    let hex: String?
    let onPick: (String) -> Void

    var body: some View {
        Button {
            Eyedropper.pick { if let h = $0 { onPick(h) } }
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: hex.flatMap { RGB(hex: $0)?.nsColor } ?? .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.6)))
                .overlay {
                    if hex == nil { Image(systemName: "eyedropper").font(.caption2) }
                }
                .frame(width: 24, height: 16)
        }
        .buttonStyle(.plain)
        .help("Pick a color from the screen with the eyedropper")
    }
}

/// "#RRGGBB" text field; ignores invalid input.
struct HexField: View {
    let hex: Binding<String>

    var body: some View {
        TextField("", value: hex, formatter: HexFormatter.shared, prompt: Text("#RRGGBB"))
            .labelsHidden()
            .font(.caption.monospaced())
            .frame(width: 70)
    }
}

/// Accepts "#RRGGBB" / "RRGGBB"; anything else reverts when committed.
final class HexFormatter: Formatter {
    static let shared = HexFormatter()

    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription _: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard let c = RGB(hex: string) else { return false }
        obj?.pointee = c.hex as NSString
        return true
    }
}

/// A stored picture (PNG) shown small, with a thin frame.
struct PictureThumbnail: View {
    let png: Data
    var maxWidth: CGFloat = 120
    var maxHeight: CGFloat = 40

    var body: some View {
        Group {
            if let img = NSImage(data: png) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight)
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
    }
}
