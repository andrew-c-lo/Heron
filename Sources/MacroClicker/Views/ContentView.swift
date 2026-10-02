import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            VStack(spacing: 0) {
                // (Screenshot copies run without permissions on purpose; don't show the banner there.)
                if !model.hasAccessibility || !model.hasInputMonitoring,
                   ProcessInfo.processInfo.environment["MACROCLICKER_SCREENSHOTS"] == nil {
                    PermissionBanner()
                }
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Messages appear briefly over the content instead of in a permanent bar.
            .overlay(alignment: .bottom) {
                if let msg = model.statusMessage {
                    MessageToast(text: msg)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.reveal(reduceMotion), value: model.statusMessage)
            .toolbar {
                ToolbarItem(placement: .status) { ActivityStatus() }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

/// The main area for whatever is picked in the sidebar.
private struct DetailView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        switch model.sidebar ?? .autoClicker {
        case .autoClicker:
            AutoClickerView().navigationTitle("Auto Clicker")
        case .watcher(let id):
            if let binding = model.watcherBinding(for: id) {
                WatcherDetailView(watcher: binding)
                    .id(id)
            } else {
                ContentUnavailableView("No watcher selected", systemImage: "eye",
                                       description: Text("Add a watcher in the sidebar."))
            }
        case .macro(let id):
            if let binding = model.binding(for: id, undoManager: undoManager),
               let plain = model.binding(for: id) {
                MacroDetailView(macro: binding, name: plain.name)
                    .padding([.horizontal, .top], 12)
                    .id(id)
            } else {
                ContentUnavailableView("No macro selected", systemImage: "record.circle",
                                       description: Text("Record a macro or pick one in the sidebar."))
            }
        case .hotkeys:
            HotkeysSettingsView().navigationTitle("Hotkeys")
        case .recording:
            RecordingSettingsView().navigationTitle("Recording")
        case .permissions:
            PermissionsSettingsView().navigationTitle("Permissions")
        case .general:
            GeneralSettingsView().navigationTitle("General")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.sidebar) {
            Section("Tools") {
                Label("Auto Clicker", systemImage: "cursorarrow.click.2")
                    .tag(SidebarItem.autoClicker)
            }

            Section("Watchers") {
                ForEach(model.watchers) { w in
                    let running = model.runningWatchers.contains(w.id)
                    let visible = model.watcherStatus[w.id]?.visible == true
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(w.name).lineLimit(1)
                            Text(running ? (visible ? "On screen, clicking" : "Watching…") : "Off")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: running ? "eye.fill" : "eye")
                            .foregroundStyle(running ? (visible ? Color.orange : Color.green) : Color.accentColor)
                    }
                    .tag(SidebarItem.watcher(w.id))
                    .contextMenu {
                        Button(running ? "Stop" : "Start") { model.toggleWatcher(w.id) }
                        Divider()
                        Button("Delete", role: .destructive) { model.deleteWatcher(w) }
                    }
                }
            }

            Section("Macros") {
                ForEach(model.macros) { m in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.name).lineLimit(1)
                            Text("\(ActionGrouper.groups(for: m.steps).count) actions · \(formatDuration(m.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: model.playingMacroID == m.id ? "play.fill" : "record.circle")
                            .foregroundStyle(model.playingMacroID == m.id ? Color.green : Color.accentColor)
                    }
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

            Section("Settings") {
                Label("Hotkeys", systemImage: "command").tag(SidebarItem.hotkeys)
                Label("Recording", systemImage: "waveform").tag(SidebarItem.recording)
                Label("Permissions", systemImage: "lock.shield").tag(SidebarItem.permissions)
                Label("General", systemImage: "gearshape").tag(SidebarItem.general)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { recordArea }
    }

    private var recordArea: some View {
        VStack(spacing: 6) {
            Button {
                model.toggleRecording(fromUI: true)
            } label: {
                Label(recordTitle, systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording || model.countdown != nil ? .red : .accentColor)
            .controlSize(.large)

            Text(model.hotkeys[.toggleRecording].map { "or press \($0.display) from anywhere" }
                 ?? "Tip: set a recording hotkey in Hotkeys")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                // Everything you can add, in one place.
                Menu {
                    Button { model.newWatcher() } label: { Label("New Watcher", systemImage: "eye") }
                    Button { model.newChain() } label: { Label("New Chain", systemImage: "link") }
                        .help("A macro built from picture steps: wait for something to appear, click it, then the next")
                    Button { model.newMacro() } label: { Label("New empty macro", systemImage: "record.circle") }
                    Divider()
                    Button { model.importMacros() } label: { Label("Import macros (.json)", systemImage: "square.and.arrow.down") }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Button { model.revealMacroFolder() } label: { Image(systemName: "folder") }
                    .help("Show macro files in Finder")
            }
            .buttonStyle(.borderless)
        }
        .padding(10)
    }

    private var recordTitle: String {
        if let c = model.countdown { return "Starting in \(c)…" }
        return model.isRecording ? "Stop (\(model.recordedSteps) steps)" : "Record Macro"
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions needed").bold()
                Text("Accessibility lets MacroClicker click and type. Input Monitoring lets it record. Enable MacroClicker in System Settings, then come back — this banner disappears on its own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !model.hasAccessibility {
                Button("Accessibility…") { Permissions.requestAccessibility() }
            }
            if !model.hasInputMonitoring {
                Button("Input Monitoring…") { Permissions.requestInputMonitoring() }
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

/// What's running right now, shown in the window toolbar. A Stop button appears while anything runs.
struct ActivityStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let c = model.countdown {
                    dot(.orange)
                    Text("Starting in \(c)… (press the hotkey again to cancel)")
                } else if model.isRecording {
                    dot(.red)
                    Text("Recording — \(model.recordedSteps) steps")
                } else if let id = model.playingMacroID {
                    dot(.green)
                    Text("Playing “\(model.macros.first { $0.id == id }?.name ?? "")” — \(model.playStatus)")
                } else if model.isAutoClicking {
                    dot(.blue)
                    Text("Auto clicking: \(model.autoClickCount) clicks")
                } else if !model.runningWatchers.isEmpty {
                    dot(.green)
                    Text("\(model.runningWatchers.count) watcher\(model.runningWatchers.count == 1 ? "" : "s") running")
                } else {
                    dot(.secondary)
                    Text("Idle").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.tail)
            // Never let a long status push the page's own toolbar buttons (Play, Stop…) into the overflow menu.
            .frame(minWidth: 72, maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if model.isBusy {
                Button(model.hotkeys[.stopAll].map { "Stop  \($0.display)" } ?? "Stop") { model.stopAll() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
    }

    private func dot(_ c: Color) -> some View {
        Circle().fill(c).frame(width: 7, height: 7)
    }
}

/// A short message that slides up over the content and fades away by itself.
struct MessageToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .frame(maxWidth: 520)
    }
}

/// Small helper: a labelled numeric field with a unit suffix.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String = ""
    var width: CGFloat = 80

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: $value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: width)
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var unit: String = ""
    var range: ClosedRange<Int> = 0...1_000_000

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField("", value: $value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Stepper("", value: $value, in: range).labelsHidden()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
            }
        }
    }
}
