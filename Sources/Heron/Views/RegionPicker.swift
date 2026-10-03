import SwiftUI

/// Everything about the screenshot cropper that isn't drawing: zoom, scroll position, selection and what a
/// drag does. Kept separate from the view so it can be tested directly.
///
/// Coordinates: "image" = window points (the screenshot's size); "view" = points inside the visible area.
final class RegionPickerState: ObservableObject {
    enum Handle: CaseIterable { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

    enum Drag {
        case thumb(horizontal: Bool, startOffset: CGPoint, ratio: CGFloat)
        case pan(startOffset: CGPoint)
        case new(anchor: CGPoint)
        case move(grab: CGPoint, original: CGRect)
        case resize(Handle, original: CGRect)
    }

    let imageSize: CGSize
    @Published var rect: CGRect?
    /// Screen points per image point. nil = fit the whole screenshot.
    @Published private(set) var zoom: CGFloat?
    /// Top-left of the visible part of the zoomed screenshot, in view points.
    @Published private(set) var offset: CGPoint = .zero
    /// When on, dragging scrolls instead of selecting.
    @Published var panTool = false
    @Published private(set) var viewport: CGSize = .zero
    private(set) var drag: Drag?

    static let minZoom: CGFloat = 0.1, maxZoom: CGFloat = 16

    init(imageSize: CGSize) { self.imageSize = imageSize }

    // MARK: Geometry

    var fitZoom: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / imageSize.width, viewport.height / imageSize.height)
    }

    var effectiveZoom: CGFloat { zoom ?? fitZoom }

    var contentSize: CGSize { CGSize(width: imageSize.width * effectiveZoom, height: imageSize.height * effectiveZoom) }

    /// Where the screenshot's top-left sits in the view (centered when it's smaller than the view).
    var contentOrigin: CGPoint {
        let c = contentSize
        return CGPoint(x: c.width <= viewport.width ? (viewport.width - c.width) / 2 : -offset.x,
                       y: c.height <= viewport.height ? (viewport.height - c.height) / 2 : -offset.y)
    }

    var maxOffset: CGPoint {
        let c = contentSize
        return CGPoint(x: max(0, c.width - viewport.width), y: max(0, c.height - viewport.height))
    }

    func toImage(_ v: CGPoint) -> CGPoint {
        let o = contentOrigin, z = effectiveZoom
        return CGPoint(x: (v.x - o.x) / z, y: (v.y - o.y) / z)
    }

    func toView(_ p: CGPoint) -> CGPoint {
        let o = contentOrigin, z = effectiveZoom
        return CGPoint(x: p.x * z + o.x, y: p.y * z + o.y)
    }

    func viewRect(_ r: CGRect) -> CGRect {
        let a = toView(r.origin), z = effectiveZoom
        return CGRect(x: a.x, y: a.y, width: r.width * z, height: r.height * z)
    }

    // MARK: Scrolling & zooming

    func setViewport(_ size: CGSize) {
        guard size != viewport else { return }
        viewport = size
        setOffset(offset)
    }

    func setOffset(_ p: CGPoint) {
        let m = maxOffset
        offset = CGPoint(x: min(max(0, p.x), m.x), y: min(max(0, p.y), m.y))
    }

    func scroll(by d: CGSize) {
        setOffset(CGPoint(x: offset.x + d.width, y: offset.y + d.height))
    }

    /// Changes zoom while keeping the image point under `focus` (view coordinates) where it is.
    func setZoom(_ z: CGFloat?, focus: CGPoint? = nil) {
        let f = focus ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let pinned = toImage(f)
        zoom = z.map { min(max($0, Self.minZoom), Self.maxZoom) }
        let nz = effectiveZoom
        setOffset(CGPoint(x: pinned.x * nz - f.x, y: pinned.y * nz - f.y))
    }

    /// Centers an image point in the view (as far as the edges allow).
    func center(on p: CGPoint) {
        let z = effectiveZoom
        setOffset(CGPoint(x: p.x * z - viewport.width / 2, y: p.y * z - viewport.height / 2))
    }

    /// Zoom presets keep the selection in the middle if there is one.
    func applyPreset(_ z: CGFloat?) {
        setZoom(z)
        if let r = rect { center(on: CGPoint(x: r.midX, y: r.midY)) }
    }

    func zoomToSelection() {
        guard let r = rect, r.width > 0, r.height > 0, viewport.width > 0 else { return }
        zoom = min(max(min(viewport.width * 0.6 / r.width, viewport.height * 0.6 / r.height), Self.minZoom), Self.maxZoom)
        center(on: CGPoint(x: r.midX, y: r.midY))
    }

    /// Trackpad pinch: `delta` is the change in magnification for this event.
    func pinch(delta: CGFloat, focus: CGPoint) {
        setZoom(effectiveZoom * max(0.2, 1 + delta), focus: focus)
    }

    /// Scroll wheel / trackpad scroll at view point `p`. ⌘ zooms around the pointer instead.
    /// Mouse wheels report lines (not precise); Shift + wheel already arrives as a sideways delta.
    func wheel(dx: CGFloat, dy: CGFloat, precise: Bool, command: Bool, at p: CGPoint) {
        if command {
            setZoom(effectiveZoom * max(0.2, 1 + dy * (precise ? 0.01 : 0.1)), focus: p)
        } else {
            let k: CGFloat = precise ? 1 : 12
            scroll(by: CGSize(width: -dx * k, height: -dy * k))
        }
    }

    // MARK: Scroll bars (drawn and hit-tested from the same numbers)

    static let barThickness: CGFloat = 10

    struct Bar {
        let track: CGRect
        let thumb: CGRect
        /// Content points scrolled per point of thumb movement.
        let ratio: CGFloat
    }

    var horizontalBar: Bar? {
        let c = contentSize, t = Self.barThickness
        guard c.width > viewport.width + 0.5 else { return nil }
        let track = CGRect(x: 1, y: viewport.height - t + 1, width: viewport.width - t - 2, height: t - 2)
        let len = max(30, track.width * viewport.width / c.width)
        let travel = max(1, track.width - len)
        let x = track.minX + travel * offset.x / max(1, maxOffset.x)
        return Bar(track: track, thumb: CGRect(x: x, y: track.minY, width: len, height: track.height), ratio: maxOffset.x / travel)
    }

    var verticalBar: Bar? {
        let c = contentSize, t = Self.barThickness
        guard c.height > viewport.height + 0.5 else { return nil }
        let track = CGRect(x: viewport.width - t + 1, y: 1, width: t - 2, height: viewport.height - t - 2)
        let len = max(30, track.height * viewport.height / c.height)
        let travel = max(1, track.height - len)
        let y = track.minY + travel * offset.y / max(1, maxOffset.y)
        return Bar(track: track, thumb: CGRect(x: track.minX, y: y, width: track.width, height: len), ratio: maxOffset.y / travel)
    }

    // MARK: Dragging (new box / move / resize / pan)

    /// `pan`: Space or ⌥ was held when the drag started. The Pan switch also makes every drag pan.
    func dragBegan(at v: CGPoint, pan: Bool) {
        // Scroll bars first: grab the thumb, or click the track to jump there and keep dragging.
        for (horizontal, bar) in [(true, horizontalBar), (false, verticalBar)] {
            guard let bar, bar.track.insetBy(dx: -3, dy: -3).contains(v) else { continue }
            if !bar.thumb.insetBy(dx: -3, dy: -3).contains(v) {
                let jump = horizontal ? (v.x - bar.thumb.midX) * bar.ratio : (v.y - bar.thumb.midY) * bar.ratio
                setOffset(horizontal ? CGPoint(x: offset.x + jump, y: offset.y) : CGPoint(x: offset.x, y: offset.y + jump))
            }
            drag = .thumb(horizontal: horizontal, startOffset: offset, ratio: bar.ratio)
            return
        }
        if pan || panTool {
            drag = .pan(startOffset: offset)
            return
        }
        let here = toImage(v)
        if let r = rect {
            let vr = viewRect(r)
            if let h = Handle.allCases.first(where: {
                let c = Self.handlePoint($0, vr)
                return abs(c.x - v.x) <= 7 && abs(c.y - v.y) <= 7
            }) {
                drag = .resize(h, original: r)
            } else if vr.contains(v) {
                drag = .move(grab: here, original: r)
            } else {
                drag = .new(anchor: here)
            }
        } else {
            drag = .new(anchor: here)
        }
    }

    /// `translation` is in view points since the drag began.
    func dragChanged(to v: CGPoint, translation: CGSize) {
        let here = toImage(v)
        switch drag {
        case .thumb(let horizontal, let start, let ratio):
            setOffset(horizontal ? CGPoint(x: start.x + translation.width * ratio, y: start.y)
                                 : CGPoint(x: start.x, y: start.y + translation.height * ratio))
        case .pan(let start):
            setOffset(CGPoint(x: start.x - translation.width, y: start.y - translation.height))
        case .new(let a):
            rect = Self.clean(CGRect(x: min(a.x, here.x), y: min(a.y, here.y), width: abs(here.x - a.x), height: abs(here.y - a.y)),
                              in: imageSize)
        case .move(let grab, let o):
            var r = o
            r.origin.x = min(max(0, o.minX + here.x - grab.x), imageSize.width - o.width)
            r.origin.y = min(max(0, o.minY + here.y - grab.y), imageSize.height - o.height)
            rect = Self.clean(r, in: imageSize)
        case .resize(let h, let o):
            var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
            switch h {
            case .topLeft: x0 = here.x; y0 = here.y
            case .top: y0 = here.y
            case .topRight: x1 = here.x; y0 = here.y
            case .right: x1 = here.x
            case .bottomRight: x1 = here.x; y1 = here.y
            case .bottom: y1 = here.y
            case .bottomLeft: x0 = here.x; y1 = here.y
            case .left: x0 = here.x
            }
            rect = Self.clean(CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)), in: imageSize)
        case nil:
            break
        }
    }

    func dragEnded() { drag = nil }

    var isPanning: Bool { if case .pan = drag { true } else { false } }

    // MARK: Selection helpers

    static func handlePoint(_ h: Handle, _ r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }

    /// Integer points, inside the screenshot, at least 1×1.
    static func clean(_ r: CGRect, in size: CGSize) -> CGRect {
        let x0 = max(0, min(size.width, r.minX.rounded())), y0 = max(0, min(size.height, r.minY.rounded()))
        let x1 = max(0, min(size.width, r.maxX.rounded())), y1 = max(0, min(size.height, r.maxY.rounded()))
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: max(1, abs(x1 - x0)), height: max(1, abs(y1 - y0)))
    }

    func nudge(dx: CGFloat, dy: CGFloat, resize: Bool) {
        guard var r = rect else { return }
        if resize {
            r.size.width = max(1, r.width + dx)
            r.size.height = max(1, r.height + dy)
        } else {
            r.origin.x = min(max(0, r.minX + dx), imageSize.width - r.width)
            r.origin.y = min(max(0, r.minY + dy), imageSize.height - r.height)
        }
        rect = Self.clean(r, in: imageSize)
    }
}

/// Native mouse handling for the visible area: drags (box / move / resize / pan / scroll bars), scroll wheel and
/// pinch. Using an AppKit view means each event carries its own modifier keys, and nothing can get stuck.
final class RegionPickerInputView: NSView {
    weak var st: RegionPickerState?
    private var start: CGPoint?
    private var pushedCursor = false

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with e: NSEvent) {
        guard let st else { return }
        let p = point(e)
        start = p
        // Pan while ⌥ or Space is held (or the Pan switch is on). Read from this event / live key state.
        let space = CGEventSource.keyState(.combinedSessionState, key: 49)
        st.dragBegan(at: p, pan: e.modifierFlags.contains(.option) || space)
        if st.isPanning { NSCursor.closedHand.push(); pushedCursor = true }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let st, let s = start else { return }
        let p = point(e)
        st.dragChanged(to: p, translation: CGSize(width: p.x - s.x, height: p.y - s.y))
    }

    override func mouseUp(with e: NSEvent) {
        if pushedCursor { NSCursor.pop(); pushedCursor = false }
        st?.dragEnded()
        start = nil
    }

    override func scrollWheel(with e: NSEvent) {
        guard let st else { return super.scrollWheel(with: e) }
        st.wheel(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas,
                 command: e.modifierFlags.contains(.command), at: point(e))
    }

    override func magnify(with e: NSEvent) {
        st?.pinch(delta: e.magnification, focus: point(e))
    }

    override func resetCursorRects() {
        if st?.panTool == true { addCursorRect(bounds, cursor: .openHand) }
    }
}

private struct RegionPickerInput: NSViewRepresentable {
    let st: RegionPickerState
    let panTool: Bool

    func makeNSView(context: Context) -> RegionPickerInputView {
        let v = RegionPickerInputView()
        v.st = st
        return v
    }

    func updateNSView(_ v: RegionPickerInputView, context: Context) {
        v.st = st
        v.window?.invalidateCursorRects(for: v)
    }
}

/// Keeps Space (used for panning) from also pressing whichever button has focus.
final class SpaceKeySwallower: ObservableObject {
    private var monitor: Any?
    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 49, !(e.window?.firstResponder is NSTextView) else { return e }
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    deinit { stop() }
}

/// Shows a screenshot of the window; drag a box around the button to use as the picture. Supports zooming,
/// scrolling and panning, handles to adjust the box, arrow-key nudging and exact numbers.
struct RegionPickerSheet: View {
    let image: NSImage
    let onUse: (CGRect) -> Void
    let onCancel: () -> Void
    @StateObject private var st: RegionPickerState
    @StateObject private var spaceKey = SpaceKeySwallower()

    init(image: NSImage, state: RegionPickerState? = nil, onUse: @escaping (CGRect) -> Void, onCancel: @escaping () -> Void) {
        self.image = image
        self.onUse = onUse
        self.onCancel = onCancel
        _st = StateObject(wrappedValue: state ?? RegionPickerState(imageSize: image.size))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Drag a box around the button").font(.headline)
                Text("Include the whole button with as little background as possible. Scroll, or hold Space (or ⌥) and drag, to move around; ⌘-scroll or pinch to zoom. Fine-tune with the handles or arrow keys (⇧ for 10, ⌥ to resize).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            zoomBar
            viewportView
            footer
        }
        .padding(18)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 700, idealHeight: 820)
        .onAppear { spaceKey.start() }
        .onDisappear { spaceKey.stop() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            guard st.rect != nil else { return .ignored }
            let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
            var dx: CGFloat = 0, dy: CGFloat = 0
            switch press.key {
            case .leftArrow: dx = -step
            case .rightArrow: dx = step
            case .upArrow: dy = -step
            default: dy = step
            }
            st.nudge(dx: dx, dy: dy, resize: press.modifiers.contains(.option))
            return .handled
        }
    }

    // MARK: Zoom bar

    private var zoomBar: some View {
        let z = st.effectiveZoom
        return HStack(spacing: 8) {
            Button { st.setZoom(z / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
            Slider(value: Binding(get: { log2(st.effectiveZoom) }, set: { st.setZoom(pow(2, $0)) }),
                   in: log2(RegionPickerState.minZoom)...log2(RegionPickerState.maxZoom))
                .frame(width: 150)
            Button { st.setZoom(z * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
            Text("\(Int((z * 100).rounded()))%")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
            Divider().frame(height: 16)
            Button("Fit") { st.applyPreset(nil) }
                .keyboardShortcut("0", modifiers: .command)
                .help("Show the whole screenshot (⌘0)")
            ForEach([1, 2, 4, 8], id: \.self) { f in
                Button("\(f * 100)%") { st.applyPreset(CGFloat(f)) }
            }
            Divider().frame(height: 16)
            Button("Zoom to Selection") { st.zoomToSelection() }
                .disabled(st.rect == nil)
            Toggle(isOn: $st.panTool) { Label("Pan", systemImage: "hand.raised") }
                .toggleStyle(.button)
                .help("While on, dragging moves around the screenshot instead of drawing a box")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
    }

    // MARK: Visible area

    private var viewportView: some View {
        GeometryReader { geo in
            let z = st.effectiveZoom
            let origin = st.contentOrigin
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.3))
                // Pinned to the visible area's size: the (much larger) zoomed screenshot must not resize the
                // stack, or everything in it gets re-centered and shifted.
                ScreenshotLayer(image: image, zoom: z, shown: st.contentSize)
                    .offset(x: origin.x, y: origin.y)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                if z >= 6 { PixelGridLayer(zoom: z, origin: origin, viewport: geo.size) }
                if let r = st.rect { SelectionLayer(rect: st.viewRect(r), viewport: geo.size) }
                ScrollBars(horizontal: st.horizontalBar, vertical: st.verticalBar, viewport: geo.size)
                RegionPickerInput(st: st, panTool: st.panTool)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { st.setViewport(geo.size) }
            .onChange(of: geo.size) { _, s in st.setViewport(s) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if st.rect != nil {
                field("X", \.origin.x)
                field("Y", \.origin.y)
                field("W", \.size.width)
                field("H", \.size.height)
                Text("points").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No selection yet").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Use Selection") { if let r = st.rect { onUse(r) } }
                .keyboardShortcut(.defaultAction)
                .disabled((st.rect?.width ?? 0) < 4 || (st.rect?.height ?? 0) < 4)
        }
    }

    private func field(_ label: String, _ kp: WritableKeyPath<CGRect, CGFloat>) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField("", value: Binding(
                get: { Double(st.rect?[keyPath: kp] ?? 0) },
                set: { v in
                    guard var r = st.rect else { return }
                    r[keyPath: kp] = CGFloat(v)
                    st.rect = RegionPickerState.clean(r, in: st.imageSize)
                }), format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
        }
    }
}

// MARK: - Layers

private struct ScreenshotLayer: View, Equatable {
    let image: NSImage
    let zoom: CGFloat
    let shown: CGSize

    static func == (a: Self, b: Self) -> Bool { a.image === b.image && a.zoom == b.zoom && a.shown == b.shown }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(zoom >= 2 ? .none : .high) // crisp pixels when zoomed in
            .frame(width: shown.width, height: shown.height)
            .allowsHitTesting(false)
    }
}

/// Faint pixel grid, drawn only for the visible area.
private struct PixelGridLayer: View {
    let zoom: CGFloat
    let origin: CGPoint
    let viewport: CGSize

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x = origin.x.truncatingRemainder(dividingBy: zoom)
            while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += zoom }
            var y = origin.y.truncatingRemainder(dividingBy: zoom)
            while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += zoom }
            ctx.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
        }
        .frame(width: viewport.width, height: viewport.height)
        .allowsHitTesting(false)
    }
}

/// Dimmed surroundings, yellow outline and resize handles.
private struct SelectionLayer: View {
    let rect: CGRect
    let viewport: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(origin: .zero, size: viewport))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

            Rectangle()
                .strokeBorder(Color.yellow, lineWidth: 1.5)
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .offset(x: rect.minX, y: rect.minY)

            ForEach(RegionPickerState.Handle.allCases, id: \.self) { h in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                    .frame(width: 9, height: 9)
                    .position(RegionPickerState.handlePoint(h, rect))
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Always-visible scroll bars (dragging them is handled by `RegionPickerInputView`).
private struct ScrollBars: View {
    let horizontal: RegionPickerState.Bar?
    let vertical: RegionPickerState.Bar?
    let viewport: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array([horizontal, vertical].compactMap { $0 }.enumerated()), id: \.offset) { _, bar in
                Capsule().fill(Color.white.opacity(0.12))
                    .frame(width: bar.track.width, height: bar.track.height)
                    .offset(x: bar.track.minX, y: bar.track.minY)
                Capsule().fill(Color.white.opacity(0.65))
                    .frame(width: bar.thumb.width, height: bar.thumb.height)
                    .offset(x: bar.thumb.minX, y: bar.thumb.minY)
            }
        }
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
