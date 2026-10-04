import SwiftUI

struct ImageSheetItem: Identifiable {
    let image: NSImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

struct StepSheetItem: Identifiable {
    let id: UUID
}

/// Full settings for one picture step.
struct PictureStepEditor: View {
    @EnvironmentObject var model: AppModel
    let step: Binding<ImageStep>
    let app: TargetApp?
    let touch: Bool
    var allAtOnce = false
    /// Steps it can jump to with “Go to another step”.
    var stepChoices: [(id: UUID, title: String)] = []
    @StateObject private var ui = WatcherUIState()

    /// Shown in the macro editor's details panel; the screenshot cropper opens as a sheet.
    var body: some View {
        form
            .sheet(item: Binding(get: { ui.picker.map(ImageSheetItem.init) }, set: { ui.picker = $0?.image })) { item in
                RegionPickerSheet(image: item.image) { rect in
                    if ui.pickingArea {
                        step.wrappedValue.area = rect.integral
                        ui.testResult = nil
                    } else if ui.pickingVariant, let c = PictureCrop.crop(rect, from: item.image) {
                        step.wrappedValue.variants.append(PictureVariant(png: c.png, width: c.width, height: c.height))
                        ui.testResult = nil
                    } else if let c = PictureCrop.crop(rect, from: item.image) {
                        step.wrappedValue.png = c.png
                        step.wrappedValue.width = c.width
                        step.wrappedValue.height = c.height
                        step.wrappedValue.originX = Double(rect.minX)
                        step.wrappedValue.originY = Double(rect.minY)
                        ui.testResult = nil
                    }
                    ui.picker = nil
                } onCancel: {
                    ui.picker = nil
                }
            }
    }

    private var s: ImageStep { step.wrappedValue }

    private var form: some View {
        Form {
            Section("Look for") {
                LookForPicker(text: step.text, alsoPicture: s.alsoPicture,
                              spotOnly: s.mode == .click ? s.spotOnly : nil) { t, both, spot in
                    var v = step.wrappedValue
                    v.text = t
                    v.alsoPicture = both
                    v.setSpotOnly(spot)
                    step.wrappedValue = v
                }
                if s.spotOnly && s.mode == .click {
                    Text("Clicks this spot without looking: quick and predictable when the button never moves. The picture and words are kept, so you can switch back anytime.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    spotRow
                } else {
                if s.text != nil && s.alsoPicture {
                    Text("Found when either the picture or the words show up. The picture is checked first, since it's quicker.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if s.text != nil {
                    LookForTextField(text: step.text)
                    if !s.alsoPicture {
                        HStack {
                            testButton
                            Spacer()
                        }
                    }
                }
                if s.text == nil || s.alsoPicture {
                VStack(alignment: .leading, spacing: 8) {
                    if s.png.isEmpty {
                        Text("No picture yet").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ClickAreaEditor(png: s.png, area: step.clickArea)
                    }
                    HStack {
                        Button(s.png.isEmpty ? "Pick…" : "Pick Again…") { pick(area: false) }
                            .help("Box the picture on a screenshot of the window")
                        testButton
                    }
                    if !s.png.isEmpty { variantsRow }
                }
                }
                SearchAreaRow(area: step.area) { pick(area: true) }
                if s.text == nil || s.alsoPicture {
                LabeledContent {
                    HStack {
                        Slider(value: step.strictness, in: 0.6...0.98).frame(width: 100)
                        Text("\(Int((s.strictness * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Match strictness")
                    Text("Raise it if look-alikes get matched.")
                }
                }
                }
            }

            Section("What to do") {
                Picker("When it's found", selection: step.mode) {
                    ForEach(ImageStep.Mode.allCases) { Text($0.menuLabel).tag($0) }
                }
                if s.mode == .stop {
                    Text("When it shows up, the macro has done its job and stops, with a notification. Use it for a goal, like a “Finished” message.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if allAtOnce && s.mode != .click && s.mode != .stop {
                    Label("This chain runs All at once, which only uses steps that click. This step is skipped.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if s.mode == .click {
                    Picker("Click with", selection: step.button) {
                        ForEach(MouseButton.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if allAtOnce && s.spotOnly {
                        Label("All at once only clicks things it finds, so a step set to a spot is skipped. Switch Look for back to Picture, Text or Both.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    if !s.spotOnly {
                    seconds("Wait before clicking", "How long it must be visible first. Helps with things that animate in.",
                            step.settle)
                    Toggle(isOn: step.repeatUntilGone) {
                        Text("Keep \(touch ? "tapping" : "clicking") until it's gone")
                        Text("For when one \(touch ? "tap" : "click") doesn't always register because of lag.")
                    }
                    if s.repeatUntilGone {
                        seconds("Every", "Time between repeat \(touch ? "taps" : "clicks").", step.repeatEvery)
                    }
                    LabeledContent {
                        HStack(spacing: 4) {
                            Text("x").foregroundStyle(.secondary)
                            TextField("", value: step.offsetX, format: .number).multilineTextAlignment(.trailing).frame(width: 50)
                            Text("y").foregroundStyle(.secondary)
                            TextField("", value: step.offsetY, format: .number).multilineTextAlignment(.trailing).frame(width: 50)
                        }
                    } label: {
                        Text("Click offset")
                        Text("Shift the \(touch ? "tap" : "click") away from the \(s.text == nil ? "picture" : s.alsoPicture ? "match" : "text")'s center, in points.")
                    }
                    }
                }
            }

            if !allAtOnce && s.mode == .stop {
            Section("If it isn't there") {
                Picker("Look", selection: step.untilAppears) {
                    Text("Briefly, then carry on").tag(false)
                    Text("Until it appears").tag(true)
                }
                if !s.untilAppears {
                    seconds("Look for", "Then the macro carries on with the next step.", step.timeout)
                }
            }
            } else if !allAtOnce && !(s.spotOnly && s.mode == .click) {
            Section("If it doesn't happen") {
                Picker("Wait", selection: step.untilAppears) {
                    Text("As long as it takes").tag(true)
                    Text("Give up after a time").tag(false)
                }
                if !s.untilAppears {
                    seconds("Give up after", "", step.timeout)
                    Picker("Then", selection: step.otherwise) {
                        ForEach(ColorFallback.allCases) { Text($0.label).tag($0) }
                    }
                    if s.otherwise == .goToStep {
                        Picker("Step", selection: Binding(get: { s.goToStep }, set: { step.wrappedValue.goToStep = $0 })) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(stepChoices, id: \.id) { c in Text(c.title).tag(Optional(c.id)) }
                        }
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
    }

    /// The fixed spot, in window points, and a way to point at it.
    private var spotRow: some View {
        LabeledContent {
            HStack(spacing: 4) {
                Text("x").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { s.spotX ?? 0 }, set: { step.wrappedValue.spotX = $0 }), format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 54)
                Text("y").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { s.spotY ?? 0 }, set: { step.wrappedValue.spotY = $0 }), format: .number)
                    .multilineTextAlignment(.trailing).frame(width: 54)
                Button("Pick…") {
                    model.captureSpot(in: app) { p, _ in
                        step.wrappedValue.spotX = Double(p.x.rounded())
                        step.wrappedValue.spotY = Double(p.y.rounded())
                    }
                }
                .help("Hover over the spot; it's set after a 3 second countdown")
            }
        } label: {
            Text("Spot")
            Text("In the window, in points.")
        }
    }

    private func seconds(_ title: String, _ detail: String, _ value: Binding<Double>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number).multilineTextAlignment(.trailing).frame(width: 60)
                Text("s").foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
            if !detail.isEmpty { Text(detail) }
        }
    }

    private var testButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(ui.testing ? "Looking…" : "Test Now") {
                ui.testing = true
                let current = s
                Task { @MainActor in
                    ui.testResult = await model.testPicture(current, in: app)
                    ui.testing = false
                }
            }
            .disabled(ui.testing || (s.text != nil && !s.isText && !s.usesPicture))
            if let r = ui.testResult {
                Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// More pictures of the same thing: any of them counts as found.
    private var variantsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.variants.isEmpty ? "Looks different sometimes? Add another picture of it."
                                    : "Also matches any of these:")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Array(s.variants.enumerated()), id: \.offset) { i, v in
                    PictureThumbnail(png: v.png, maxWidth: 56, maxHeight: 36)
                        .overlay(alignment: .topTrailing) {
                            Button { step.wrappedValue.variants.remove(at: i) } label: {
                                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this picture")
                            .offset(x: 5, y: -5)
                        }
                }
                Button("Add Variant…") { pick(area: false, variant: true) }
                    .controlSize(.small)
                    .help("Box another picture of the same thing on a screenshot")
            }
        }
    }

    /// Screenshot the window to re-pick the picture, add a variant, or box the search area.
    private func pick(area: Bool, variant: Bool = false) {
        Task { @MainActor in
            if let img = await model.windowPicture(for: app) {
                ui.pickingVariant = variant
                ui.pickingArea = area
                ui.picker = img
            }
        }
    }
}

/// Shown instead of the step list when a macro is empty: build a chain or record.
struct EmptyMacroPrompt: View {
    let appName: String?
    let onAddPicture: () -> Void
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "plus.circle").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Add the first step").font(.title3.bold())
            Text("Add steps with Find Picture and Add above. Each one is added right away and its settings appear on the right. Or record what you do\(appName.map { " in \($0)" } ?? "").")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Record", action: onRecord)
                .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
