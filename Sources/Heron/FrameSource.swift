import Accelerate
import CoreMedia
import ScreenCaptureKit

/// A live video feed of one window (ScreenCaptureKit stream) that keeps the latest frame.
/// macOS only sends a frame when the window's content changes, so new frames arrive the moment something
/// appears, with no polling.
final class WindowStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let windowNumber: Int
    let size: CGSize
    private var stream: SCStream?
    private let cond = NSCondition()
    private var latest: ScreenReader.WindowPixels?
    private var number = 0
    private(set) var failed = false
    var lastUsed = Timing.now()
    private let queue = DispatchQueue(label: "Heron.windowStream", qos: .userInteractive)

    init(windowNumber: Int, size: CGSize) {
        self.windowNumber = windowNumber
        self.size = size
    }

    func start(_ window: SCWindow) async -> Bool {
        let config = SCStreamConfiguration()
        config.width = Int(size.width.rounded())
        config.height = Int(size.height.rounded())
        config.scalesToFit = true // one pixel per point, whatever the display's scale
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 4
        config.ignoreShadowsSingleWindow = true
        let s = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        do {
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            stream = s
            return true
        } catch {
            failed = true
            return false
        }
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = buffer.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { out in
            var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                    rowBytes: CVPixelBufferGetBytesPerRow(pb))
            var dst = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            let bgraToRGBA: [UInt8] = [2, 1, 0, 3]
            vImagePermuteChannels_ARGB8888(&src, &dst, bgraToRGBA, vImage_Flags(kvImageNoFlags))
        }
        cond.lock()
        latest = ScreenReader.WindowPixels(rgba: rgba, width: w, height: h)
        number += 1
        cond.broadcast()
        cond.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        cond.lock()
        failed = true
        cond.broadcast()
        cond.unlock()
    }

    /// The latest frame, waiting up to `timeout` for one newer than `after`. With no newer frame (nothing on
    /// screen changed) the previous frame is returned again.
    func frame(after: Int, timeout: Double) -> (pixels: ScreenReader.WindowPixels, number: Int)? {
        lastUsed = Timing.now()
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while number <= after && !failed {
            if !cond.wait(until: deadline) { break }
        }
        guard let latest else { return nil }
        return (latest, number)
    }
}

/// Hands out window frames: from a live stream when possible, otherwise one-off screenshots.
/// Streams stop by themselves a few seconds after nobody asks for frames.
final class FrameSource: @unchecked Sendable {
    static let shared = FrameSource()

    private let lock = NSLock()
    private var streams: [Int: WindowStream] = [:]
    private var janitor: DispatchSourceTimer?
    private var fallbackNumber = 0

    /// Latest frame of `win`, waiting up to `timeout` for one newer than `after`. Call from worker threads.
    func frame(for win: TargetWindow, after: Int, timeout: Double = 0.1) -> (pixels: ScreenReader.WindowPixels, number: Int)? {
        if let s = stream(for: win), let f = s.frame(after: after, timeout: timeout) { return f }
        // Fallback: a single screenshot (slower, but always works).
        guard let px = ScreenReader.captureWindow(win) else { return nil }
        let n = lock.withLock { fallbackNumber += 1; return max(after + 1, fallbackNumber) }
        return (px, n)
    }

    private func stream(for win: TargetWindow) -> WindowStream? {
        let size = CGSize(width: win.frame.width.rounded(), height: win.frame.height.rounded())
        if let s = lock.withLock({ streams[win.windowNumber] }) {
            if !s.failed && s.size == size { return s }
            // The window was resized, or the stream died: replace it.
            s.stop()
            lock.withLock { streams[win.windowNumber] = nil }
        }
        let s = WindowStream(windowNumber: win.windowNumber, size: size)
        let ok = Self.blocking { () async -> Bool in
            guard let w = await ScreenReader.scWindow(win.windowNumber) else { return false }
            return await s.start(w)
        } ?? false
        guard ok else { return nil }
        lock.withLock { streams[win.windowNumber] = s }
        startJanitor()
        return s
    }

    private func startJanitor() {
        lock.lock()
        defer { lock.unlock() }
        guard janitor == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.stopIdleStreams() }
        t.resume()
        janitor = t
    }

    private func stopIdleStreams() {
        let now = Timing.now()
        let idle: [WindowStream] = lock.withLock {
            let list = streams.values.filter { now - $0.lastUsed > 3 }
            for s in list { streams[s.windowNumber] = nil }
            return list
        }
        idle.forEach { $0.stop() }
    }

    private static func blocking<T>(_ work: @escaping () async -> T) -> T? {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
        return box.value
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
