import SwiftUI

/// Settings for an If step: what it checks, how long it looks, and whether it has an Otherwise.
struct ConditionEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var condition: StepCondition
    let app: TargetApp?
    let hasOtherwise: Bool
    let setOtherwise: (Bool) -> Void
    let wait: Binding<Double>
    let allAtOnce: Bool
    let onRemove: () -> Void
    @StateObject private var ui = PickState()

    final class PickState: ObservableObject {
        @Published var picker: NSImage?
        var pickingArea = false
    }

    private var c: StepCondition { condition }

    var body: some View {
        Form {
            if allAtOnce {
                Label("If steps only work when steps run in order. Change it in Playback (⌘2).", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
            }
            Section {
                Picker("Check", selection: Binding(get: { c.kind }, set: setKind)) {
                    ForEach(StepCondition.Kind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                kindControls
            } header: {
                Text("Check")
            }
            if c.kind != .round {
                Section {
                    Picker("Look for", selection: $condition.lookFor) {
                        Text("One look").tag(0.0)
                        ForEach([1.0, 2, 5, 10, 30], id: \.self) { Text("Up to \($0.formatted()) s").tag($0) }
                        if ![0.0, 1, 2, 5, 10, 30].contains(c.lookFor) { Text("Up to \(c.lookFor.formatted()) s").tag(c.lookFor) }
                    }
                    Text(c.negate
                         ? "Checks for this long; if it never shows up, the If's steps run."
                         : "Decides as soon as it shows up; if it hasn't by then, it isn't there.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { hasOtherwise }, set: setOtherwise)) {
                    Text("Otherwise")
                    Text("Steps to run when it doesn't hold. They go between Otherwise and End.")
                }
                Text(hasOtherwise
                     ? "Steps under the If run when it holds, steps under Otherwise when it doesn't, then the macro carries on after End."
                     : "Steps under the If run only when it holds; then the macro carries on after End.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                LabeledContent("Wait before it") {
                    HStack(spacing: 4) {
                        TextField("", value: wait, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("s").foregroundStyle(.secondary)
                    }
                }
                Button("Remove If (Keep Its Steps)", action: onRemove)
                    .help("Deletes the If, Otherwise and End rows; the steps inside stay where they are")
            }
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { ui.picker.map(ImageSheetItem.init) }, set: { ui.picker = $0?.image })) { item in
            RegionPickerSheet(image: item.image) { rect in
                var v = condition
                if ui.pickingArea {
                    v.look.area = rect.integral
                } else if let crop = PictureCrop.crop(rect, from: item.image) {
                    v.look.png = crop.png
                    v.look.width = crop.width
                    v.look.height = crop.height
                    v.look.originX = Double(rect.minX)
                    v.look.originY = Double(rect.minY)
                    v.look.pictureWords = nil
                    v.look.pictureColor = nil
                }
                v.look.captureWindow = item.image.size
                condition = v
                ui.picker = nil
            } onCancel: {
                ui.picker = nil
            }
        }
    }

    @ViewBuilder
    private var kindControls: some View {
        switch c.kind {
        case .picture:
            HStack {
                if c.look.png.isEmpty {
                    Text("No picture yet").foregroundStyle(.orange)
                } else {
                    PictureThumbnail(png: c.look.png, maxWidth: 140, maxHeight: 44)
                }
                Spacer()
                Button(c.look.png.isEmpty ? "Pick Picture…" : "Pick Again…") { pick(area: false) }
            }
            isIsnt
            areaRow
        case .words:
            TextField("Words", text: Binding(get: { c.look.text ?? "" }, set: { condition.look.text = $0 }),
                      prompt: Text("Level up"))
            isIsnt
            areaRow
        case .number:
            LabeledContent("At least") {
                TextField("", value: Binding(get: { c.atLeast }, set: { condition.atLeast = max(0, $0) }), format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 80)
            }
            areaRow
            Text("Reads the numbers in the area and checks the biggest, like a level or a score. “30/50” counts as 30.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .color:
            HStack {
                if let hex = c.colorHex {
                    RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: RGB(hex: hex)?.nsColor ?? .gray))
                        .frame(width: 22, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.separator))
                    Text("\(hex) at \(Int(c.colorX)), \(Int(c.colorY))").monospacedDigit().foregroundStyle(.secondary)
                } else {
                    Text("No colour yet").foregroundStyle(.orange)
                }
                Spacer()
                Button(c.colorHex == nil ? "Pick Colour…" : "Pick Again…") {
                    model.captureSpot(in: app) { p, hex in
                        condition.colorX = Double(p.x.rounded())
                        condition.colorY = Double(p.y.rounded())
                        condition.colorHex = hex ?? condition.colorHex
                    }
                }
                .help("Hover over the spot; its colour is taken after a 3 second countdown")
            }
            isIsnt
        case .round:
            Picker("When", selection: $condition.roundRule) {
                ForEach(StepCondition.RoundRule.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent(c.roundRule == .every ? "Rounds" : "Round") {
                Stepper(c.roundRule == .every ? "\(StepCondition.ordinal(max(1, c.roundN))) round" : "\(max(1, c.roundN))",
                        value: Binding(get: { max(1, c.roundN) }, set: { condition.roundN = max(1, $0) }), in: 1...10_000)
            }
            Text("Rounds count from 1 each time you press Play. Set how many there are in Playback › Repeat (⌘2).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isIsnt: some View {
        Picker("When it", selection: $condition.negate) {
            Text(c.kind == .color ? "Matches" : "Is on screen").tag(false)
            Text(c.kind == .color ? "Doesn't match" : "Isn't on screen").tag(true)
        }
    }

    private var areaRow: some View {
        HStack {
            Text(c.look.area.map { "Looks in a \(Int($0.width)) × \(Int($0.height)) area" } ?? "Looks in the whole window")
                .foregroundStyle(.secondary)
            Spacer()
            Button(c.look.area == nil ? "Choose Area…" : "Change…") { pick(area: true) }
            if c.look.area != nil { Button("Whole Window") { condition.look.area = nil } }
        }
        .font(.callout)
    }

    private func setKind(_ k: StepCondition.Kind) {
        var v = condition
        v.kind = k
        // Picture looks only at the picture; words only at the words.
        switch k {
        case .picture: v.look.text = nil
        case .words: v.look.text = v.look.text ?? ""
        default: break
        }
        condition = v
    }

    private func pick(area: Bool) {
        guard let app else {
            model.flash("Choose the app to watch first (Target, ⌘1).")
            return
        }
        ui.pickingArea = area
        Task { @MainActor in
            if let img = await model.windowPicture(for: app) { ui.picker = img }
        }
    }
}
