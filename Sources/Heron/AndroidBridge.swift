import AppKit

/// Background taps for Android emulators (BlueStacks). The Android screen reads input from the system-wide event
/// stream, so clicks sent to the app never reach it; instead taps and swipes go into Android itself over ADB,
/// which BlueStacks ships and keeps listening on. The pointer never moves and the window doesn't need to be in front.
final class AndroidBridge: @unchecked Sendable {
    /// Emulators whose Android screen takes taps over ADB.
    static let emulators: Set<String> = ["com.now.gg.BlueStacks", "com.bluestacks.BlueStacks"]

    /// BlueStacks' own copy of adb (no download needed), or one on the PATH.
    static var adbPath: String? {
        ["/Applications/BlueStacks.app/Contents/MacOS/hd-adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether background taps can reach this app's Android screen (adb found and Android answering).
    static func available(for bundleID: String?) -> Bool {
        guard let bundleID, emulators.contains(bundleID), adbPath != nil else { return false }
        return serial() != nil
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cachedSerial: (value: String?, at: Double)?
    private nonisolated(unsafe) static var sessions: [String: AndroidBridge] = [:]
    private nonisolated(unsafe) static var sizes: [String: CGSize] = [:]

    /// The Android device to talk to: BlueStacks listens on 127.0.0.1:5555 (other instances on nearby ports).
    static func serial() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cachedSerial, Timing.now() - c.at < 30 { return c.value }
        var found: String?
        if run(["connect", "127.0.0.1:5555"])?.contains("connected") == true { found = "127.0.0.1:5555" }
        if found == nil {
            found = run(["devices"])?.split(separator: "\n")
                .compactMap { line -> String? in
                    let parts = line.split(separator: "\t")
                    return parts.count == 2 && parts[1] == "device" ? String(parts[0]) : nil
                }
                .first
        }
        cachedSerial = (found, Timing.now())
        return found
    }

    /// Android's screen size in its natural orientation (from `wm size`), e.g. 1920 × 1080.
    static func physicalSize(_ serial: String) -> CGSize? {
        lock.lock()
        if let s = sizes[serial] { lock.unlock(); return s }
        lock.unlock()
        guard let out = run(["-s", serial, "shell", "wm", "size"]) else { return nil }
        // “Physical size: 1920x1080”, and “Override size: …” when one is set (that one wins).
        var size: CGSize?
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) else { continue }
            let nums = line[r].split(separator: "x").compactMap { Double($0) }
            if nums.count == 2 { size = CGSize(width: nums[0], height: nums[1]) }
        }
        if let size { lock.lock(); sizes[serial] = size; lock.unlock() }
        return size
    }

    /// Runs adb once and returns what it printed (nil if it couldn't run or took too long).
    @discardableResult
    static func run(_ args: [String], timeout: Double = 4) -> String? {
        guard let path = adbPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: A kept-open shell, so each tap doesn't start adb again

    private let process: Process
    private let input: FileHandle

    private init?(serial: String) {
        guard let path = Self.adbPath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-s", serial, "shell"]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        process = p
        input = pipe.fileHandleForWriting
    }

    static func send(_ command: String, serial: String) {
        lock.lock(); defer { lock.unlock() }
        if sessions[serial]?.process.isRunning != true { sessions[serial] = AndroidBridge(serial: serial) }
        guard let s = sessions[serial] else { return }
        do { try s.input.write(contentsOf: Data((command + "\n").utf8)) } catch { sessions[serial] = nil }
    }
}

/// Where the Android screen is on the Mac, and how big it is in Android pixels, for one window.
struct AndroidScreen {
    /// The Android screen inside the window, in screen points (top-left origin, like window frames).
    let rect: CGRect
    /// Android's current size in pixels (portrait or landscape, as shown).
    let size: CGSize
    let serial: String

    /// BlueStacks keeps a transparent “Keymap Overlay” window exactly over the Android screen; without it, the
    /// the Android screen's shape fitted under the window's top bar (32 pt).
    static func find(pid: pid_t, windowFrame: CGRect) -> AndroidScreen? {
        guard let serial = AndroidBridge.serial(), let natural = AndroidBridge.physicalSize(serial) else { return nil }
        var rect: CGRect?
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard (w[kCGWindowName as String] as? String)?.contains("Overlay") == true,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let wd = b["Width"], let ht = b["Height"],
                  wd > 50, ht > 50, windowFrame.insetBy(dx: -2, dy: -2).contains(CGRect(x: x, y: y, width: wd, height: ht))
            else { continue }
            rect = CGRect(x: x, y: y, width: wd, height: ht)
        }
        let long = max(natural.width, natural.height), short = min(natural.width, natural.height)
        // No overlay: the Android screen keeps its shape under the top bar, whether the sidebar is showing or not.
        let r = rect ?? WindowFit.androidScreen(in: windowFrame.size, aspect: long / short)
            .map { $0.offsetBy(dx: windowFrame.minX, dy: windowFrame.minY) }
            ?? CGRect(x: windowFrame.minX, y: windowFrame.minY + 32,
                      width: max(1, windowFrame.width - 32), height: max(1, windowFrame.height - 32))
        let size = r.height >= r.width ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
        return AndroidScreen(rect: r, size: size, serial: serial)
    }

    /// The Android pixel under a screen point, or nil when it's outside the Android screen (the toolbars).
    func pixel(_ p: CGPoint) -> CGPoint? {
        guard rect.contains(p) else { return nil }
        return CGPoint(x: ((p.x - rect.minX) / rect.width * size.width).rounded(),
                       y: ((p.y - rect.minY) / rect.height * size.height).rounded())
    }

    func tap(_ p: CGPoint) {
        AndroidBridge.send("input tap \(Int(p.x)) \(Int(p.y))", serial: serial)
    }

    /// A swipe, or a long press when `from` and `to` are the same spot.
    func swipe(from a: CGPoint, to b: CGPoint, seconds: Double) {
        let ms = Int(max(0.05, seconds) * 1000)
        AndroidBridge.send("input swipe \(Int(a.x)) \(Int(a.y)) \(Int(b.x)) \(Int(b.y)) \(ms)", serial: serial)
    }
}
