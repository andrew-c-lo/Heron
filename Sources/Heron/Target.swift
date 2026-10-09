import AppKit
import CoreGraphics

struct TargetApp: Codable, Equatable, Hashable {
    var bundleID: String
    var name: String

    static func running() -> [TargetApp] {
        let me = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> TargetApp? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != me else { return nil }
            return TargetApp(bundleID: id, name: app.localizedName ?? id)
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }
}

enum DeliveryMode: String, Codable, CaseIterable, Identifiable {
    /// Real cursor moves to each click and stays there.
    case normal
    /// Real cursor jumps to the click and is put straight back.
    case jumpReturn
    /// Events are sent directly to the target app; the real cursor never moves.
    case background

    var id: String { rawValue }

    /// What's offered: leaving the cursor wherever the last click was isn't a useful choice, so “Normal” is gone
    /// (macros saved with it load as Jump & return).
    static let choices: [DeliveryMode] = [.background, .jumpReturn]

    /// Apps known to ignore clicks sent in the background (they read input another way), so new macros for them
    /// start in Jump & return and the Target panel warns if Background is picked. BlueStacks is here for when its
    /// ADB tool is missing; normally its taps go in over ADB (see `AndroidBridge`).
    static let backgroundIgnoredBy: Set<String> = [
        "com.now.gg.BlueStacks", "com.now.gg.BlueStacksAirMIM", "com.bluestacks.BlueStacks",
    ]

    static func backgroundWorks(in app: TargetApp?) -> Bool {
        guard let app else { return false }
        // BlueStacks: its Android screen takes taps over ADB, which it ships with.
        if AndroidBridge.emulators.contains(app.bundleID) { return AndroidBridge.adbPath != nil }
        return !backgroundIgnoredBy.contains(app.bundleID)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = raw == "normal" ? .jumpReturn : DeliveryMode(rawValue: raw) ?? .jumpReturn
    }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .jumpReturn: "Jump & return"
        case .background: "Background"
        }
    }

    var explanation: String {
        switch self {
        case .normal: "Moves your real cursor to each click."
        case .jumpReturn: "Cursor jumps to the click and instantly back. Works in every app, including ones that ignore background clicks (some games)."
        case .background: "Clicks go straight to the target app, and your cursor never moves. If an app ignores them, use Test, then switch to Jump & return."
        }
    }
}

struct TargetOptions: Codable, Equatable {
    /// When set, all coordinates are relative to this app's window's top-left corner.
    var app: TargetApp?
    var delivery: DeliveryMode = .jumpReturn
    var activateFirst = true
    var pauseWhenInactive = false
    /// Jump & return only: wait for the user's mouse to be still this long before each jump.
    var jumpWhenStillMs: Double = 150
    /// The app window's size (points) the macro was made for. When the window is a different size, pictures,
    /// areas and positions are resized to match.
    var windowSize: CGSize?

    /// How much bigger (or smaller) the window is now than when the macro was made (1 = same size).
    func scale(for current: CGSize?, reference: CGSize? = nil) -> Double { fit(for: current, reference: reference).s }

    /// How the macro's window coordinates land on the window as it is now (see `WindowFit`).
    func fit(for current: CGSize?, reference: CGSize? = nil) -> WindowFit {
        .between(reference ?? windowSize, current, emulator: isAndroidEmulator)
    }

    /// An Android emulator (BlueStacks): only its Android screen scales; its toolbars stay the same size.
    var isAndroidEmulator: Bool { app.map { AndroidBridge.emulators.contains($0.bundleID) } ?? false }
}

/// How a macro's window coordinates map onto the window as it is now: scaled, and for an emulator shifted, so
/// positions, areas and pictures follow its Android screen rather than the whole window.
struct WindowFit: Equatable {
    var s: Double = 1
    var dx: Double = 0
    var dy: Double = 0

    static let same = WindowFit()
    var isSame: Bool { self == .same }

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s + dx, y: p.y * s + dy) }
    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * s + dx, y: r.minY * s + dy, width: r.width * s, height: r.height * s)
    }

    static func between(_ reference: CGSize?, _ current: CGSize?, emulator: Bool) -> WindowFit {
        guard let r = reference, let c = current, r.width > 0, c.width > 0 else { return .same }
        if emulator, let a = androidScreen(in: r), let b = androidScreen(in: c), a.width > 0 {
            let s = Double(b.width / a.width)
            let fit = WindowFit(s: s, dx: Double(b.minX) - Double(a.minX) * s, dy: Double(b.minY) - Double(a.minY) * s)
            return abs(s - 1) < 0.02 && abs(fit.dx) < 1 && abs(fit.dy) < 1 ? .same : fit
        }
        let s = Double(c.width / r.width)
        return abs(s - 1) < 0.02 ? .same : WindowFit(s: s)
    }

    /// The other way round: from the current window back to the reference one.
    var inverse: WindowFit { WindowFit(s: 1 / s, dx: -dx / s, dy: -dy / s) }

    /// Where BlueStacks' Android screen sits in a window this size: under its 32 pt top bar, as tall as it fits,
    /// at 9:16 (16:9 when the window is wider than tall). Whatever width is left over is its right-hand toolbar,
    /// open or collapsed, which is why the whole window's size alone can't be used to resize.
    static func androidScreen(in w: CGSize, aspect: CGFloat = 16.0 / 9) -> CGRect? {
        let top: CGFloat = 32
        let available = w.height - top
        guard available > 50, w.width > 50, aspect >= 1 else { return nil }
        let ratio: CGFloat = w.width > w.height ? aspect : 1 / aspect
        var width = available * ratio, height = available
        if width > w.width { width = w.width; height = width / ratio }
        return CGRect(x: 0, y: top + (available - height) / 2, width: width, height: height)
    }
}

struct TargetWindow {
    let pid: pid_t
    let windowNumber: Int
    let frame: CGRect
}

enum WindowFinder {
    /// The app's main (frontmost, on-screen preferred) normal window, in global top-left coordinates.
    /// `preferring`: a window number seen earlier; kept if it still exists even when off-screen (e.g. another Space).
    static func find(_ app: TargetApp, preferring: Int? = nil) -> TargetWindow? {
        guard let running = app.runningApp else { return nil }
        let pid = running.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        var onscreen: TargetWindow?
        var fallback: TargetWindow?
        // The list is ordered front to back.
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let bounds = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 40, rect.height > 40 else { continue }
            let win = TargetWindow(pid: pid, windowNumber: number, frame: rect)
            if number == preferring { return win }
            if onscreen == nil, (w[kCGWindowIsOnscreen as String] as? Bool) == true { onscreen = win }
            if fallback == nil { fallback = win }
        }
        return onscreen ?? fallback
    }

    /// The app window under a screen point (front to back), skipping Heron's own windows.
    static func window(at p: CGPoint) -> (app: TargetApp, window: TargetWindow)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.contains(p),
                  let running = NSRunningApplication(processIdentifier: pid), let id = running.bundleIdentifier
            else { continue }
            return (TargetApp(bundleID: id, name: running.localizedName ?? id), TargetWindow(pid: pid, windowNumber: number, frame: frame))
        }
        return nil
    }

    static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// Caches the target window lookup so per-event resolution stays cheap.
final class TargetResolver {
    let app: TargetApp
    private var cached: TargetWindow?
    private var lastLookup = -1.0

    init(app: TargetApp) { self.app = app }

    func window() -> TargetWindow? {
        let now = Timing.now()
        if now - lastLookup > 0.5 || cached == nil {
            cached = WindowFinder.find(app, preferring: cached?.windowNumber)
            lastLookup = now
        }
        return cached
    }
}

extension ImageStep {
    /// The window size the picture and area are measured in: the one it was picked in, else the macro's.
    /// nil when unknown, or when what's saved can't be right (the picture or area sits past the edge of that
    /// window, so they were really picked in a bigger one): then they're used as they are.
    func reference(fallback: CGSize?) -> CGSize? {
        guard let r = captureWindow ?? fallback else { return nil }
        let slack = 4.0
        if !png.isEmpty, width > 0, originX + width > r.width + slack || originY + height > r.height + slack { return nil }
        if let a = area, a.minX > r.width - slack || a.minY > r.height - slack { return nil }
        return r
    }

    /// An area drawn on (or found in) a window of `size`, kept in the step's own measurements.
    mutating func setArea(_ rect: CGRect, in size: CGSize, fallback: CGSize?, emulator: Bool) {
        guard let ref = reference(fallback: fallback), !png.isEmpty else {
            // Words only, or the saved size was wrong (the picture is used as it is, so it belongs to this window
            // as much as any): measure the step in this window.
            area = rect.integral
            if png.isEmpty || captureWindow != nil || fallback != nil { captureWindow = size }
            return
        }
        area = WindowFit.between(ref, size, emulator: emulator).inverse.rect(rect).integral
    }

    /// A new picture picked in a window of `size`: from now on the step is measured in that window, and its area
    /// and other pictures are carried over to match.
    mutating func adoptWindow(_ size: CGSize, fallback: CGSize?, emulator: Bool) {
        if let old = reference(fallback: fallback) {
            let f = WindowFit.between(old, size, emulator: emulator)
            if let a = area { area = f.rect(a).integral }
            for i in variants.indices {
                variants[i].width *= f.s
                variants[i].height *= f.s
            }
        }
        captureWindow = size
    }

    /// A picture picked in a window of `size`, at the step's own measurements (for “also looks like” pictures).
    func variantScale(pickedIn size: CGSize, fallback: CGSize?, emulator: Bool) -> Double {
        guard let ref = reference(fallback: fallback) else { return 1 }
        return 1 / WindowFit.between(ref, size, emulator: emulator).s
    }
}
