import AppKit

/// The Android screen read straight from BlueStacks over ADB, as a “virtual window”: the full-resolution Android
/// screen under a 32-pixel strip, laid out exactly like BlueStacks' own window (top bar, then the Android screen,
/// no sidebar). Everything that works in window coordinates (pictures, areas, spots, taps) then works on it
/// unchanged, whatever size the real window is, and even while it's covered or minimised.
final class AndroidFrames: @unchecked Sendable {
    static let shared = AndroidFrames()
    /// The window number the virtual window goes by (no real window has it).
    static let windowNumber = -5555
    /// The strip above the Android screen, matching BlueStacks' top bar.
    static let topBar = 32

    private let cond = NSCondition()
    private var latest: ScreenReader.WindowPixels?
    private var number = 0
    private var signature: [UInt8] = []
    private var running = false
    private var lastUsed = 0.0
    private var failures = 0

    /// The virtual window for the app with this pid, or nil when Android can't be read.
    static func window(pid: pid_t) -> TargetWindow? {
        guard let size = shared.currentSize() else { return nil }
        return TargetWindow(pid: pid, windowNumber: windowNumber,
                            frame: CGRect(x: 0, y: 0, width: size.width, height: size.height + CGFloat(topBar)))
    }

    /// The Android screen's size in pixels as shown now (portrait or landscape).
    func currentSize() -> CGSize? {
        // Android's own size setting doesn't say which way round it's showing; a screenshot does.
        guard let l = cond.withLock({ latest }) ?? frame(after: -1, timeout: 3)?.pixels else { return nil }
        return CGSize(width: l.width, height: l.height - Self.topBar)
    }

    /// The latest frame, waiting up to `timeout` for one newer than `after` (frames count up only when the screen
    /// changes). Starts reading if it isn't already; stops by itself a few seconds after nobody asks.
    func frame(after: Int, timeout: Double) -> (pixels: ScreenReader.WindowPixels, number: Int)? {
        cond.lock()
        lastUsed = Timing.now()
        if !running { running = true; Thread.detachNewThread { [weak self] in self?.loop() } }
        let deadline = Date().addingTimeInterval(max(timeout, latest == nil ? 3 : 0))
        while number <= after || latest == nil, failures < 5 {
            if !cond.wait(until: deadline) { break }
        }
        defer { cond.unlock() }
        guard let latest else { return nil }
        return (latest, number)
    }

    /// One screenshot right now (for picking pictures and Test Now).
    func snapshot() -> ScreenReader.WindowPixels? {
        if let f = frame(after: -1, timeout: 0), Timing.now() - cond.withLock({ lastFrameAt }) < 0.5 { return f.pixels }
        return Self.capture()
    }

    private var lastFrameAt = 0.0

    private func loop() {
        while true {
            cond.lock()
            if Timing.now() - lastUsed > 3 { running = false; cond.unlock(); return }
            cond.unlock()
            guard let px = Self.capture() else {
                cond.lock(); failures += 1; cond.broadcast(); cond.unlock()
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            let sig = Self.signature(px)
            cond.lock()
            failures = 0
            lastFrameAt = Timing.now()
            if sig != signature || latest == nil {
                signature = sig
                latest = px
                number += 1
                cond.broadcast()
            }
            cond.unlock()
        }
    }

    /// A coarse fingerprint of a frame, to tell whether anything changed.
    private static func signature(_ px: ScreenReader.WindowPixels) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(4096)
        let stepX = max(1, px.width / 48), stepY = max(1, px.height / 80)
        for y in stride(from: 0, to: px.height, by: stepY) {
            for x in stride(from: 0, to: px.width, by: stepX) {
                let i = (y * px.width + x) * 4
                out.append(px.rgba[i] & 0xF8); out.append(px.rgba[i + 1] & 0xF8); out.append(px.rgba[i + 2] & 0xF8)
            }
        }
        return out
    }

    /// `adb exec-out screencap` (raw RGBA, no PNG to decode), as the virtual window's pixels.
    static func capture() -> ScreenReader.WindowPixels? {
        guard let path = AndroidBridge.adbPath, let serial = AndroidBridge.serial() else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-s", serial, "exec-out", "screencap"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parse(data)
    }

    /// Raw screencap: width, height, format (1 = RGBA) as 32-bit numbers, sometimes a colour space too, then pixels.
    static func parse(_ data: Data) -> ScreenReader.WindowPixels? {
        guard data.count > 16 else { return nil }
        func u32(_ o: Int) -> Int { data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
        let w = u32(0), h = u32(4), format = u32(8)
        guard w > 0, h > 0, format == 1 || format == 2 else { return nil }
        let body = w * h * 4
        let header = data.count - body
        guard header == 12 || header == 16 else { return nil }
        let bar = topBar * w * 4
        var rgba = [UInt8](repeating: 0, count: bar + body)
        for i in stride(from: 3, to: bar, by: 4) { rgba[i] = 255 }
        rgba.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                dst.baseAddress!.advanced(by: bar).copyMemory(from: src.baseAddress!.advanced(by: header), byteCount: body)
            }
        }
        return ScreenReader.WindowPixels(rgba: rgba, width: w, height: h + topBar)
    }
}

/// Caches the target window lookup so per-event resolution stays cheap.
final class TargetResolver {
    let app: TargetApp
    private var cached: TargetWindow?
    private var lastLookup = -1.0

    /// The screen comes from Android over ADB: `window()` is the virtual window (`AndroidFrames`).
    let android: Bool
    private var cachedReal: TargetWindow?
    private var lastRealLookup = -1.0

    init(app: TargetApp, android: Bool = false) {
        self.app = app
        self.android = android
    }

    func window() -> TargetWindow? {
        let now = Timing.now()
        if now - lastLookup > 0.5 || cached == nil {
            if android {
                cached = app.runningApp.flatMap { AndroidFrames.window(pid: $0.processIdentifier) }
            } else {
                cached = WindowFinder.find(app, preferring: cached?.windowNumber)
            }
            lastLookup = now
        }
        return cached
    }

    /// The app's real window on the Mac (the same as `window()` unless reading from Android).
    func realWindow() -> TargetWindow? {
        guard android else { return window() }
        let now = Timing.now()
        if now - lastRealLookup > 0.5 || cachedReal == nil {
            cachedReal = WindowFinder.find(app, preferring: cachedReal?.windowNumber)
            lastRealLookup = now
        }
        return cachedReal
    }
}
