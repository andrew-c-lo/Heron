// Records two app windows side by side into an animated GIF for the README (used by scripts/record-demo.sh).
// The windows are captured straight from the window server, so other windows and the pointer never show up.
//   record-demo <out.gif> <seconds> <left bundle id> <right bundle id>
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 5, let seconds = Double(args[2]) else {
    print("usage: record-demo <out.gif> <seconds> <left bundle id> <right bundle id>"); exit(2)
}
_ = NSApplication.shared // window capture needs a connection to the window server
let out = URL(fileURLWithPath: args[1])
let ids = [args[3], args[4]]
let fps = 10.0
let outputWidth = 1000.0 // pixels

func window(_ bundle: String, in content: SCShareableContent) -> SCWindow? {
    content.windows
        .filter { $0.owningApplication?.bundleIdentifier == bundle && $0.windowLayer == 0 && $0.frame.width > 200 }
        .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
}

func capture(_ w: SCWindow) async -> CGImage? {
    let filter = SCContentFilter(desktopIndependentWindow: w)
    // Always at 2× (a window on a non-Retina display would otherwise come out half size).
    let cfg = SCStreamConfiguration()
    cfg.width = Int(filter.contentRect.width * 2)
    cfg.height = Int(filter.contentRect.height * 2)
    cfg.scalesToFit = true
    cfg.showsCursor = false
    cfg.ignoreShadowsSingleWindow = true
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
}

/// Both windows on a quiet backdrop, bottoms aligned, scaled to the output width.
func compose(_ a: CGImage, _ b: CGImage) -> CGImage? {
    let pad = 56.0, gap = 40.0
    let contentW = Double(a.width + b.width) + gap + pad * 2
    let contentH = Double(max(a.height, b.height)) + pad * 2
    let s = outputWidth / contentW
    let W = Int(outputWidth), H = Int((contentH * s).rounded())
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s, y: s)
    var x = pad
    for img in [a, b] {
        let r = CGRect(x: x, y: pad, width: Double(img.width), height: Double(img.height))
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40, color: CGColor(gray: 0, alpha: 0.5))
        ctx.draw(img, in: r)
        ctx.restoreGState()
        x += Double(img.width) + gap
    }
    return ctx.makeImage()
}

func bytes(_ img: CGImage) -> Data? { img.dataProvider?.data as Data? }

Task {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
        print("Can't list windows. Allow Screen Recording for this terminal."); exit(1)
    }
    let windows = ids.compactMap { window($0, in: content) }
    guard windows.count == 2 else { print("Couldn't find both windows: \(ids)"); exit(1) }

    // Each frame lasts until the next one was taken, so the GIF plays at real speed however fast capture is.
    var frames: [(CGImage, Double)] = []
    let start = Date()
    var lastTime = 0.0
    var last: [CGImage?] = [nil, nil]
    var missed = 0, taken = 0
    var changedAt = 0.0
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        if t - lastTime < 1 / fps, !frames.isEmpty { try? await Task.sleep(for: .milliseconds(5)); continue }
        async let l = capture(windows[0])
        async let r = capture(windows[1])
        let (li, ri) = await (l, r)
        if li == nil || ri == nil { missed += 1 }
        taken += 1
        last = [li ?? last[0], ri ?? last[1]]
        guard let a = last[0], let b = last[1], let f = compose(a, b) else { continue }
        if !frames.isEmpty { frames[frames.count - 1].1 += t - lastTime }
        lastTime = t
        // Unchanged frames just lengthen the one before (keeps the file small). Once the screen has settled
        // for a while, the run is over: stop, while its “Done” message is still showing.
        if let prev = frames.last, bytes(prev.0) == bytes(f) {
            if t > 6, t - changedAt > 1.5 { break }
            continue
        }
        changedAt = t
        frames.append((f, 0))
    }
    if !frames.isEmpty { frames[frames.count - 1].1 += Date().timeIntervalSince(start) - lastTime }
    // Hold the last frame so the loop has a pause before it starts again.
    if !frames.isEmpty { frames[frames.count - 1].1 += 2 }

    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { exit(1) }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (img, delay) in frames {
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { print("Couldn't write the GIF."); exit(1) }
    let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("Wrote \(out.path): \(frames.count) frames, \(size / 1024) KB (\(taken) captures, \(missed) missed)")
    exit(0)
}
RunLoop.main.run()
