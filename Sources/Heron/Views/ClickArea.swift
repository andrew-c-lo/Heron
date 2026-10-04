import SwiftUI

/// The step's picture, where you drag a box to choose where clicks land (or click once for a precise spot).
struct ClickAreaEditor: View {
    let png: Data
    @Binding var area: CGRect?
    var maxWidth: CGFloat = 260
    var maxHeight: CGFloat = 130
    @StateObject private var drag = DragState()

    final class DragState: ObservableObject { @Published var start: CGPoint? ; @Published var current: CGPoint? }

    var body: some View {
        if let image = NSImage(data: png) {
            let size = Self.fit(image.size, maxWidth: maxWidth, maxHeight: maxHeight)
            VStack(alignment: .leading, spacing: 6) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .overlay(alignment: .topLeading) { overlay(size) }
                    // Mouse handling in AppKit: dependable with every kind of mouse and trackpad input.
                    .overlay(ClickAreaInput(onChange: { a, b in drag.start = a; drag.current = b },
                                            onEnd: { a, b in
                                                area = Self.area(from: a, to: b, in: size)
                                                drag.start = nil; drag.current = nil
                                            }))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .help("Drag a box where clicks should land, or click once for a precise spot")
                HStack(spacing: 8) {
                    Text(area == nil ? "Clicks land anywhere on the picture." : "Clicks land in the box.")
                        .font(.caption).foregroundStyle(.secondary)
                    if area != nil {
                        Button("Whole Picture") { area = nil }.controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func overlay(_ size: CGSize) -> some View {
        let shown: CGRect? = {
            if let s = drag.start, let c = drag.current { return Self.area(from: s, to: c, in: size) }
            return area
        }()
        ZStack(alignment: .topLeading) {
            if let a = shown {
                let r = CGRect(x: a.minX * size.width, y: a.minY * size.height, width: a.width * size.width, height: a.height * size.height)
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                crosshair.offset(x: r.midX - 7, y: r.midY - 7)
            } else {
                crosshair.offset(x: size.width / 2 - 7, y: size.height / 2 - 7)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var crosshair: some View {
        ZStack {
            Rectangle().fill(Color.accentColor).frame(width: 14, height: 2)
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 14)
        }
        .frame(width: 14, height: 14)
        .shadow(color: .black.opacity(0.5), radius: 1)
    }

    /// The box between two points as fractions of the picture; a click (tiny drag) gives a small box around it.
    static func area(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x / size.width, 0), 1), y: min(max(p.y / size.height, 0), 1))
        }
        let p = clamp(a), q = clamp(b)
        var r = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
        if r.width < 0.04 && r.height < 0.04 { // a click: a precise spot
            let w = 0.06
            r = CGRect(x: min(max(q.x - w / 2, 0), 1 - w), y: min(max(q.y - w / 2, 0), 1 - w), width: w, height: w)
        }
        return r
    }

    static func fit(_ s: CGSize, maxWidth: CGFloat, maxHeight: CGFloat) -> CGSize {
        guard s.width > 0, s.height > 0 else { return CGSize(width: maxWidth, height: maxHeight) }
        let k = min(maxWidth / s.width, maxHeight / s.height)
        return CGSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }
}

/// Press, drag and release on the picture, in its own top-left coordinates.
struct ClickAreaInput: NSViewRepresentable {
    let onChange: (CGPoint, CGPoint) -> Void
    let onEnd: (CGPoint, CGPoint) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    final class InputView: NSView {
        var onChange: (CGPoint, CGPoint) -> Void = { _, _ in }
        var onEnd: (CGPoint, CGPoint) -> Void = { _, _ in }
        private var start: CGPoint?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private func point(_ e: NSEvent) -> CGPoint {
            let p = convert(e.locationInWindow, from: nil)
            return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
        }

        override func mouseDown(with e: NSEvent) {
            let p = point(e)
            start = p
            onChange(p, p)
        }

        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            onChange(s, point(e))
        }

        override func mouseUp(with e: NSEvent) {
            guard let s = start else { return }
            onEnd(s, point(e))
            start = nil
        }
    }
}
