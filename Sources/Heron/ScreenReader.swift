import AppKit
import ScreenCaptureKit

/// An sRGB color, stored in macros as "#RRGGBB".
struct RGB: Equatable {
    var r: UInt8, g: UInt8, b: UInt8

    init(r: UInt8, g: UInt8, b: UInt8) { (self.r, self.g, self.b) = (r, g, b) }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        r = UInt8(v >> 16 & 0xFF); g = UInt8(v >> 8 & 0xFF); b = UInt8(v & 0xFF)
    }

    init?(_ color: NSColor) {
        guard let c = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        r = byte(c.redComponent); g = byte(c.greenComponent); b = byte(c.blueComponent)
    }

    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }

    /// Every channel within `tolerance` (0 = exact).
    func matches(_ o: RGB, tolerance: Int) -> Bool {
        abs(Int(r) - Int(o.r)) <= tolerance && abs(Int(g) - Int(o.g)) <= tolerance && abs(Int(b) - Int(o.b)) <= tolerance
    }
}

/// Reads screen pixels and window snapshots via ScreenCaptureKit (needs Screen Recording permission).
enum ScreenReader {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static func requestPermission() {
        _ = CGRequestScreenCaptureAccess()
        Permissions.open("Privacy_ScreenCapture")
    }

    private static let cache = ContentCache()

    /// Color at a global (top-left origin) screen point. Blocking, so call it from worker threads only.
    static func color(at p: CGPoint) -> RGB? {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await colorAsync(at: p)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
        return box.value
    }

    static func colorAsync(at p: CGPoint) async -> RGB? {
        guard let content = await cache.content() else { return nil }
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(p) }) else { return nil }
        let bounds = CGDisplayBounds(display.displayID)
        let pixelsPerPoint = CGFloat(CGDisplayCopyDisplayMode(display.displayID)?.pixelWidth ?? Int(bounds.width)) / bounds.width

        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: (p.x - bounds.minX).rounded(.down), y: (p.y - bounds.minY).rounded(.down), width: 1, height: 1)
        let side = max(1, Int(pixelsPerPoint.rounded()))
        config.width = side
        config.height = side
        config.showsCursor = false // the real cursor may be sitting right on the point
        config.colorSpaceName = CGColorSpace.sRGB
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return topLeftPixel(image)
    }

    /// Picture of the app's window, sized in points like the window (for the visual macro view).
    static func snapshot(of app: TargetApp) async -> NSImage? {
        guard let win = WindowFinder.find(app),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(win.windowNumber) }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(win.frame.width * 2)
        config.height = Int(win.frame.height * 2)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.scalesToFit = true // on 1× displays the window is only half as many pixels; scale it up to fill
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        // Keep the full-resolution (2×) pixels; the image's point size matches the window so coordinates line up.
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = win.frame.size
        let img = NSImage(size: win.frame.size)
        img.addRepresentation(rep)
        return img
    }

    struct WindowPixels {
        let rgba: [UInt8]
        let width: Int
        let height: Int
    }

    /// The window at one pixel per point (window-relative coordinates = pixel coordinates). Async version.
    /// ScreenCaptureKit's handle for a window. Listing all windows is slow, so results are reused for a while.
    static func scWindow(_ number: Int) async -> SCWindow? {
        if let w = windowCache.get(number) { return w }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
        windowCache.store(content.windows)
        return content.windows.first { $0.windowID == CGWindowID(number) }
    }

    private static let windowCache = WindowCache()

    private final class WindowCache: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [CGWindowID: SCWindow] = [:]
        private var fetchedAt = -100.0
        func get(_ n: Int) -> SCWindow? {
            lock.withLock { Timing.now() - fetchedAt < 10 ? windows[CGWindowID(n)] : nil }
        }
        func store(_ list: [SCWindow]) {
            lock.withLock {
                windows = Dictionary(list.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
                fetchedAt = Timing.now()
            }
        }
    }

    static func captureWindowAsync(_ win: TargetWindow) async -> WindowPixels? {
        guard let scWindow = await scWindow(win.windowNumber) else { return nil }
        let w = Int(win.frame.width.rounded()), h = Int(win.frame.height.rounded())
        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              let px = TemplateMatcher.rgba(cg, width: w, height: h) else { return nil }
        return WindowPixels(rgba: px, width: w, height: h)
    }

    /// Blocking version for worker threads.
    static func captureWindow(_ win: TargetWindow) -> WindowPixels? {
        final class Box: @unchecked Sendable { var value: WindowPixels? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await captureWindowAsync(win)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return box.value
    }

    private static func topLeftPixel(_ image: CGImage) -> RGB? {
        guard let pixel = image.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return ok ? RGB(r: bytes[0], g: bytes[1], b: bytes[2]) : nil
    }

    private final class ResultBox: @unchecked Sendable { var value: RGB? }

    /// Fetching the list of displays is slow, so reuse it for a few seconds.
    private final class ContentCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: SCShareableContent?
        private var fetchedAt = -100.0

        func content() async -> SCShareableContent? {
            let now = Timing.now()
            if let c = lock.withLock({ now - fetchedAt < 5 ? cached : nil }) { return c }
            guard let fresh = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
            lock.withLock {
                cached = fresh
                fetchedAt = now
            }
            return fresh
        }
    }
}

/// System eyedropper (magnifier loupe). Calls back on the main thread with "#RRGGBB", or nil if cancelled.
@MainActor
enum Eyedropper {
    private static var sampler: NSColorSampler?

    static func pick(_ done: @escaping (String?) -> Void) {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            let hex = color.flatMap { RGB($0)?.hex }
            Task { @MainActor in
                sampler = nil
                done(hex)
            }
        }
    }
}

extension ScreenReader.WindowPixels {
    /// Pixels of a saved picture (for reading text from stuck screens).
    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(rgba: data, width: w, height: h)
    }
}
