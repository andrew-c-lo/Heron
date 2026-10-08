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


/// Mini mode on the Macros tab: one macro at a time on a small card, swiped (or arrowed) through like a carousel,
/// with its round count up front and a dot per macro (green while running).
struct MacroMiniStrip: View {
    @EnvironmentObject var model: AppModel
    /// The macro on show, kept between launches.
    @AppStorage("miniMacro") private var storedID = ""
    @StateObject private var state = Carousel()
    @Binding var onTop: Bool
    let onExpand: () -> Void

    final class Carousel: ObservableObject {
        @Published var current: UUID?
        var ready = false
    }

    static let cardWidth: CGFloat = 268
    static let height: CGFloat = 86

    private var macros: [Macro] { model.macros }

    var body: some View {
        HStack(spacing: 6) {
            arrow(-1)
            VStack(spacing: 5) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(macros) { m in
                            card(m).frame(width: Self.cardWidth).id(m.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.never)
                .scrollPosition(id: $state.current)
                .frame(width: Self.cardWidth, height: 58)
                dots
            }
            arrow(1)
            VStack(spacing: 10) {
                MiniOnTopToggle(onTop: $onTop)
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show everything")
                    .accessibilityLabel("Show everything")
            }
            .font(.system(size: 11))
            .frame(width: 18)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .onAppear {
            // After the first layout: set any earlier, the carousel settles back on the first macro.
            let start = macros.first { $0.id.uuidString == storedID }?.id ?? model.selectedMacro?.id ?? macros.first?.id
            DispatchQueue.main.async {
                state.current = start
                state.ready = true
            }
        }
        .onChange(of: state.current) { _, id in if state.ready { storedID = id?.uuidString ?? "" } }
        // ← and → move between macros too.
        .background {
            Group {
                Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            }
            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private var index: Int { macros.firstIndex { $0.id == state.current } ?? 0 }

    private func step(_ by: Int) {
        guard !macros.isEmpty else { return }
        let next = (index + by + macros.count) % macros.count // wraps around
        withAnimation(.snappy(duration: 0.25)) { state.current = macros[next].id }
    }

    private func arrow(_ by: Int) -> some View {
        Button { step(by) } label: {
            Image(systemName: by < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(macros.count > 1 ? Color.secondary : Color.secondary.opacity(0.3))
        .disabled(macros.count < 2)
        .help(by < 0 ? "Previous macro (←)" : "Next macro (→)")
        .accessibilityLabel(by < 0 ? "Previous macro" : "Next macro")
    }

    /// A dot per macro (up to 12): the one on show is solid, running ones are green.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(Array(macros.prefix(12).enumerated()), id: \.element.id) { i, m in
                Circle()
                    .fill(isRunning(m) ? Color.green : i == index ? Color.primary.opacity(0.7) : Color.primary.opacity(0.18))
                    .frame(width: 5, height: 5)
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { state.current = m.id } }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func isRunning(_ m: Macro) -> Bool { model.playingMacroID == m.id || model.isRunningInBackground(m.id) }

    private func card(_ m: Macro) -> some View {
        // Ticks once a second, so its time and round stay current.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let running = isRunning(m)
            HStack(spacing: 10) {
                Button {
                    if m.runsInBackground { model.toggleBackground(m.id) }
                    else if model.playingMacroID == m.id { model.stopPlayback() }
                    else { model.play(m) }
                } label: {
                    Image(systemName: running ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(running ? Color.white : Color.primary)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(running ? Color.green : Color.primary.opacity(0.1)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(running ? "Stop \(m.name)" : "Play \(m.name)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(status(m, running: running, now: context.date))
                        .font(.caption2).foregroundStyle(running ? Color.green : Color.secondary)
                        .lineLimit(1).monospacedDigit()
                }
                Spacer(minLength: 4)
                counter(m, running: running)
            }
            .padding(.leading, 10).padding(.trailing, 12)
            .frame(width: Self.cardWidth - 8, height: 54)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(running ? Color.green.opacity(0.14) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(running ? Color.green.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1))
            .frame(width: Self.cardWidth)
            .contextMenu { Button("Show in Heron") { model.show(m.id); onExpand() } }
        }
    }

    /// The round, big, when the macro counts rounds: the current one while it runs, the last run's total otherwise.
    @ViewBuilder
    private func counter(_ m: Macro, running: Bool) -> some View {
        if m.playback.stopAfterStep != nil {
            // A last run that got through no rounds shows nothing rather than a lone 0.
            let rounds = running ? (model.live[m.id]?.rounds ?? 0) + 1 : model.lastRounds[m.id].flatMap { $0 > 0 ? $0 : nil }
            if let rounds {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(rounds)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(running ? Color.green : Color.primary)
                        .contentTransition(.numericText())
                    Text(running ? (m.playback.roundLimit.map { "of \($0)" } ?? "round") : "last run")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// While running: how long. Otherwise: Ready, background, or its next scheduled run.
    private func status(_ m: Macro, running: Bool, now: Date) -> String {
        if running {
            let time = model.live[m.id].map { AppModel.clock(now.timeIntervalSince($0.started)) } ?? ""
            return (m.runsInBackground ? "Watching · " : "Running · ") + time
        }
        if let next = model.nextScheduledRun(m) { return "Next \(next.formatted(date: .omitted, time: .shortened))" }
        return m.runsInBackground ? "Background" : "Ready"
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
