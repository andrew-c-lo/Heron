import SwiftUI
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !ok { failures += 1 }
}
func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    // Test screenshot: 513×1126 points with a checker pattern (2× pixels, like real captures).
    let size = NSSize(width: 513, height: 1126)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1026, pixelsHigh: 2252, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for y in stride(from: 0, to: 2252, by: 40) { for x in stride(from: 0, to: 1026, by: 40) {
        NSColor(hue: CGFloat((x + y) % 360) / 360, saturation: 0.6, brightness: ((x / 40 + y / 40) % 2 == 0) ? 0.9 : 0.5, alpha: 1).setFill()
        NSRect(x: x, y: y, width: 40, height: 40).fill()
    } }
    NSGraphicsContext.restoreGraphicsState()
    rep.size = size
    let image = NSImage(size: size); image.addRepresentation(rep)

    let st = RegionPickerState(imageSize: size)
    let host = NSHostingView(rootView: RegionPickerSheet(image: image, state: st, onUse: { _ in }, onCancel: {}))
    let win = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 760, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
    win.contentView = host
    win.orderFrontRegardless()
    pump(0.6)

    check("visible area laid out", st.viewport.width > 600 && st.viewport.height > 400, "\(st.viewport)")
    func findInput(_ v: NSView) -> RegionPickerInputView? {
        if let i = v as? RegionPickerInputView { return i }
        for s in v.subviews { if let f = findInput(s) { return f } }
        return nil
    }
    guard let input = findInput(host) else { print("FAIL input view not found"); return }
    let r = input.convert(input.bounds, to: nil)
    let vf = CGRect(x: r.minX, y: win.contentView!.bounds.height - r.maxY, width: r.width, height: r.height)
    check("native input view covers the visible area", abs(vf.width - st.viewport.width) < 1 && abs(vf.height - st.viewport.height) < 1, "\(vf)")

    // Window coordinates (bottom-left origin) of a point inside the visible area.
    let contentH = win.contentView!.bounds.height
    func winPoint(_ v: CGPoint) -> NSPoint { NSPoint(x: vf.minX + v.x, y: contentH - (vf.minY + v.y)) }
    var t = ProcessInfo.processInfo.systemUptime
    func mouse(_ type: NSEvent.EventType, _ v: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
        t += 0.02
        let e = NSEvent.mouseEvent(with: type, location: winPoint(v), modifierFlags: flags, timestamp: t,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        win.sendEvent(e)
        pump(0.02)
    }
    func drag(from a: CGPoint, to b: CGPoint, _ flags: NSEvent.ModifierFlags = []) {
        mouse(.leftMouseDown, a, flags)
        for i in 1...6 {
            let f = CGFloat(i) / 6
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), flags)
        }
        mouse(.leftMouseUp, b, flags)
        pump(0.1)
    }

    st.applyPreset(4); pump()
    check("400% is scrollable sideways", st.maxOffset.x > 500, "max \(st.maxOffset)")
    let start = st.offset

    // ⌥-drag pans; a second ⌥-drag continues from there (the reported reset-to-0,0 bug).
    drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 250, y: 300), .option)
    check("⌥-drag pans sideways", abs(st.offset.x - (start.x + 150)) < 3 && abs(st.offset.y - start.y) < 3, "\(start) → \(st.offset)")
    let mid = st.offset
    drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 300, y: 260), .option)
    check("second pan continues (no reset)", abs(st.offset.x - (mid.x + 100)) < 3 && abs(st.offset.y - (mid.y + 40)) < 3, "\(mid) → \(st.offset)")
    check("no selection was drawn while panning", st.rect == nil)

    // Pan off, no modifier: drag draws a box and doesn't scroll.
    let beforeBox = st.offset
    drag(from: CGPoint(x: 200, y: 150), to: CGPoint(x: 360, y: 230))
    check("plain drag draws a box", st.rect != nil, st.rect.map { "\($0)" } ?? "nil")
    if let r = st.rect {
        let vr = st.viewRect(r), half = st.effectiveZoom / 2
        check("box appears exactly under the mouse (within half a point)",
              abs(vr.minX - 200) <= half && abs(vr.minY - 150) <= half && abs(vr.maxX - 360) <= half && abs(vr.maxY - 230) <= half,
              "on screen \(vr), dragged (200,150)→(360,230)")
    }
    check("plain drag doesn't scroll", st.offset == beforeBox)

    // Pan switch on: plain drag pans. Switch off again: plain drag selects again.
    st.panTool = true; pump()
    let p0 = st.offset
    drag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 220, y: 300))
    check("with Pan on, plain drag pans", abs(st.offset.x - (p0.x + 80)) < 3, "\(p0) → \(st.offset)")
    st.panTool = false; pump()
    let p1 = st.offset
    let oldRect = st.rect
    drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 160, y: 140))
    check("Pan switched off really stops panning", st.offset == p1, "\(p1) → \(st.offset)")
    check("…and drag selects again", st.rect != oldRect)
    let lastRect = st.rect

    // Scroll wheel: a real wheel event (3 lines sideways, as Shift + mouse wheel produces).
    let s0 = st.offset
    let screenPt = win.convertPoint(toScreen: winPoint(CGPoint(x: 300, y: 300)))
    let w2 = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -3, wheel3: 0)!
    w2.location = CGPoint(x: screenPt.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screenPt.y)
    w2.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.windowNumber))
    let we = NSEvent(cgEvent: w2)!
    if we.window != nil { win.sendEvent(we) } else { input.scrollWheel(with: we) }
    pump()
    check("sideways wheel scroll moves right", st.offset.x > s0.x + 10 && abs(st.offset.y - s0.y) < 0.5, "\(s0) → \(st.offset) (event window: \(we.window != nil))")

    // Scroll bar: drag the horizontal thumb.
    let h0 = st.offset.x
    let thumb = st.horizontalBar!.thumb
    // What point does the view actually receive for the thumb's center?
    let probe = NSEvent.mouseEvent(with: .leftMouseDown, location: winPoint(CGPoint(x: thumb.midX, y: thumb.midY)), modifierFlags: [], timestamp: 0,
                                   windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    let got = input.convert(probe.locationInWindow, from: nil)
    check("mouse position inside the view is exact", abs(got.x - thumb.midX) < 0.5 && abs(got.y - thumb.midY) < 0.5, "aimed \(thumb.midX),\(thumb.midY) got \(got)")
    drag(from: CGPoint(x: thumb.midX, y: thumb.midY), to: CGPoint(x: thumb.midX + 60, y: thumb.midY))
    let expected = 60 * st.horizontalBar!.ratio
    check("dragging the horizontal scroll bar scrolls", abs(st.offset.x - (h0 + expected)) < 3, "\(h0) → \(st.offset.x), expected +\(Int(expected))")
    check("…and didn't draw a box", st.rect == nil || st.rect == lastRect)
    let v0 = st.offset.y
    let vthumb = st.verticalBar!.thumb
    drag(from: CGPoint(x: vthumb.midX, y: vthumb.midY), to: CGPoint(x: vthumb.midX, y: vthumb.midY + 40))
    check("dragging the vertical scroll bar scrolls", st.offset.y > v0 + 20, "\(v0) → \(st.offset.y)")

    // Picture of the result.
    st.rect = CGRect(x: 160, y: 330, width: 60, height: 30)
    st.zoomToSelection(); pump(0.3)
    if let bmp = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bmp)
        try? bmp.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
