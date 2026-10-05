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
    func scale(for current: CGSize?, reference: CGSize? = nil) -> Double {
        guard let r = reference ?? windowSize, let c = current, r.width > 0, c.width > 0 else { return 1 }
        let s = Double(c.width / r.width)
        return abs(s - 1) < 0.02 ? 1 : s
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
