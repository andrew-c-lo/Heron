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
                    if model.playingMacroID == m.id {
                        Circle().fill(.green).frame(width: 8, height: 8).help("Playing")
                    }
                }
                .padding(.vertical, 3)
                .tag(SidebarItem.macro(m.id))
                .contextMenu {
                    Button("Play") { model.play(m) }
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
        let n = ActionGrouper.groups(for: m.steps).count
        let steps = "\(n) action\(n == 1 ? "" : "s")"
        return m.target.app.map { "\(steps) in \($0.name)" } ?? steps
    }
}

// MARK: - Watchers

/// One row per watcher with its switch; a row opens its settings.
struct WatchersPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Watchers click something whenever it shows up, while you keep working.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("New Watcher") { model.newWatcher() }
            }
            if model.watchers.isEmpty {
                ContentUnavailableView("No watchers yet", systemImage: "eye",
                                       description: Text("A watcher looks for a picture or some words and clicks it when it appears."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.watchers) { w in
                        WatcherRow(watcher: w)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
            }
        }
        .padding(18)
        .sheet(item: Binding(get: { editingID.map(WatcherSheetItem.init) },
                             set: { if $0 == nil { model.sidebar = .watchers } })) { item in
            if let binding = model.watcherBinding(for: item.id) {
                VStack(spacing: 0) {
                    WatcherDetailView(watcher: binding)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { model.sidebar = .watchers }.keyboardShortcut(.defaultAction)
                    }
                    .padding(12)
                }
                .frame(width: 600, height: 680)
            }
        }
    }

    private var editingID: UUID? {
        if case .watcher(let id) = model.sidebar { return id }
        return nil
    }
}

private struct WatcherSheetItem: Identifiable { let id: UUID }

private struct WatcherRow: View {
    @EnvironmentObject var model: AppModel
    let watcher: Watcher

    private var running: Bool { model.runningWatchers.contains(watcher.id) }
    private var status: WatcherStatus? { model.watcherStatus[watcher.id] }

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(watcher.name).fontWeight(.semibold).lineLimit(1)
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(state)
                .font(.callout)
                .foregroundStyle(running && status?.error == nil ? Color.green : Color.secondary)
                .lineLimit(1)
            Button("Edit…") { model.sidebar = .watcher(watcher.id) }
                .buttonStyle(.borderless)
            Toggle("", isOn: Binding(get: { running }, set: { if $0 != running { model.toggleWatcher(watcher.id) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(running ? "Stop watching" : "Start watching")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.sidebar = .watcher(watcher.id) }
        .contextMenu {
            Button("Edit…") { model.sidebar = .watcher(watcher.id) }
            Button(running ? "Stop" : "Start") { model.toggleWatcher(watcher.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteWatcher(watcher) }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let box = RoundedRectangle(cornerRadius: 6)
        Group {
            if watcher.text == nil, let data = watcher.templatePNG, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(3)
            } else {
                Image(systemName: watcher.text != nil ? "text.viewfinder" : "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 34)
        .background(box.fill(.quaternary.opacity(0.6)))
        .overlay(box.strokeBorder(.separator))
    }

    private var summary: String {
        let what: String
        if let t = watcher.text { what = t.isEmpty ? "some words" : "“\(t)”" } else { what = watcher.hasTemplate ? "its picture" : "a picture" }
        return "Clicks \(what) in \(watcher.target.app?.name ?? "any app")"
    }

    private var state: String {
        guard running else { return "Off" }
        if let e = status?.error { return e }
        let c = status?.clicks ?? 0
        return c > 0 ? "\(c) click\(c == 1 ? "" : "s")" : "Watching"
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
