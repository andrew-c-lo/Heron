import SwiftUI

// MARK: - Macros

/// Saved macros on the left, the selected one's editor on the right.
struct MacrosPage: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        HStack(spacing: 0) {
            MacroList()
                .frame(width: 230)
            Divider()
            Group {
                if case .macro(let id) = model.sidebar,
                   let binding = model.binding(for: id, undoManager: undoManager),
                   let plain = model.binding(for: id) {
                    MacroDetailView(macro: binding, name: plain.name)
                        .padding([.horizontal, .top], 12)
                        .id(id)
                } else {
                    ContentUnavailableView {
                        Label("No macro yet", systemImage: "record.circle")
                    } description: {
                        Text("Record what you do, or build steps by hand.")
                    } actions: {
                        Button("Record") { model.toggleRecording(fromUI: true) }
                        Button("New Empty Macro") { model.newMacro() }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct MacroList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.sidebar) {
            ForEach(model.macros) { m in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.name).lineLimit(1)
                        Text(subtitle(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if m.runsInBackground {
                        let on = model.isRunningInBackground(m.id)
                        Toggle("", isOn: Binding(get: { on }, set: { if $0 != on { model.toggleBackground(m.id) } }))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                            .help(on ? "Running in the background. Switch off to stop." : "Start running in the background")
                    } else if model.playingMacroID == m.id {
                        Circle().fill(.green).frame(width: 8, height: 8).help("Playing")
                    }
                }
                .padding(.vertical, 3)
                .tag(SidebarItem.macro(m.id))
                .contextMenu {
                    if m.runsInBackground {
                        Button(model.isRunningInBackground(m.id) ? "Stop" : "Start") { model.toggleBackground(m.id) }
                    } else {
                        Button("Play") { model.play(m) }
                    }
                    Button("Duplicate") { model.duplicate(m) }
                    Button("Export…") { model.export(m) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete(m) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button {
                    model.toggleRecording(fromUI: true)
                } label: {
                    Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)
                .help(model.hotkeys[.toggleRecording].map { "Record what you do (\($0.display) from anywhere)" } ?? "Record what you do")
                Menu {
                    Button("New Empty Macro") { model.newMacro() }
                    Button("New Chain") { model.newChain() }
                        .help("A macro built from picture steps: wait for something to appear, click it, then the next")
                    Button("Watch for Something…") { model.newBackgroundChain() }
                        .help("Runs in the background and clicks a picture or some words whenever they show up")
                    Divider()
                    Button("Import Macros (.json)…") { model.importMacros() }
                    Button("Show Macro Files in Finder") { model.revealMacroFolder() }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New macro")
            }
            .controlSize(.large)
            .padding(10)
        }
    }

    private func subtitle(_ m: Macro) -> String {
        if model.isRunningInBackground(m.id) {
            let c = model.backgroundClicks[m.id] ?? 0
            return c > 0 ? "Running, \(c) click\(c == 1 ? "" : "s")" : "Running in the background"
        }
        let n = ActionGrouper.groups(for: m.steps).count
        let steps = "\(n) action\(n == 1 ? "" : "s")"
        let place = m.target.app.map { " in \($0.name)" } ?? ""
        return m.runsInBackground ? "Background\(place)" : steps + place
    }
}

// MARK: - Simple mode

/// A small strip with just the speed, the button, where to click and Start, that floats above other windows.
struct SimpleStrip: View {
    @EnvironmentObject var model: AppModel
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                TextField("", value: cps, format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .ultraLight).monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .help("Clicks a second")
                Text("a second").foregroundStyle(.secondary)
            }
            Picker("Button", selection: $model.autoClick.button) {
                ForEach(MouseButton.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            Picker("Where", selection: $model.autoClick.location) {
                Text("Pointer").tag(AutoClickSettings.LocationMode.cursor)
                Text("Spots").tag(AutoClickSettings.LocationMode.points)
            }
            .labelsHidden().fixedSize()
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(model.isAutoClicking ? "Running" : "Stopped")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(model.isAutoClicking ? Color.green : Color.secondary)
                Text(model.isAutoClicking ? "\(model.autoClickCount) clicks" : " ")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { model.toggleAutoClick() } label: {
                HStack(spacing: 10) {
                    Text(model.isAutoClicking ? "Stop" : "Start")
                    if let d = model.hotkeys[.toggleAutoClick]?.display { KeyCaps(d, onDark: true) }
                }
            }
            .buttonStyle(PrimaryActionStyle(tint: model.isAutoClicking ? .green : .primary))
            .fixedSize()
            Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Show everything")
                .buttonStyle(.borderless)
                .help("Show everything")
        }
        .padding(.horizontal, 14)
        .frame(width: 700, height: 58)
    }

    private var cps: Binding<Double> {
        Binding(get: { AutoClickerView.clicksPerSecond(model.autoClick.intervalMs) },
                set: { model.autoClick.intervalMs = 1000 / min(max($0, 0.1), 1000) })
    }
}
