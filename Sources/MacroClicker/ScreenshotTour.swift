import AppKit
import SwiftUI

/// README screenshots: when MACROCLICKER_SCREENSHOT_DIR is set (by scripts/make-demo.sh), the app steps through a
/// few pages on its own, saves a picture of its own window for each, and quits. Capturing your own window needs
/// no Screen Recording permission, and there's no mouse pointer in the pictures.
@MainActor
enum ScreenshotTour {

    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["MACROCLICKER_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let routine = model.macros.first { $0.name == "Morning routine" }?.id
        let chain = model.macros.first { $0.name == "Collect daily rewards" }?.id
        let watcher = model.watchers.first?.id
        let textWatcher = model.watchers.first { $0.text != nil }?.id
        var shots: [(String, SidebarItem?, String?)] = [
            ("visual", routine.map { .macro($0) }, "visual"),
            ("chain", chain.map { .macro($0) }, "actions"),
            ("auto-clicker", .autoClicker, nil),
            ("watcher", watcher.map { .watcher($0) }, nil),
            ("watcher-text", textWatcher.map { .watcher($0) }, nil),
            ("settings", .general, nil),
        ]
        shots.removeAll { $0.1 == nil }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.activate(ignoringOtherApps: true)
            for (name, page, viewMode) in shots {
                if let viewMode { UserDefaults.standard.set(viewMode, forKey: "stepsViewMode") }
                model.sidebar = page
                try? await Task.sleep(for: .seconds(1.2))
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(0.4))
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                   let png = capture(win) {
                    try? png.write(to: out.appendingPathComponent("\(name).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    /// The window as it appears on screen (title bar, toolbar, shadow-free), at full resolution.
    private static func capture(_ win: NSWindow) -> Data? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // Removed from the SDK headers but still present at runtime; fine for capturing our own window.
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: Fn.self)
            let includingWindow: UInt32 = 1 << 3
            let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
            if let img = fn(.null, includingWindow, UInt32(win.windowNumber), boundsIgnoreFraming | bestResolution)?
                .takeRetainedValue() {
                return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
            }
        }
        // Fallback: draw the window's content view (no title bar).
        guard let view = win.contentView?.superview ?? win.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
