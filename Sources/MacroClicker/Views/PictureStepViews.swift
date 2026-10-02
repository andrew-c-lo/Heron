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
    let onDone: () -> Void
    @StateObject private var ui = WatcherUIState()

    var body: some View {
        if let screenshot = ui.picker {
            RegionPickerSheet(image: screenshot) { rect in
                if let c = PictureCrop.crop(rect, from: screenshot) {
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
        } else {
            VStack(spacing: 0) {
                form
                Divider()
                HStack {
                    Text("Changes apply right away.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 540, height: 640)
        }
    }

    private var s: ImageStep { step.wrappedValue }

    private var form: some View {
        Form {
            Section("Picture") {
                HStack(alignment: .center, spacing: 16) {
                    PictureThumbnail(png: s.png, maxWidth: 220, maxHeight: 90)
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Pick Again from Screenshot…") {
                            Task { @MainActor in
                                if let img = await model.windowPicture(for: app) { ui.picker = img }
                            }
                        }
                        Button(ui.testing ? "Looking…" : "Test Now") {
                            ui.testing = true
                            let current = s
                            Task { @MainActor in
                                ui.testResult = await model.testPicture(current, in: app)
                                ui.testing = false
                            }
                        }
                        .disabled(ui.testing)
                        if let r = ui.testResult {
                            Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                LabeledContent {
                    HStack {
                        Slider(value: step.strictness, in: 0.6...0.98).frame(width: 170)
                        Text("\(Int((s.strictness * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Match strictness")
                    Text("Raise it if look-alikes get matched.")
                }
            }

            Section("What to do") {
                Picker("When it's found", selection: step.mode) {
                    ForEach(ImageStep.Mode.allCases) { Text($0.menuLabel).tag($0) }
                }
                if allAtOnce && s.mode != .click {
                    Label("This chain runs All at once, which only uses steps that click. This step is skipped.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if s.mode == .click {
                    Picker("Click with", selection: step.button) {
                        ForEach(MouseButton.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
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
                        Text("Shift the \(touch ? "tap" : "click") away from the picture's center, in points.")
                    }
                }
            }

            if !allAtOnce {
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
                }
            }
            }
        }
        .formStyle(.grouped)
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
}

/// Shown instead of the step list when a macro is empty: build a chain or record.
struct EmptyMacroPrompt: View {
    let appName: String?
    let onAddPicture: () -> Void
    let onRecord: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.circle").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Build a chain").font(.title3.bold())
            Text("Add picture steps: each one waits for something to appear\(appName.map { " in \($0)" } ?? ""), then clicks it, one after another. You can also record your clicks and add picture steps in between.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Add Picture Step…", action: onAddPicture).buttonStyle(.borderedProminent)
                Button("Record", action: onRecord)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }
}
