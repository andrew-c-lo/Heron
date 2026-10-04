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
        guard s.mode == .click else { return "Skipped in All at once (only steps that click are used)" }
        let how = s.repeatUntilGone ? "every \(s.repeatEvery.formatted())s while it's showing" : "once each time it appears"
        return "Whenever it appears, \(how)" + (s.text != nil ? "" : " · \(Int((s.strictness * 100).rounded()))% match")
    }

    /// The id of the step that holds a group's main action (e.g. the picture step itself).
    func actionStepID(_ g: ActionGroup) -> UUID? {
        g.actionIndex < steps.count ? steps[g.actionIndex].id : nil
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

    /// Changes a “Repeat from” step.
    func setRepeat(_ g: ActionGroup, target: UUID, times: Int) {
        guard g.actionIndex < steps.count else { return }
        macro.wrappedValue.steps[g.actionIndex].action = .repeatFrom(step: target, times: times)
    }

    /// The step id an action starts at, for choosing jump targets.
    func stepChoices(before g: ActionGroup? = nil) -> [(id: UUID, title: String)] {
        groups.enumerated().compactMap { i, e in
            guard let id = actionStepID(e), g.map({ e.range.upperBound <= $0.range.lowerBound }) ?? true else { return nil }
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
        guard g.range.upperBound <= steps.count else { return }
        macro.wrappedValue.steps.removeSubrange(g.range)
        ui.selection.removeAll()
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
        var clicks = 0, drags = 0, scrolls = 0, keys = 0, pauses = 0, colors = 0, pictures = 0, texts = 0
        for g in groups {
            switch g.kind {
            case .click: clicks += 1
            case .drag: drags += 1
            case .scroll: scrolls += 1
            case .keys: keys += 1
            case .wait: pauses += 1
            case .colorWait: colors += 1
            case .image(let s): if s.text != nil { texts += 1 } else { pictures += 1 }
            default: break
            }
        }
        func n(_ count: Int, _ word: String) -> String? {
            count == 0 ? nil : "\(count) \(word)\(count == 1 ? "" : "s")"
        }
        let parts = [n(pictures, "picture step"), n(texts, "text step"), n(clicks, touch ? "tap" : "click"), n(drags, touch ? "swipe" : "drag"), n(scrolls, "scroll"),
                     n(keys, "keyboard action"), n(colors, "color check"), n(pauses, "pause")].compactMap { $0 }
        let head = "\(groups.count) action\(groups.count == 1 ? "" : "s")"
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

    private func hits(_ g: ActionGroup, ran: Bool) -> Int? {
        guard ran, let id = editing.actionStepID(g) else { return nil }
        return model.stepHits[id] ?? 0
    }

    var body: some View {
        let groups = editing.groups
        let touch = editing.isTouch

        VStack(alignment: .leading, spacing: 6) {
            Text(editing.summary(groups))
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8)
            List(selection: editing.selectionBinding(groups)) {
                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    ActionRow(group: g, number: i + 1, touch: touch,
                              enabled: editing.enabledBinding(g),
                              wait: editing.waitBinding(g),
                              point: nil,
                              color: nil,
                              onSampleColor: { onSampleColor(g) },
                              onEditPicture: { onEditPicture(g) },
                              detailOverride: editing.allAtOnceDetail(g),
                              compact: true,
                              hits: hits(g, ran: ran))
                        .tag(g.id)
                        .contextMenu {
                            ActionMenu(group: g, editing: editing, onShowRaw: onShowRaw, onAddColorCheck: onAddColorCheck,
                                       onEditPicture: onEditPicture)
                        }
                }
                .onMove { editing.move(groups, from: $0, to: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .onDeleteCommand(perform: onDelete)
            .overlay {
                if groups.isEmpty {
                    Text("No actions yet. Record something, or use the buttons above.").foregroundStyle(.secondary)
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
        if case .click = group.kind, group.editablePoint != nil {
            Button(editing.isTouch ? "Only Tap If the Color Matches…" : "Only Click If the Color Matches…") { onAddColorCheck(group) }
        }
        Button("Show Raw Steps") { onShowRaw(group) }
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
    @StateObject private var hover = HoverState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if let enabled {
                Toggle("", isOn: enabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(enabled.wrappedValue ? "On. Uncheck to skip this action when the macro plays."
                                               : "Off. This action is skipped when the macro plays.")
            }
            Text("\(number)")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 30, alignment: .trailing)

            if !compact {
            HStack(spacing: 3) {
                Image(systemName: "clock").font(.caption2).foregroundStyle(.tertiary)
                TextField("", value: wait, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 50)
                    .multilineTextAlignment(.trailing)
                Text("s").foregroundStyle(.secondary)
            }
            .help(isPause ? "How long to pause" : "How long to wait before this action")
            }

            Image(systemName: group.icon(touch: touch))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.title(touch: touch))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let color {
                    ColorWaitControls(wait: color, onSampleColor: onSampleColor)
                } else if case .image(let pic) = group.kind {
                    HStack(spacing: 8) {
                        if pic.text == nil { PictureThumbnail(png: pic.png, maxWidth: 110, maxHeight: 26) }
                        if let d = detailOverride ?? group.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if !compact {
                        // Shown on the row under the pointer only (double-click or right-click also edits).
                        Button("Edit…", action: onEditPicture)
                            .controlSize(.small)
                            .opacity(hover.hovering ? 1 : 0)
                            .allowsHitTesting(hover.hovering)
                        }
                    }
                } else if let d = group.detail {
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
        .opacity(group.enabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.snap(reduceMotion)) { hover.hovering = h } }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if case .image = group.kind { onEditPicture() }
        })
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
            .help("Ignore the recorded waits around this check: start checking right after the previous action, and do the next action the moment the color appears. Good when lag makes timing unpredictable.")
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
