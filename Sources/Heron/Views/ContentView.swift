import SwiftUI

/// The three things Heron does, as tabs in the window toolbar.
enum MainTab: String, CaseIterable, Identifiable {
    case clicker = "Clicker", macros = "Macros"
    var id: String { rawValue }
}

extension AppModel {
    var tab: MainTab {
        get {
            switch sidebar ?? .autoClicker {
            case .macro, .macros: .macros
            default: .clicker
            }
        }
        set {
            guard newValue != tab else { return }
            switch newValue {
            case .clicker: sidebar = .autoClicker
            case .macros: sidebar = (selectedMacroID ?? macros.first?.id).map { .macro($0) } ?? .macros
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("simpleMode") private var simple = false
    /// Mini mode stays above other windows unless unpinned.
    @AppStorage("miniOnTop") private var onTop = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var macroMini: Bool { simple && model.tab == .macros }

    var body: some View {
        Group {
            // Mini mode follows the tab you were on: the auto clicker's strip here, or (Macros) a separate
            // floating card while this window steps aside.
            if simple && model.tab != .macros {
                SimpleStrip(onTop: $onTop) { simple = false }
            } else {
                full
            }
        }
        // The card is put up before the window steps aside, so Heron always has a window showing.
        .onAppear { MiniPanel.shared.show(macroMini, model: model) }
        .onChange(of: macroMini) { _, on in MiniPanel.shared.show(on, model: model) }
        .background(MainWindowAside(aside: macroMini) { simple = false })
        .toolbar(simple && model.tab != .macros ? .hidden : .visible, for: .windowToolbar)
        // The small strip stays above other windows, like a remote control.
        .background(WindowLevel(floating: simple && model.tab != .macros && onTop))
    }

    private var full: some View {
        VStack(spacing: 0) {
            // (Screenshot copies run without permissions on purpose; don't show the banner there.)
            if !model.hasAccessibility || !model.hasInputMonitoring,
               ProcessInfo.processInfo.environment["HERON_SCREENSHOTS"] == nil {
                PermissionBanner()
            }
            Group {
                switch model.tab {
                case .clicker: AutoClickerView()
                case .macros: MacrosPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        // Messages appear briefly over the content instead of in a permanent bar.
        .overlay(alignment: .bottom) {
            if let msg = model.statusMessage {
                MessageToast(text: msg, action: model.statusAction)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.reveal(reduceMotion), value: model.statusMessage)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                    ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // An explicit width: with fixedSize the toolbar under-measured it and the buttons beside it overlapped.
                .frame(width: 180)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { simple = true } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .accessibilityLabel("Mini mode")
                    .help(model.tab == .macros ? "Mini mode: up to three macros in a small window that stays on top"
                                               : "Mini mode: a small strip that stays on top")
                SettingsLink { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
                    .help("Settings (⌘,)")
            }
        }
        .frame(minWidth: 860, idealWidth: 1000, maxWidth: .infinity, minHeight: 600, idealHeight: 720, maxHeight: .infinity)
    }
}

/// Keeps the window above others while `floating` (the simple strip), and hides the window title: the tabs
/// say where you are.
struct WindowLevel: NSViewRepresentable {
    let floating: Bool

    final class Probe: NSView {
        var floating = false { didSet { apply() } }
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            apply()
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
        }
        override func layout() { super.layout(); apply() }
        func apply() {
            guard let window else { return }
            let level: NSWindow.Level = floating ? .floating : .normal
            if window.level != level { window.level = level }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.floating = floating }
}

/// Puts the main window away while the macro mini card is up, and back when it closes. Opening the window
/// another way meanwhile (the Dock, the menu bar) ends mini mode.
struct MainWindowAside: NSViewRepresentable {
    let aside: Bool
    let onShownAnyway: () -> Void

    final class Probe: NSView {
        var aside = false { didSet { if aside != oldValue { if aside { asideSince = Date() }; apply() } } }
        var onShownAnyway: () -> Void = {}
        private var asideSince = Date()
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Ignored just after stepping aside: at launch the window becomes key on its own.
                    guard let self, self.aside, Date().timeIntervalSince(self.asideSince) > 1.5 else { return }
                    self.onShownAnyway()
                }
            }
            apply()
        }
        func apply() {
            guard let window else { return }
            if aside {
                // Not closed or hidden: window-tidying utilities (like Vorssaint) quit apps whose windows all go
                // away. It stays open but out of sight: see-through, at the back, not clickable, skipped by ⌘`.
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.collectionBehavior.insert([.ignoresCycle, .transient])
                window.orderBack(nil)
            } else if window.alphaValue < 1 || !window.isVisible {
                window.alphaValue = 1
                window.ignoresMouseEvents = false
                window.collectionBehavior.remove([.ignoresCycle, .transient])
                window.makeKeyAndOrderFront(nil)
                // You asked for it (Show everything), so it comes to the front even from another app.
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.onShownAnyway = onShownAnyway
        view.aside = aside
    }
}

/// The macro mini card's own window: a small borderless panel that floats (unless unpinned) and doesn't make
/// Heron the active app when clicked, so pressing Play leaves you in the app you're using.
@MainActor
final class MiniPanel {
    static let shared = MiniPanel()
    private var panel: NSPanel?
    private var moveObserver: NSObjectProtocol?
    private static let cornerKey = "miniTopLeft"

    /// A panel that takes key presses (← →) when clicked, without activating the app.
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    func show(_ visible: Bool, model: AppModel) {
        guard visible else { panel?.orderOut(nil); return }
        if panel == nil {
            let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 356, height: 86),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: MiniPanelRoot().environmentObject(model))
            p.contentView = host
            p.setContentSize(host.fittingSize)
            if let saved = UserDefaults.standard.string(forKey: Self.cornerKey) {
                p.setFrameTopLeftPoint(NSPointFromString(saved))
            } else if let screen = NSScreen.main {
                p.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - p.frame.width - 24, y: screen.visibleFrame.maxY - 24))
            }
            moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: p.frame.minX, y: p.frame.maxY)), forKey: Self.cornerKey)
                }
            }
            panel = p
        }
        setOnTop(UserDefaults.standard.object(forKey: "miniOnTop") as? Bool ?? true)
        panel?.orderFrontRegardless()
    }

    func setOnTop(_ on: Bool) { panel?.level = on ? .floating : .normal }

    var isShowing: Bool { panel?.isVisible == true }
}

/// The mini card with its rounded, material background.
private struct MiniPanelRoot: View {
    @AppStorage("miniOnTop") private var onTop = true
    @AppStorage("simpleMode") private var simple = false

    var body: some View {
        MacroMiniStrip(onTop: $onTop) { simple = false }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .fixedSize()
            .onChange(of: onTop) { _, on in MiniPanel.shared.setOnTop(on) }
    }
}

// MARK: - Status bar

/// The bottom bar: what this page is doing, and its main button with the hotkey that does the same.
struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    private struct Content {
        var dot: Color, title: String, detail: String
        var button: String, hotkey: HotkeyAction?, tint: Color = .primary, enabled = true
        var action: () -> Void
    }

    var body: some View {
        let c = content
        HStack(spacing: 12) {
            Circle().fill(c.dot).frame(width: 9, height: 9)
            Text(c.title).font(.callout.weight(.semibold))
            Text(c.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 12)
            Button(action: c.action) {
                HStack(spacing: 10) {
                    Text(c.button)
                    if let hk = c.hotkey, let display = model.liveHotkey(hk)?.display { KeyCaps(display, onDark: true) }
                }
            }
            .buttonStyle(PrimaryActionStyle(tint: c.tint))
            .fixedSize()
            .disabled(!c.enabled)
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var content: Content {
        if let n = model.countdown {
            return Content(dot: .orange, title: "Starting in \(n)…", detail: "Press the hotkey again to cancel",
                           button: "Cancel", hotkey: nil, action: { model.stopAll() })
        }
        if model.isRecording {
            return Content(dot: .red, title: "Recording", detail: "\(model.recordedSteps) steps so far",
                           button: "Stop Recording", hotkey: .toggleRecording, tint: .red,
                           action: { model.toggleRecording(fromUI: true) })
        }
        switch model.tab {
        case .clicker:
            if model.isAutoClicking {
                var detail = "\(model.autoClickCount) click\(model.autoClickCount == 1 ? "" : "s")"
                if model.autoClickSkipped > 0 { detail += ", \(model.autoClickSkipped) skipped" }
                return Content(dot: .green, title: "Running", detail: detail, button: "Stop", hotkey: .toggleAutoClick,
                               tint: .green, action: { model.toggleAutoClick() })
            }
            return Content(dot: .secondary.opacity(0.5), title: "Stopped", detail: clickerSummary, button: "Start",
                           hotkey: .toggleAutoClick, action: { model.toggleAutoClick() })
        case .macros:
            let others = model.backgroundRunning.count
            let also = others > 0 ? ", \(others) in the background" : ""
            if let id = model.playingMacroID {
                let name = model.macros.first { $0.id == id }?.name ?? ""
                return Content(dot: .green, title: "Playing", detail: "\(name), \(model.playStatus)\(also)", button: "Stop",
                               hotkey: .togglePlayback, tint: .green, action: { model.stopPlayback() })
            }
            guard let m = model.selectedMacro else {
                return Content(dot: .secondary.opacity(0.5), title: others > 0 ? "\(others) in the background" : "Ready",
                               detail: "Record or create a macro", button: "Play", hotkey: .togglePlayback, enabled: false,
                               action: {})
            }
            if m.runsInBackground {
                if model.isRunningInBackground(m.id) {
                    let c = model.backgroundClicks[m.id] ?? 0
                    return Content(dot: .green, title: "Running in the background",
                                   detail: "\(c) click\(c == 1 ? "" : "s") so far" + (others > 1 ? ", \(others - 1) more running" : ""),
                                   button: "Stop", hotkey: nil, tint: .green, action: { model.stopBackground(m.id) })
                }
                return Content(dot: .secondary.opacity(0.5), title: "Off", detail: "Runs in the background once started\(also)",
                               button: "Start", hotkey: nil, action: { model.startBackground(m.id) })
            }
            let n = ActionGrouper.stepCount(m.steps)
            let detail = "\(n) step\(n == 1 ? "" : "s")" + (m.target.app.map { " in \($0.name)" } ?? "") + also
            return Content(dot: others > 0 ? .green : .secondary.opacity(0.5), title: "Ready", detail: detail, button: "Play",
                           hotkey: .togglePlayback, action: { model.play(m) })
        }
    }

    private var clickerSummary: String {
        let s = model.autoClick
        let type = ["", "", "Double-", "Triple-"][min(3, max(1, s.clicksPerEvent))]
        let what = type.isEmpty ? "\(s.button.label) click" : type + s.button.label.lowercased() + " click"
        let where_ = s.location == .cursor ? "wherever the pointer is"
            : "\(s.points.count) spot\(s.points.count == 1 ? "" : "s")"
        return "\(what), \(where_)" + (s.target.app.map { " in \($0.name)" } ?? "")
    }
}

/// The page's main button: filled, with the hotkey drawn as keycaps inside.
struct PrimaryActionStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = tint == .primary ? (scheme == .dark ? Color(white: 0.92) : Color(white: 0.14)) : tint
        let ink: Color = tint == .primary && scheme == .dark ? .black : .white
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(ink)
            .padding(.leading, 16).padding(.trailing, 8)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 9).fill(fill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

/// A hotkey like "⌃⌥C" drawn as keycaps.
struct KeyCaps: View {
    let keys: [String]
    var onDark = false

    init(_ display: String, onDark: Bool = false) {
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var caps: [String] = [], rest = ""
        for ch in display where ch != " " {
            if modifiers.contains(ch) { caps.append(String(ch)) } else { rest.append(ch) }
        }
        if !rest.isEmpty { caps.append(rest) }
        keys = caps
        self.onDark = onDark
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                Text(k)
                    .font(.system(size: 11.5, weight: .semibold))
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, k.count > 1 ? 5 : 0)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(onDark ? AnyShapeStyle(.foreground.opacity(0.16)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(onDark ? AnyShapeStyle(.foreground.opacity(0.25)) : AnyShapeStyle(Color.secondary.opacity(0.35))))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Permissions needed").bold()
                Text("Accessibility lets Heron click and type. Input Monitoring lets it record. Enable Heron in System Settings, then come back — this banner disappears on its own.")
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

/// A short message that slides up over the content and fades away by itself.
struct MessageToast: View {
    let text: String
    /// A way out of the problem the message names (“Open TextEdit”).
    var action: AppModel.StatusAction? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.center)
            if let action {
                Button(action.title, action: action.perform)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
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
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).fixedSize() }
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
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).fixedSize() }
            }
        }
    }
}
