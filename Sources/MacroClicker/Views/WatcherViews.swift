import SwiftUI

final class WatcherUIState: ObservableObject {
    @Published var picker: NSImage?
    @Published var testResult: String?
    @Published var testing = false
    /// The open screenshot is for choosing the search area (not the picture).
    @Published var pickingArea = false
}

/// "Look for: Picture | Text". Text mode is `text != nil`, so an empty box stays in text mode.
struct LookForPicker: View {
    @Binding var text: String?

    var body: some View {
        Picker("Look for", selection: Binding(get: { text != nil }, set: { text = $0 ? (text ?? "") : nil })) {
            Text("Picture").tag(false)
            Text("Text").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden() // the section is already titled "Look for"
    }
}

/// The text to look for, read on-device with Live Text–style recognition.
struct LookForTextField: View {
    @Binding var text: String?

    var body: some View {
        LabeledContent {
            TextField("Text", text: Binding(get: { text ?? "" }, set: { text = $0 }), prompt: Text("Claim"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
        } label: {
            Text("Text")
            Text("Found anywhere it appears, ignoring capitals. Read on this Mac; nothing is uploaded.")
        }
    }
}

/// Limit the search to part of the window: faster, and avoids matches elsewhere.
struct SearchAreaRow: View {
    @Binding var area: CGRect?
    let onChoose: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(area.map { "\(Int($0.width)) × \(Int($0.height)) at (\(Int($0.minX)), \(Int($0.minY)))" } ?? "Whole window")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button(area == nil ? "Choose…" : "Change…", action: onChoose)
                if area != nil {
                    Button("Clear") { area = nil }
                }
            }
        } label: {
            Text("Search area")
            Text("Only look inside part of the window.")
        }
    }
}

struct WatcherDetailView: View {
    @EnvironmentObject var model: AppModel
    @Binding var watcher: Watcher
    @StateObject private var ui = WatcherUIState()

    private var running: Bool { model.runningWatchers.contains(watcher.id) }
    private var status: WatcherStatus? { model.watcherStatus[watcher.id] }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: running ? "eye.fill" : "eye")
                        .font(.title2)
                        .foregroundStyle(running ? Color.green : Color.secondary)
                        .frame(width: 30)
                    Text(statusLine)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(running ? .primary : .secondary)
                    Spacer()
                }
                if let problem = model.watcherProblem(watcher) {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                LookForPicker(text: $watcher.text)
                if watcher.text != nil {
                    LookForTextField(text: $watcher.text)
                    HStack {
                        testButton
                        Spacer()
                    }
                } else {
                HStack(alignment: .center, spacing: 16) {
                    templatePreview
                    VStack(alignment: .leading, spacing: 8) {
                        Button(watcher.hasTemplate ? "Pick Again from Screenshot…" : "Pick from Screenshot…") { pick() }
                        testButton
                    }
                    Spacer(minLength: 0)
                }
                }
                SearchAreaRow(area: $watcher.area) { pick(area: true) }
                if watcher.text == nil {
                LabeledContent {
                    HStack {
                        Slider(value: $watcher.strictness, in: 0.6...0.98)
                            .frame(width: 180)
                        Text("\(Int((watcher.strictness * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Match strictness")
                    Text("How closely the screen must match the picture. 80% suits most buttons; raise it if look-alikes get clicked.")
                }
                }
            } header: {
                Text("Look for")
            }

            Section("When it appears") {
                Picker(selection: $watcher.button) {
                    ForEach(MouseButton.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Click with")
                }
                .pickerStyle(.segmented)
                seconds("Click every", watcher.text != nil ? "While the text stays on screen." : "While the picture stays on screen.",
                        $watcher.interval)
                seconds("Wait before the first click", "How long it must be visible first. Helps with buttons that animate in.",
                        $watcher.firstClickDelay)
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("", value: $watcher.maxClicks, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                        Text("clicks").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Stop after")
                    Text("0 keeps going until you stop it.")
                }
                LabeledContent {
                    HStack(spacing: 4) {
                        Text("x").foregroundStyle(.secondary)
                        TextField("", value: $watcher.offsetX, format: .number).multilineTextAlignment(.trailing).frame(width: 50)
                        Text("y").foregroundStyle(.secondary)
                        TextField("", value: $watcher.offsetY, format: .number).multilineTextAlignment(.trailing).frame(width: 50)
                    }
                } label: {
                    Text("Click offset")
                    Text("Shift the click away from the \(watcher.text != nil ? "text" : "picture")'s center, in points.")
                }
            }

            Section("Target") {
                TargetControls(target: $watcher.target, onSelectApp: { watcher.target.app = $0 })
            }

            Section {
                Button("Delete Watcher", role: .destructive) { model.deleteWatcher(watcher) }
            }
        }
        .formStyle(.grouped)
        // Name in the window title (click to rename) and Start/Stop in the toolbar, like the other pages.
        .navigationTitle($watcher.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleWatcher(watcher.id)
                } label: {
                    Label(running ? "Stop" : "Start", systemImage: running ? "stop.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .sheet(item: Binding(get: { ui.picker.map(PickerImage.init) }, set: { ui.picker = $0?.image })) { item in
            RegionPickerSheet(image: item.image) { rect in
                if ui.pickingArea { watcher.area = rect.integral } else { useRegion(rect, of: item.image) }
                ui.picker = nil
            } onCancel: {
                ui.picker = nil
            }
        }
    }

    private var statusLine: String {
        guard running else { return "Not running" }
        guard let st = status else { return "Starting…" }
        if let e = st.error { return e }
        let seen = st.visible ? "On screen now" : st.lastSeen.map { "Last seen \(relative($0))" } ?? "Not seen yet"
        let clicks = "\(seen) · \(st.clicks) click\(st.clicks == 1 ? "" : "s")"
        return watcher.text != nil ? clicks : clicks + " · best match \(Int((st.score * 100).rounded()))%"
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "\(s)s ago" : "\(s / 60)m ago"
    }

    @ViewBuilder
    private var templatePreview: some View {
        let box = RoundedRectangle(cornerRadius: 8)
        Group {
            if let data = watcher.templatePNG, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 220, maxHeight: 90)
                    .padding(8)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus").font(.title2)
                    Text("No picture yet").font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(width: 160, height: 70)
            }
        }
        .background(box.fill(.quaternary.opacity(0.5)))
        .overlay(box.strokeBorder(.separator))
    }

    private func seconds(_ title: String, _ detail: String, _ value: Binding<Double>) -> some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number).multilineTextAlignment(.trailing).frame(width: 60)
                Text("s").foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }

    private var testButton: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(ui.testing ? "Looking…" : "Test Now") { test() }
                .disabled(ui.testing || !watcher.canSearch)
            if let r = ui.testResult {
                Text(r).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pick(area: Bool = false) {
        Task { @MainActor in
            if let img = await model.windowPicture(for: watcher.target.app) {
                ui.pickingArea = area
                ui.picker = img
            }
        }
    }

    private func test() {
        ui.testing = true
        let w = watcher
        Task { @MainActor in
            ui.testResult = await model.testWatcher(w)
            ui.testing = false
        }
    }

    /// Crop `rect` (window points) out of the full-resolution screenshot and store it as the picture to find.
    private func useRegion(_ rect: CGRect, of image: NSImage) {
        guard let c = PictureCrop.crop(rect, from: image) else { return }
        watcher.templatePNG = c.png
        watcher.templateWidth = c.width
        watcher.templateHeight = c.height
        ui.testResult = nil
    }
}

private struct PickerImage: Identifiable {
    let image: NSImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}
