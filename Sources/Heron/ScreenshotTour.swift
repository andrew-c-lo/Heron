import AppKit
import SwiftUI

/// README screenshots: when HERON_SCREENSHOT_DIR is set (by scripts/make-demo.sh), the app steps through a
/// few pages on its own, saves a picture of its own window for each, and quits. Capturing your own window needs
/// no Screen Recording permission, and there's no mouse pointer in the pictures.
@MainActor
enum ScreenshotTour {

    static let selectAction = Notification.Name("HeronQASelectAction")

    static func runIfRequested(_ model: AppModel) {
        if let qa = ProcessInfo.processInfo.environment["HERON_QA_DIR"], !qa.isEmpty {
            runQA(model, into: URL(fileURLWithPath: qa, isDirectory: true))
            return
        }
        guard let dir = ProcessInfo.processInfo.environment["HERON_SCREENSHOT_DIR"], !dir.isEmpty else { return }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let routine = model.macros.first { $0.name == "Morning routine" }?.id
        let chain = model.macros.first { $0.name == "Collect daily rewards" }?.id
        let background = model.macros.first { $0.name == "Close pop-ups" }?.id
        var shots: [(String, SidebarItem?, String?)] = [
            ("visual", routine.map { .macro($0) }, "visual"),
            ("chain", chain.map { .macro($0) }, "actions"),
            ("auto-clicker", .autoClicker, nil),
            ("background", background.map { .macro($0) }, "actions"),
        ]
        shots.removeAll { $0.1 == nil }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.activate(ignoringOtherApps: true)
            // HERON_SCREENSHOT_WIDTH: capture at this window width (e.g. the 820-point minimum).
            if let w = ProcessInfo.processInfo.environment["HERON_SCREENSHOT_WIDTH"].flatMap(Double.init),
               let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                var f = win.frame
                f.size.width = w
                f.size.height = 620
                win.setFrame(f, display: true)
            }
            for (name, page, viewMode) in shots {
                if let viewMode { UserDefaults.standard.set(viewMode, forKey: "stepsViewMode") }
                model.sidebar = page
                try? await Task.sleep(for: .seconds(1.2))
                // The main picture shows a step's settings beside the list.
                if name == "chain" {
                    NotificationCenter.default.post(name: Self.selectAction, object: 0)
                    try? await Task.sleep(for: .seconds(0.8))
                }
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .seconds(0.4))
                // An open sheet is its own window.
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
                   let png = capture(win.attachedSheet ?? win) {
                    try? png.write(to: out.appendingPathComponent("\(name).png"))
                }
            }
            // A new macro opens on its templates (“What should it do?”).
            model.newMacro()
            try? await Task.sleep(for: .seconds(1.2))
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let png = capture(win) {
                try? png.write(to: out.appendingPathComponent("templates.png"))
            }
            if let m = model.selectedMacro, m.steps.isEmpty { model.delete(m) }
            model.sidebar = .autoClicker
            // Settings live in their own window.
            let main = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
            if let appMenu = NSApp.mainMenu?.items.first?.submenu,
               let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                appMenu.performActionForItem(at: i)
            }
            try? await Task.sleep(for: .seconds(1.2))
            if let win = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.windowNumber > 0 && $0.frame.width > 300 }) {
                if let png = capture(win) { try? png.write(to: out.appendingPathComponent("settings.png")) }
                win.close()
            }
            // Simple mode strip.
            UserDefaults.standard.set(true, forKey: "simpleMode")
            try? await Task.sleep(for: .seconds(1.2))
            if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let png = capture(win) {
                try? png.write(to: out.appendingPathComponent("simple.png"))
            }
            UserDefaults.standard.set(false, forKey: "simpleMode")
            // Narrow-window check: the toolbar while something runs (status grows a Stop button).
            if ProcessInfo.processInfo.environment["HERON_SCREENSHOT_WIDTH"] != nil,
               let w = background, let c = chain {
                model.sidebar = .macro(c)
                model.toggleBackground(w)
                try? await Task.sleep(for: .seconds(1.2))
                if let win = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), let png = capture(win) {
                    try? png.write(to: out.appendingPathComponent("chain-busy.png"))
                }
                model.toggleBackground(w)
            }
            NSApp.terminate(nil)
        }
    }

    /// QA sweep: every page and state at several window sizes, in the current appearance
    /// (HERON_QA_APPEARANCE=light|dark), saved as <size>-<page>.png.
    private static func runQA(_ model: AppModel, into out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        if let a = env["HERON_QA_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua)
        }
        let routine = model.macros.first { $0.name == "Morning routine" }?.id
        let chain = model.macros.first { $0.name == "Collect daily rewards" }?.id
        let background = model.macros.first { $0.name == "Close pop-ups" }?.id
        let sizes: [(String, CGFloat, CGFloat)] = [("min", 860, 600), ("default", 1000, 720), ("large", 1440, 900)]

        func mainWindow() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.frame.width > 400 } }
        func shot(_ name: String, _ win: NSWindow? = nil) async {
            try? await Task.sleep(for: .seconds(0.9))
            if let w = win ?? mainWindow(), let png = capture(w.attachedSheet ?? w) {
                try? png.write(to: out.appendingPathComponent("\(name).png"))
            }
        }
        func select(_ i: Int?) async {
            try? await Task.sleep(for: .seconds(0.3))
            NotificationCenter.default.post(name: selectAction, object: i)
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            NSApp.activate(ignoringOtherApps: true)
            for (size, w, h) in sizes {
                if let win = mainWindow() {
                    win.setFrame(NSRect(x: 60, y: 60, width: w, height: h), display: true)
                }
                model.sidebar = .autoClicker
                await shot("\(size)-clicker")
                if let routine {
                    UserDefaults.standard.set("visual", forKey: "stepsViewMode")
                    model.sidebar = .macro(routine)
                    await shot("\(size)-macro-map")
                    await select(4)
                    await shot("\(size)-macro-map-selected")
                    UserDefaults.standard.set("raw", forKey: "stepsViewMode")
                    await shot("\(size)-macro-raw")
                }
                if let chain {
                    UserDefaults.standard.set("actions", forKey: "stepsViewMode")
                    model.sidebar = .macro(chain)
                    await shot("\(size)-macro-list")
                    await select(0)
                    await shot("\(size)-step-picture")
                    await select(2)
                    await shot("\(size)-step-text")
                }
                if let routine {
                    model.sidebar = .macro(routine)
                    await select(0)
                    await shot("\(size)-step-click")
                }
                if let background {
                    model.sidebar = .macro(background)
                    await shot("\(size)-background")
                }
            }
            // Empty macro (then removed again).
            model.newMacro()
            await shot("empty-macro")
            if let m = model.selectedMacro { model.delete(m) }
            // Settings, every tab.
            let main = mainWindow()
            for tab in ["general", "hotkeys", "recording", "permissions"] {
                UserDefaults.standard.set(tab, forKey: "settingsTab")
                if !NSApp.windows.contains(where: { $0.isVisible && $0 !== main && $0.frame.width > 300 }),
                   let appMenu = NSApp.mainMenu?.items.first?.submenu,
                   let i = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) {
                    appMenu.performActionForItem(at: i)
                }
                try? await Task.sleep(for: .seconds(0.6))
                if let win = NSApp.windows.first(where: { $0.isVisible && $0 !== main && $0.windowNumber > 0 && $0.frame.width > 300 }) {
                    await shot("settings-\(tab)", win)
                }
            }
            NSApp.windows.first { $0.isVisible && $0 !== main && $0.frame.width > 300 }?.close()
            // Simple mode, stopped and running.
            UserDefaults.standard.set(true, forKey: "simpleMode")
            await shot("simple")
            UserDefaults.standard.set(false, forKey: "simpleMode")
            try? await Task.sleep(for: .seconds(0.8))
            NSApp.terminate(nil)
        }
    }

    /// The window as it appears on screen (title bar, toolbar, shadow-free), at full resolution.
    private static func capture(_ win: NSWindow) -> Data? {
        guard win.windowNumber > 0 else { return nil } // not on screen (yet)
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
