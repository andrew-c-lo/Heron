import SwiftUI
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
    if !ok { failures += 1 }
}
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.6 }
MainActor.assumeIsolated {
    let st = RegionPickerState(imageSize: CGSize(width: 513, height: 1126))
    st.setViewport(CGSize(width: 720, height: 560))
    check("starts fitted, nothing scrolled", st.offset == .zero && st.maxOffset == .zero)

    st.applyPreset(4)
    check("400% makes it scrollable both ways", st.maxOffset.x > 1000 && st.maxOffset.y > 3000, "max \(st.maxOffset)")

    // Pan twice: the second pan must continue from where the first ended (the reported bug).
    let before = st.offset
    st.dragBegan(at: CGPoint(x: 400, y: 300), pan: true)
    st.dragChanged(to: CGPoint(x: 300, y: 300), translation: CGSize(width: -100, height: 0))
    st.dragEnded()
    st.dragBegan(at: CGPoint(x: 400, y: 300), pan: true)
    st.dragChanged(to: CGPoint(x: 300, y: 250), translation: CGSize(width: -100, height: -50))
    st.dragEnded()
    check("pans accumulate (no reset to 0,0)", near(st.offset.x, before.x + 200) && near(st.offset.y, before.y + 50),
          "from \(before) to \(st.offset)")

    // Pan tool off and no modifier: dragging must draw a box, not pan.
    st.panTool = false
    let o2 = st.offset
    st.rect = nil
    st.dragBegan(at: CGPoint(x: 100, y: 100), pan: false)
    st.dragChanged(to: CGPoint(x: 260, y: 180), translation: CGSize(width: 160, height: 80))
    st.dragEnded()
    check("with Pan off, drag selects and doesn't scroll", st.offset == o2 && st.rect != nil, "rect \(st.rect.map { "\($0)" } ?? "nil")")
    let r = st.rect!
    check("box is 40×20 points at 400% (160×80 on screen)", r.width == 40 && r.height == 20)
    let vr = st.viewRect(r)
    let half = st.effectiveZoom / 2 // snapping to whole screenshot points: within half a point
    check("box is drawn where it was dragged (within half a point)",
          abs(vr.minX - 100) <= half && abs(vr.minY - 100) <= half && abs(vr.maxX - 260) <= half && abs(vr.maxY - 180) <= half, "\(vr)")

    // Pan tool on: drags pan.
    st.panTool = true
    st.dragBegan(at: CGPoint(x: 50, y: 50), pan: false)
    check("with Pan on, drag pans", st.isPanning)
    st.dragEnded()
    st.panTool = false

    // Horizontal scrolling (wheel / shift-wheel / trackpad) and the edges.
    let o3 = st.offset
    st.scroll(by: CGSize(width: 240, height: 0))
    check("horizontal scroll moves sideways only", near(st.offset.x, o3.x + 240) && near(st.offset.y, o3.y))
    st.scroll(by: CGSize(width: 100_000, height: 100_000))
    check("can't scroll past the right/bottom edge", st.offset == st.maxOffset)
    st.scroll(by: CGSize(width: -100_000, height: -100_000))
    check("can't scroll past the left/top edge", st.offset == .zero)

    // Zooming keeps the point under the mouse still.
    st.applyPreset(2)
    st.setOffset(CGPoint(x: 150, y: 600))
    let focus = CGPoint(x: 333, y: 222)
    let pinned = st.toImage(focus)
    st.setZoom(5, focus: focus)
    let after = st.toView(pinned)
    check("zoom keeps the point under the pointer in place", near(after.x, focus.x) && near(after.y, focus.y), "\(after)")

    // Zoom to selection centers it.
    st.rect = CGRect(x: 120, y: 640, width: 110, height: 32)
    st.zoomToSelection()
    let sel = st.viewRect(st.rect!)
    check("zoom to selection centers the box", near(sel.midX, 360) && near(sel.midY, 280), "center (\(sel.midX), \(sel.midY))")

    // Fit returns to whole view; resizing the window never leaves it scrolled out of range.
    st.applyPreset(nil)
    check("Fit shows everything (no scrolling)", st.offset == .zero && st.maxOffset == .zero)
    st.applyPreset(8)
    st.scroll(by: CGSize(width: 100_000, height: 100_000))
    st.setViewport(CGSize(width: 1400, height: 1000))
    check("window resize keeps scroll in range", st.offset.x <= st.maxOffset.x && st.offset.y <= st.maxOffset.y)

    // Pinch (each trackpad event reports its own change).
    st.applyPreset(1)
    st.pinch(delta: 0.5, focus: CGPoint(x: 300, y: 300))
    st.pinch(delta: 1.0 / 3.0, focus: CGPoint(x: 300, y: 300))
    check("pinch ×1.5 then ×4/3 from 100% lands at 200%", near(st.effectiveZoom * 100, 200), "\(st.effectiveZoom)")

    // Scroll wheel: mouse wheel lines vs trackpad points, and ⌘ zooms.
    st.applyPreset(4)
    let w0 = st.offset
    st.wheel(dx: -3, dy: 0, precise: false, command: false, at: CGPoint(x: 300, y: 300))
    check("Shift + mouse wheel (3 lines) scrolls 36 points right", near(st.offset.x, w0.x + 36) && near(st.offset.y, w0.y))
    st.wheel(dx: 0, dy: -20, precise: true, command: false, at: CGPoint(x: 300, y: 300))
    check("trackpad scroll moves by its points", near(st.offset.y, w0.y + 20))
    let zBefore = st.effectiveZoom
    st.wheel(dx: 0, dy: 2, precise: false, command: true, at: CGPoint(x: 300, y: 300))
    check("⌘ + wheel zooms instead of scrolling", st.effectiveZoom > zBefore)

    // Scroll bars: present when scrollable, thumb tracks the position, grabbing a thumb scrolls.
    st.applyPreset(4)
    st.setOffset(.zero)
    let hb = st.horizontalBar!, vb = st.verticalBar!
    check("both scroll bars exist at 400%", hb.thumb.width > 0 && vb.thumb.height > 0)
    check("thumbs start at the left/top", near(hb.thumb.minX, hb.track.minX) && near(vb.thumb.minY, vb.track.minY))
    st.dragBegan(at: CGPoint(x: hb.thumb.midX, y: hb.thumb.midY), pan: false)
    st.dragChanged(to: CGPoint(x: hb.thumb.midX + 50, y: hb.thumb.midY), translation: CGSize(width: 50, height: 0))
    st.dragEnded()
    check("dragging the horizontal thumb scrolls proportionally", near(st.offset.x, 50 * hb.ratio), "\(st.offset.x) vs \(50 * hb.ratio)")
    st.setOffset(st.maxOffset)
    check("thumbs reach the right/bottom end", near(st.horizontalBar!.thumb.maxX, hb.track.maxX) && near(st.verticalBar!.thumb.maxY, vb.track.maxY))
    st.applyPreset(nil)
    check("no scroll bars when everything fits", st.horizontalBar == nil && st.verticalBar == nil)
}
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
