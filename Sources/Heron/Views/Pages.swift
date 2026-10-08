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
            ForEach(model.macros.filter { $0.folder == nil }) { m in row(m) }
            // Folders: collapsible sections (hover a header to fold it).
            ForEach(model.folders, id: \.self) { folder in
                Section(folder) {
                    ForEach(model.macros.filter { $0.folder == folder }) { m in row(m) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // Record is the main way to start, so it keeps its label; the rest are small icon buttons.
            HStack(spacing: 4) {
                Button {
                    model.toggleRecording(fromUI: true)
                } label: {
                    Label(model.isRecording ? "Stop" : "Record", systemImage: model.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .help(model.liveHotkey(.toggleRecording).map { "Record what you do (\($0.display) from anywhere)" } ?? "Record what you do")
                iconButton("plus", "New macro: build it step by step") { model.newMacro() }
                iconButton("eye", "Watch for something: runs in the background and clicks a picture or some words whenever they show up") {
                    model.newBackgroundChain()
                }
                iconButton("square.and.arrow.down", "Import macros (.json)") { model.importMacros() }
            }
            .padding(10)
        }
    }

    private func iconButton(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 18, height: 18) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }

    private func row(_ m: Macro) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).lineLimit(1)
                Text(subtitle(m)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let s = m.schedule, s.enabled {
                Image(systemName: "calendar.badge.clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Scheduled: \(s.summary(appName: m.target.app?.name))")
            }
            RunDot(running: model.playingMacroID == m.id || model.isRunningInBackground(m.id)) {
                if m.runsInBackground { model.toggleBackground(m.id) }
                else if model.playingMacroID == m.id { model.stopPlayback() }
                else { model.play(m) }
            }
            .help(model.playingMacroID == m.id || model.isRunningInBackground(m.id) ? "Running. Click to stop."
                  : m.runsInBackground ? "Click to start it in the background" : "Click to play")
        }
        .padding(.vertical, 3)
        .tag(SidebarItem.macro(m.id))
        .contextMenu {
            if m.runsInBackground {
                Button(model.isRunningInBackground(m.id) ? "Stop" : "Start") { model.toggleBackground(m.id) }
            } else {
                Button("Play") { model.play(m) }
            }
            Menu("Move to Folder") {
                ForEach(model.folders.filter { $0 != m.folder }, id: \.self) { f in
                    Button(f) { model.setFolder(f, for: m.id) }
                }
                if !model.folders.isEmpty { Divider() }
                Button("New Folder…") { if let name = askFolderName() { model.setFolder(name, for: m.id) } }
                if m.folder != nil {
                    Divider()
                    Button("Remove from Folder") { model.setFolder(nil, for: m.id) }
                }
            }
            Button("Duplicate") { model.duplicate(m) }
            Button("Export…") { model.export(m) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(m) }
        }
    }

    private func askFolderName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Name the folder for this macro."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Daily"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func subtitle(_ m: Macro) -> String {
        if model.isRunningInBackground(m.id) {
            let c = model.backgroundClicks[m.id] ?? 0
            return c > 0 ? "Running, \(c) click\(c == 1 ? "" : "s")" : "Running in the background"
        }
        let n = ActionGrouper.stepCount(m.steps)
        let steps = "\(n) step\(n == 1 ? "" : "s")"
        let place = m.target.app.map { " in \($0.name)" } ?? ""
        return m.runsInBackground ? "Background\(place)" : steps + place
    }
}

// MARK: - Simple mode

/// Mini mode on the Clicker tab: just the speed, the button, where to click and Start, above other windows.
struct SimpleStrip: View {
    @EnvironmentObject var model: AppModel
    @Binding var onTop: Bool
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
                    if let d = model.liveHotkey(.toggleAutoClick)?.display { KeyCaps(d, onDark: true) }
                }
            }
            .buttonStyle(PrimaryActionStyle(tint: model.isAutoClicking ? .green : .primary))
            .fixedSize()
            MiniOnTopToggle(onTop: $onTop)
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


/// Mini mode on the Macros tab: up to three macros, each one click from running, with what it's doing now.
struct MacroMiniStrip: View {
    @EnvironmentObject var model: AppModel
    /// The macros picked for mini mode (comma-separated ids). Empty: the one you're looking at and the newest others.
    @AppStorage("miniMacros") private var stored = ""
    @Binding var onTop: Bool
    let onExpand: () -> Void

    private var slots: [Macro] {
        let picked = stored.split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            .compactMap { id in model.macros.first { $0.id == id } }
        if !picked.isEmpty { return Array(picked.prefix(3)) }
        var out: [Macro] = []
        for m in [model.selectedMacro].compactMap({ $0 }) + model.macros.reversed() where !out.contains(where: { $0.id == m.id }) {
            out.append(m)
            if out.count == 3 { break }
        }
        return out
    }

    private func save(_ ms: [Macro]) { stored = ms.prefix(3).map(\.id.uuidString).joined(separator: ",") }

    var body: some View {
        // Ticks once a second while something runs, so round and time stay current.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                if slots.isEmpty {
                    Text("No macros yet. Show everything to record or build one.")
                        .foregroundStyle(.secondary).padding(14)
                }
                ForEach(slots) { m in
                    row(m, now: context.date)
                    Divider()
                }
                footer
            }
        }
        .frame(width: 440)
    }

    private func isRunning(_ m: Macro) -> Bool { model.playingMacroID == m.id || model.isRunningInBackground(m.id) }

    private func row(_ m: Macro, now: Date) -> some View {
        let running = isRunning(m)
        return HStack(spacing: 10) {
            Button {
                if m.runsInBackground { model.toggleBackground(m.id) }
                else if model.playingMacroID == m.id { model.stopPlayback() }
                else { model.play(m) }
            } label: {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(running ? Color.white : Color.primary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(running ? Color.green : Color.secondary.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help(running ? "Stop “\(m.name)”" : "Play “\(m.name)”")
            .accessibilityLabel(running ? "Stop \(m.name)" : "Play \(m.name)")
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).fontWeight(.medium).lineLimit(1)
                Text(status(m, running: running, now: now))
                    .font(.caption).foregroundStyle(running ? Color.green : Color.secondary)
                    .lineLimit(1).monospacedDigit()
            }
            Spacer(minLength: 6)
            Menu {
                Button("Show in Heron") { model.show(m.id); onExpand() }
                Menu("Swap For") {
                    ForEach(model.macros.filter { mm in !slots.contains { $0.id == mm.id } }) { other in
                        Button(other.name) { save(slots.map { $0.id == m.id ? other : $0 }) }
                    }
                }
                Button("Remove From Mini Mode") { save(slots.filter { $0.id != m.id }) }
                    .disabled(slots.count <= 1)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Options for \(m.name)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// “Round 3 of 5 · 4:12” while running; otherwise its steps and app, and when it next runs on its own.
    private func status(_ m: Macro, running: Bool, now: Date) -> String {
        if running { return model.liveLines(now: now).first { $0.id == m.id }?.line ?? "Running" }
        let n = ActionGrouper.stepCount(m.steps)
        var s = (m.runsInBackground ? "Background · " : "") + "\(n) step\(n == 1 ? "" : "s")"
            + (m.target.app.map { " in \($0.name)" } ?? "")
        if let next = model.nextScheduledRun(m) { s += " · next \(next.formatted(date: .omitted, time: .shortened))" }
        return s
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if slots.count < 3, slots.count < model.macros.count {
                Menu {
                    ForEach(model.macros.filter { mm in !slots.contains { $0.id == mm.id } }) { other in
                        Button(other.name) { save(slots + [other]) }
                    }
                } label: {
                    Label("Add a Macro", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Spacer()
            MiniOnTopToggle(onTop: $onTop)
            Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .accessibilityLabel("Show everything")
                .buttonStyle(.borderless)
                .help("Show everything")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// Pins the mini strip above other windows (on by default), or lets it go behind them like any window.
struct MiniOnTopToggle: View {
    @Binding var onTop: Bool

    var body: some View {
        Toggle(isOn: $onTop) { Image(systemName: onTop ? "pin.fill" : "pin") }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .foregroundStyle(onTop ? Color.accentColor : Color.secondary)
            .help(onTop ? "Always on top. Click to let other windows cover it." : "Click to keep it above other windows")
            .accessibilityLabel("Always on top")
    }
}

/// A macro's run state at a glance: an empty ring when idle, green when running. Click to start or stop.
struct RunDot: View {
    let running: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            // The fill is always there and fades, rather than being added: an added view gets its own layer,
            // which snapped to a different pixel than the ring and sat off-centre on non-Retina screens.
            ZStack {
                Circle().strokeBorder(running ? Color.green : Color.secondary.opacity(0.6), lineWidth: 1.5)
                Circle().fill(Color.green).padding(3).opacity(running ? 1 : 0)
            }
            .drawingGroup()
            .frame(width: 12, height: 12)
            .padding(4)
            .contentShape(Rectangle())
            .animation(Motion.snap(reduceMotion), value: running)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(running ? "Stop" : "Start")
    }
}
