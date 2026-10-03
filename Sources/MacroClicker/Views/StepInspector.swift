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

    var body: some View {
        let selected = editing.groups.filter(editing.isSelected)
        Group {
            if selected.count == 1, let g = selected.first {
                details(g)
                    .id(g.id)
            } else if selected.count > 1 {
                VStack(spacing: 12) {
                    Text("\(selected.count) actions selected").font(.headline)
                    Button("Delete", role: .destructive, action: onDelete)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a step to see its settings.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
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
                Text(g.title(touch: touch)).font(.headline).lineLimit(2)
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
                PictureStepEditor(step: binding, app: app, touch: touch, allAtOnce: allAtOnce)
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
                        Button("Show Raw Steps") { onShowRaw(g) }
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
            Text("Pauses before the next action. Set how long below.")
                .foregroundStyle(.secondary)
        case .keys(let text):
            LabeledContent("Keys", value: text)
        case .drag(_, let from, let to):
            LabeledContent("From", value: "\(Int(from.x)), \(Int(from.y))")
            LabeledContent("To", value: "\(Int(to.x)), \(Int(to.y))")
        case .scroll(let dx, let dy, _):
            LabeledContent("Amount", value: "\(Int(dy)) up, \(Int(dx)) left")
        case .move(let to):
            LabeledContent("To", value: "\(Int(to.x)), \(Int(to.y))")
        case .image, .other:
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
