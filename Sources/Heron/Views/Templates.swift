import SwiftUI

/// The ways to start a macro. Each asks a question or two, then sets the macro up in the normal editor.
enum MacroTemplate: String, CaseIterable, Identifiable {
    case whenItAppears, inOrder, onSchedule, untilDone, blank
    var id: String { rawValue }

    var title: String {
        switch self {
        case .whenItAppears: "Click it whenever it appears"
        case .inOrder: "Do these steps in order"
        case .onSchedule: "Run on a schedule"
        case .untilDone: "Repeat until it's done"
        case .blank: "Blank"
        }
    }

    var subtitle: String {
        switch self {
        case .whenItAppears: "Pop-ups, buttons, prompts"
        case .inOrder: "Record it once"
        case .onSchedule: "Daily, or every few hours"
        case .untilDone: "Stops at a finish screen"
        case .blank: "Start from scratch"
        }
    }

    var icon: String {
        switch self {
        case .whenItAppears: "viewfinder"
        case .inOrder: "list.number"
        case .onSchedule: "calendar.badge.clock"
        case .untilDone: "repeat"
        case .blank: "doc"
        }
    }

    /// The guided steps, shown under the cards.
    var steps: [(String, String)] {
        switch self {
        case .whenItAppears:
            [("Which app?", "Choose the window to watch."),
             ("Box the button", "A screenshot opens; drag around it."),
             ("Done", "Heron watches all the time and clicks it whenever it shows up.")]
        case .inOrder:
            [("Which app?", "Choose the window to record in."),
             ("Record", "Do it once yourself; each tap finds its target when played back."),
             ("Done", "It plays back in order.")]
        case .onSchedule:
            [("Which app?", "Choose the window to record in."),
             ("Record", "Do it once yourself."),
             ("When?", "Pick the times: daily, every few hours, or when the app opens.")]
        case .untilDone:
            [("Which app?", "Choose the window to record in."),
             ("Record the loop", "The steps to repeat."),
             ("How do you know it's finished?", "Box a picture or type the words it shows at the end.")]
        case .blank:
            [("Empty editor", "Add steps with Find Picture and Add, or record.")]
        }
    }

    var records: Bool { self == .inOrder || self == .onSchedule || self == .untilDone }
}

/// Shown in the editor while a macro has no steps: pick what it should do.
struct TemplateChooser: View {
    let app: TargetApp?
    @Binding var selected: MacroTemplate
    let isRecording: Bool
    let onSelectApp: (TargetApp?) -> Void
    let onStart: (MacroTemplate) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("What should it do?").font(.title3.weight(.semibold))
                    Text("Pick a starting point. You can change anything afterwards.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                    ForEach(MacroTemplate.allCases) { t in card(t) }
                }
                guide
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func card(_ t: MacroTemplate) -> some View {
        let on = t == selected
        return Button { withAnimation(Motion.snap(reduceMotion)) { selected = t } } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: t.icon).font(.title3).foregroundStyle(on ? Color.accentColor : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).fontWeight(.medium).foregroundStyle(.primary)
                    Text(t.subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(on ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: on ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(selected.steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.0).fontWeight(.medium)
                        Text(s.1).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // The first step's control sits on its row.
                    if i == 0, selected != .blank {
                        TargetAppMenu(selection: app, onSelect: onSelectApp).fixedSize()
                    }
                }
                .padding(.vertical, 10)
                if i < selected.steps.count - 1 { Divider() }
            }
            HStack {
                Spacer()
                Button(startLabel) { onStart(selected) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    // Boxing a picture needs the app's window; recording can also cover the whole screen.
                    .disabled(isRecording || (selected == .whenItAppears && app == nil))
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    private var startLabel: String {
        switch selected {
        case .whenItAppears: "Box the Button…"
        case .blank: "Start Empty"
        default: isRecording ? "Recording…" : "Start Recording"
        }
    }
}

/// Settings for “Type from a list”: the items, and what happens after each and at the end.
struct TypeListEditor: View {
    @Binding var list: TypeList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Items, one per line")
            TextEditor(text: Binding(get: { list.items.joined(separator: "\n") },
                                     set: { list.items = $0.components(separatedBy: "\n") }))
                .font(.body.monospaced())
                .frame(minHeight: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text("Each time this step runs, it types the next one. Blank lines are skipped.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Toggle("Press Return after each item", isOn: $list.pressReturn)
        Picker("When the list runs out", selection: $list.whenDone) {
            ForEach(TypeList.WhenDone.allCases) { Text($0.label).tag($0) }
        }
        let count = list.entries.count
        LabeledContent {
            HStack {
                Text(count == 0 ? "No items yet" : list.next >= count ? "All \(count) typed" : "Item \(list.next + 1) of \(count)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Stepper("", value: Binding(get: { min(list.next, max(0, count - 1)) }, set: { list.next = max(0, $0) }),
                        in: 0...max(0, count - 1))
                    .labelsHidden()
                    .disabled(count == 0)
                Button("Start Over") { list.next = 0 }
                    .disabled(list.next == 0)
            }
        } label: {
            Text("Next")
            Text("Carries on where the last run stopped.")
        }
    }
}
