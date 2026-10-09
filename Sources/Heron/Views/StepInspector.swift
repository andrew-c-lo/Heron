import SwiftUI

/// The details panel beside the step list: everything about the selected action, edited in place.
struct StepInspector: View {
    @EnvironmentObject var model: AppModel
    let editing: ActionEditing
    let app: TargetApp?
    let allAtOnce: Bool
    let onShowRaw: (ActionGroup) -> Void
    let onAddColorCheck: (ActionGroup) -> Void
    let onSampleColor: (ActionGroup) -> Void
    let onDelete: () -> Void
    @StateObject private var naming = Naming()
    @FocusState private var nameFocused: Bool
    final class Naming: ObservableObject { @Published var active = false }

    private func hint(_ icon: String, _ text: String) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon).frame(width: 18) }
    }

    var body: some View {
        let selected = editing.groups.filter(editing.isSelected)
        Group {
            if selected.count == 1, let g = selected.first {
                details(g)
                    .id(g.id)
                    .onChange(of: g.id) { _, _ in naming.active = false }
            } else if selected.count > 1 {
                VStack(spacing: 12) {
                    Text("\(selected.count) steps selected").font(.headline)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Nothing selected: what to do here, and the shortcuts that make it quicker.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select a step to edit it").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        hint("arrow.up.arrow.down", "Drag steps to reorder them, or press ⌥⌘↑ and ⌥⌘↓.")
                        hint("pencil", "Name a step to tell look-alikes apart.")
                        hint("slider.horizontal.3", "⌘1–⌘4 open Target, Playback, Stops and Schedule.")
                        hint("stop.circle", "⌘. stops a run at any time.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 260, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    @ViewBuilder
    private func details(_ g: ActionGroup) -> some View {
        let touch = editing.isTouch
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: g.icon(touch: touch)).foregroundStyle(.tint)
                if naming.active {
                    TextField("", text: editing.nameBinding(g), prompt: Text(g.actionTitle(touch: touch)))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onAppear { nameFocused = true }
                        .font(.headline)
                        .onSubmit { naming.active = false }
                        .onExitCommand { naming.active = false }
                        .accessibilityLabel("Step name")
                } else {
                    Text(g.title(touch: touch)).font(.headline).lineLimit(2)
                    Button { naming.active = true } label: { Image(systemName: "pencil") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Name this step, like “Claim button”")
                        .accessibilityLabel("Rename step")
                }
                Spacer(minLength: 4)
                Toggle("On", isOn: editing.enabledBinding(g))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("Off: skipped when the macro plays")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()

            if case .image = g.kind, let id = editing.actionStepID(g), let binding = editing.imageBinding(stepID: id) {
                if let hits = model.stepHits[id] {
                    Text("Fired \(hits) time\(hits == 1 ? "" : "s") last run.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.top, 8)
                }
                if let area = model.suggestedArea(for: id), binding.wrappedValue.area != area {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "scope").foregroundStyle(.tint)
                        Text("It keeps showing up in one part of the window. Searching just there is faster and avoids look-alikes.")
                            .font(.caption)
                        Spacer(minLength: 4)
                        Button("Use It") {
                            // Found where the window was its size during the run.
                            let m = editing.macro.wrappedValue
                            if let size = model.foundWindow(for: id) {
                                binding.wrappedValue.setArea(area, in: size, fallback: m.target.windowSize,
                                                             emulator: m.target.isAndroidEmulator)
                            } else {
                                binding.wrappedValue.area = area
                            }
                        }
                            .controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                    .padding(.horizontal, 10).padding(.top, 8)
                }
                PictureStepEditor(step: binding, app: app, touch: touch, allAtOnce: allAtOnce,
                                  macroWindow: editing.macro.wrappedValue.target.windowSize,
                                  emulator: editing.macro.wrappedValue.target.isAndroidEmulator,
                                  stepChoices: editing.stepChoices().filter { $0.id != id })
            } else if case .ifStart = g.kind, let condition = editing.conditionBinding(g) {
                ConditionEditor(condition: condition, app: app, macroWindow: editing.macro.wrappedValue.target.windowSize,
                                emulator: editing.macro.wrappedValue.target.isAndroidEmulator,
                                hasOtherwise: editing.hasOtherwise(g),
                                setOtherwise: { on in
                                    let removed = editing.setOtherwise(g, on)
                                    if removed > 0 {
                                        model.flash("Removed Otherwise and the \(removed) step\(removed == 1 ? "" : "s") under it. ⌘Z brings them back.")
                                    }
                                },
                                wait: editing.waitBinding(g), allAtOnce: allAtOnce, onRemove: { editing.unwrap(g) })
            } else {
                Form {
                    Section { specific(g) }
                    Section {
                        LabeledContent("Wait before it") {
                            HStack(spacing: 4) {
                                TextField("", value: editing.waitBinding(g), format: .number.precision(.fractionLength(0...2)))
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                Text("s").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        Button("Show Raw Events") { onShowRaw(g) }
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private func specific(_ g: ActionGroup) -> some View {
        switch g.kind {
        case .click(let button, let count, let at, let hold):
            LabeledContent("Button", value: button.label)
            LabeledContent("Presses", value: count == 1 ? (hold >= 0.5 ? String(format: "Held %.1f s", hold) : "Single") : count == 2 ? "Double" : "Triple")
            if at != nil {
                positionRow(g)
                Button("Pick the Spot Again…") { repick(g) }
                    .help("Hover over the new spot; it's taken after a 3 second countdown")
                Button(editing.isTouch ? "Only Tap If the Color Matches…" : "Only Click If the Color Matches…") { onAddColorCheck(g) }
            } else {
                LabeledContent("Where", value: "Wherever the pointer is")
            }
        case .colorWait:
            positionRow(g)
            if let c = editing.colorBinding(g) {
                ColorWaitControls(wait: c, onSampleColor: { onSampleColor(g) })
            }
        case .wait:
            Text("Pauses before the next step. Set how long below.")
                .foregroundStyle(.secondary)
        case .keys(let text):
            LabeledContent("Keys", value: text)
        case .typeList:
            if let list = editing.typeListBinding(g) { TypeListEditor(list: list) }
        case .drag(_, let from, let to):
            LabeledContent("From", value: "\(Int(from.x)), \(Int(from.y))")
            LabeledContent("To", value: "\(Int(to.x)), \(Int(to.y))")
        case .scroll(let dx, let dy, _):
            LabeledContent("Amount", value: "\(Int(dy)) up, \(Int(dx)) left")
        case .move(let to):
            LabeledContent("To", value: "\(Int(to.x)), \(Int(to.y))")
        case .repeatFrom(let target, let times):
            let earlier = editing.groups.enumerated().filter { $0.element.range.upperBound <= g.range.lowerBound }
            Picker("Go back to", selection: Binding(get: { target }, set: { editing.setRepeat(g, target: $0, times: times) })) {
                ForEach(earlier, id: \.element.id) { i, e in
                    Text("\(i + 1). \(e.title(touch: editing.isTouch))").tag(editing.actionStepID(e) ?? e.id)
                }
            }
            LabeledContent("Times") {
                Stepper("\(times)", value: Binding(get: { times }, set: { editing.setRepeat(g, target: target, times: max(1, $0)) }),
                        in: 1...10_000)
            }
            Text("Runs the steps from there to here again, then carries on with the next step.")
                .font(.caption).foregroundStyle(.secondary)
        case .otherwise, .endIf:
            Text(g.kind.isOtherwise
                 ? "The steps between here and End run when the If's check doesn't hold."
                 : "The end of an If. Steps after it always run.")
                .foregroundStyle(.secondary)
            Button("Remove If (Keep Its Steps)") { editing.unwrap(g) }
        case .runMacro:
            if let target = editing.runMacroBinding(g) {
                let here = editing.macro.wrappedValue
                let others = model.macros.filter { $0.id != here.id }
                Picker("Macro", selection: target) {
                    ForEach(others) { Text($0.name).tag($0.id) }
                    if !others.contains(where: { $0.id == target.wrappedValue }) {
                        Text("Deleted macro").tag(target.wrappedValue)
                    }
                }
                if let other = model.macros.first(where: { $0.id == target.wrappedValue }) {
                    Button("Open “\(other.name)”") { model.show(other.id) }
                    if let theirs = other.target.app, theirs != here.target.app {
                        Label("It was made for \(theirs.name), but its steps run in \(here.target.app?.name ?? "this macro's app") here.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.callout)
                    }
                }
                Text("Its steps run here once, then this macro carries on. Its own Playback, Stops and Schedule aren't used.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .ifStart, .image, .other:
            Text(g.detail ?? "").foregroundStyle(.secondary)
        }
    }

    private func positionRow(_ g: ActionGroup) -> some View {
        let p = editing.pointBinding(g)
        return LabeledContent("Position") {
            HStack(spacing: 4) {
                Text("x").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { Double(p.wrappedValue.x) }, set: { p.wrappedValue.x = CGFloat($0) }),
                          format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing).frame(width: 50)
                Text("y").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { Double(p.wrappedValue.y) }, set: { p.wrappedValue.y = CGFloat($0) }),
                          format: .number.precision(.fractionLength(0)))
                    .multilineTextAlignment(.trailing).frame(width: 50)
            }
        }
    }

    private func repick(_ g: ActionGroup) {
        let p = editing.pointBinding(g)
        model.captureSpot(in: app) { spot, _ in p.wrappedValue = CGPoint(x: spot.x.rounded(), y: spot.y.rounded()) }
    }
}

/// "Type": a short popover to type the text that becomes key presses.
struct TypeTextPopover: View {
    @StateObject private var box = TextBox()
    let onAdd: (String) -> Void

    final class TextBox: ObservableObject { @Published var text = "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Text to type").font(.headline)
            TextField("", text: $box.text, prompt: Text("hello"))
                .frame(width: 240)
                .onSubmit(add)
            HStack {
                Text("Letters, numbers and punctuation.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add", action: add).keyboardShortcut(.defaultAction).disabled(box.text.isEmpty)
            }
        }
        .padding(14)
    }

    private func add() {
        guard !box.text.isEmpty else { return }
        onAdd(box.text)
        box.text = ""
    }
}
