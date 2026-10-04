import SwiftUI

/// The simplest view of a macro: where things happen (map) and when (timeline).
struct VisualMacroView: View {
    @EnvironmentObject var model: AppModel
    let editing: ActionEditing
    @ObservedObject var ui: DetailUIState
    let onShowRaw: (ActionGroup) -> Void
    let onAddColorCheck: (ActionGroup) -> Void
    let onSampleColor: (ActionGroup) -> Void
    let onEditPicture: (ActionGroup) -> Void

    var body: some View {
        let macro = editing.macro.wrappedValue
        let groups = editing.groups
        let _ = model.snapshotVersion // reload when a snapshot changes
        let snapshot = model.snapshot(for: macro.id)
        let playing = playingIndex(groups)
        let selected = groups.indices.filter { editing.isSelected(groups[$0]) }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editing.summary(groups)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                if macro.target.app != nil {
                    Button(snapshot == nil ? "Capture Screenshot" : "Update Screenshot") { model.updateSnapshot(for: macro) }
                        .controlSize(.small)
                        .help("Takes a picture of the target window to show behind the markers. Needs Screen Recording permission.")
                }
            }

            ActionMap(groups: groups, space: Self.space(groups, snapshot: snapshot, target: macro.target.app),
                      snapshot: snapshot, editing: editing, ui: ui, playing: playing,
                      onShowRaw: onShowRaw, onAddColorCheck: onAddColorCheck, onEditPicture: onEditPicture)
                .frame(minHeight: 140, maxHeight: .infinity)

            ActionTimeline(groups: groups, total: macro.duration, editing: editing, playing: playing)
                .frame(height: 50)

            inspector(groups, selected: selected)
        }
    }

    @ViewBuilder
    private func inspector(_ groups: [ActionGroup], selected: [Int]) -> some View {
        Group {
            if selected.count == 1, let i = selected.first {
                // Its settings are in the details panel beside the map.
                Text("\(i + 1). \(groups[i].title(touch: editing.isTouch))")
                    .lineLimit(1)
            } else if selected.count > 1 {
                Text("\(selected.count) actions selected. Delete removes them all.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Click a marker or the timeline to edit an action. Drag markers to move them. Right-click for more.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
    }

    /// Which action is being played right now (nil when not playing this macro).
    private func playingIndex(_ groups: [ActionGroup]) -> Int? {
        let macro = editing.macro.wrappedValue
        guard model.playingMacroID == macro.id, model.playPausing == nil, model.playStep > 0 else { return nil }
        var raw = model.playStep - 1
        if macro.playback.skipMouseMoves {
            // The player counts steps with mouse moves removed; map back to the full list.
            var seen = -1
            raw = macro.steps.count - 1
            for (k, s) in macro.steps.enumerated() where !s.action.isMouseMove {
                seen += 1
                if seen == model.playStep - 1 { raw = k; break }
            }
        }
        return groups.firstIndex { $0.range.contains(raw) }
    }

    /// The area of the map, in the macro's coordinates.
    static func space(_ groups: [ActionGroup], snapshot: NSImage?, target: TargetApp?) -> CGRect {
        let pts = groups.flatMap(\.points)
        var base: CGRect?
        if let snapshot { base = CGRect(origin: .zero, size: snapshot.size) }
        else if let target, let w = WindowFinder.find(target) { base = CGRect(origin: .zero, size: w.frame.size) }
        if let base {
            return pts.reduce(base) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }
        }
        guard let first = pts.first else { return CGRect(x: 0, y: 0, width: 400, height: 300) }
        let bb = pts.reduce(CGRect(origin: first, size: CGSize(width: 1, height: 1))) {
            $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1)))
        }
        return bb.insetBy(dx: -max(60, bb.width * 0.15), dy: -max(60, bb.height * 0.15))
    }
}

extension ActionGroup {
    /// Every on-screen position involved (used for map bounds).
    var points: [CGPoint] {
        switch kind {
        case .click(_, _, let at?, _), .scroll(_, _, let at?), .colorWait(let at, _), .move(let at): [at]
        case .image(let s) where s.spotOnly && s.spot != nil: [s.spot!]
        case .image(let s) where !s.usesPicture:
            if let x = s.fallbackX, let y = s.fallbackY { [CGPoint(x: x, y: y)] }
            else { s.area.map { [CGPoint(x: $0.midX, y: $0.midY)] } ?? [] }
        case .image(let s): [CGPoint(x: s.originX + s.width / 2, y: s.originY + s.height / 2)]
        case .drag(_, let a, let b): [a, b]
        default: []
        }
    }

    /// Where the action's marker goes.
    var anchor: CGPoint? {
        switch kind {
        case .drag(_, let from, _): from
        default: points.first
        }
    }

    var tint: Color {
        switch kind {
        case .click(let b, let count, _, let hold):
            if b == .left && count == 1 && hold >= 0.5 { return .indigo }
            return b == .left ? .blue : .orange
        case .drag: return .purple
        case .scroll: return .teal
        case .keys, .typeList: return .green
        case .wait: return .gray
        case .colorWait(_, let c): return Color(nsColor: RGB(hex: c.hex)?.nsColor ?? .gray)
        case .image: return .pink
        case .move: return .secondary
        case .other, .repeatFrom: return .brown
        }
    }
}

// MARK: - Map

struct ActionMap: View {
    let groups: [ActionGroup]
    let space: CGRect
    let snapshot: NSImage?
    let editing: ActionEditing
    @ObservedObject var ui: DetailUIState
    let playing: Int?
    let onShowRaw: (ActionGroup) -> Void
    let onAddColorCheck: (ActionGroup) -> Void
    let onEditPicture: (ActionGroup) -> Void

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / max(space.width, 1), geo.size.height / max(space.height, 1))
            let drawn = CGSize(width: space.width * scale, height: space.height * scale)
            let origin = CGPoint(x: (geo.size.width - drawn.width) / 2, y: (geo.size.height - drawn.height) / 2)
            let toView: (CGPoint) -> CGPoint = { p in
                CGPoint(x: origin.x + (p.x - space.minX) * scale, y: origin.y + (p.y - space.minY) * scale)
            }
            let placed = placements(toView)

            ZStack(alignment: .topLeading) {
                background(drawn: drawn, origin: origin)
                    .onTapGesture { ui.selection.removeAll() }

                // Order of events: a faint dashed line through the markers.
                Path { path in
                    for (n, item) in placed.enumerated() {
                        n == 0 ? path.move(to: item.point) : path.addLine(to: item.point)
                    }
                }
                .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                .shadow(color: .black.opacity(0.5), radius: 1)
                .allowsHitTesting(false)

                ForEach(placed, id: \.group.id) { item in
                    if case .drag(_, _, let to) = item.group.kind {
                        Arrow(from: item.point, to: offsetIfDragging(toView(to), item.group))
                            .stroke(item.group.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                            .shadow(color: .black.opacity(0.4), radius: 1.5)
                            .allowsHitTesting(false)
                    }
                }

                ForEach(placed, id: \.group.id) { item in
                    marker(item, scale: scale)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func background(drawn: CGSize, origin: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary.opacity(0.4))
            Group {
                if let snapshot {
                    Image(nsImage: snapshot).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay(alignment: .top) {
                            Text(editing.macro.wrappedValue.target.app == nil
                                 ? "Screen area" : "Window (no screenshot yet)")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 8)
                        }
                }
            }
            .frame(width: drawn.width, height: drawn.height)
            .offset(x: origin.x, y: origin.y)
        }
    }

    private struct Placement {
        let group: ActionGroup
        let number: Int
        let point: CGPoint
    }

    /// Marker positions in view space. Repeats on the same spot fan out slightly so each stays clickable.
    private func placements(_ toView: (CGPoint) -> CGPoint) -> [Placement] {
        var seen: [String: Int] = [:]
        var out: [Placement] = []
        for (i, g) in groups.enumerated() {
            guard let a = g.anchor else { continue }
            var p = toView(a)
            let key = "\(Int(p.x / 8)),\(Int(p.y / 8))"
            let n = seen[key, default: 0]
            seen[key] = n + 1
            p.x += CGFloat(n) * 9
            p.y -= CGFloat(n) * 9
            out.append(Placement(group: g, number: i + 1, point: offsetIfDragging(p, g)))
        }
        return out
    }

    private func offsetIfDragging(_ p: CGPoint, _ g: ActionGroup) -> CGPoint {
        guard ui.dragging == g.id else { return p }
        return CGPoint(x: p.x + ui.dragOffset.width, y: p.y + ui.dragOffset.height)
    }

    private func marker(_ item: Placement, scale: CGFloat) -> some View {
        let g = item.group
        let selected = editing.isSelected(g)
        return MapMarker(number: item.number, tint: g.tint, icon: markerIcon(g), rings: ringCount(g),
                         selected: selected, playing: playing == item.number - 1,
                         isColorCheck: { if case .colorWait = g.kind { return true } else { return false } }())
            .opacity(g.enabled ? 1 : 0.35)
            .position(item.point)
            .help("\(item.number). \(g.title(touch: editing.isTouch)) · at \(ActionRow.timestamp(g.start))")
            .onTapGesture { editing.select(g) }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { v in
                        ui.dragging = g.id
                        ui.dragOffset = v.translation
                    }
                    .onEnded { v in
                        editing.translate(g, by: CGSize(width: v.translation.width / scale, height: v.translation.height / scale))
                        ui.dragging = nil
                        ui.dragOffset = .zero
                        editing.select(g)
                    }
            )
            .contextMenu {
                ActionMenu(group: g, editing: editing, onShowRaw: onShowRaw, onAddColorCheck: onAddColorCheck,
                           onEditPicture: onEditPicture)
            }
    }

    private func ringCount(_ g: ActionGroup) -> Int {
        if case .click(_, let count, _, _) = g.kind { return count }
        return 1
    }

    private func markerIcon(_ g: ActionGroup) -> String? {
        switch g.kind {
        case .scroll: "scroll"
        case .colorWait: "eyedropper"
        case .image(let s): s.spotOnly && s.mode == .click ? "cursorarrow.click" : s.isText && s.mode == .click ? "text.viewfinder" : s.mode.icon
        default: nil
        }
    }
}

struct MapMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let number: Int
    let tint: Color
    let icon: String?
    let rings: Int
    let selected: Bool
    let playing: Bool
    var isColorCheck = false

    var body: some View {
        ZStack {
            // Extra rings for double/triple taps.
            ForEach(1..<max(1, rings), id: \.self) { r in
                Circle()
                    .stroke(tint, lineWidth: 2)
                    .frame(width: 26 + CGFloat(r) * 9, height: 26 + CGFloat(r) * 9)
            }
            Circle()
                .fill(isColorCheck ? Color.black.opacity(0.75) : tint)
                .overlay(Circle().strokeBorder(isColorCheck ? tint : .white, lineWidth: isColorCheck ? 4 : 1.5))
                .frame(width: 26, height: 26)
            if let icon, isColorCheck {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            } else {
                Text("\(number)")
                    .font(.system(size: number > 99 ? 9 : 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .overlay {
            if selected {
                Circle().stroke(Color.yellow, lineWidth: 3).frame(width: 35, height: 35)
            }
        }
        .scaleEffect(playing ? 1.4 : selected ? 1.15 : 1)
        .shadow(color: .black.opacity(0.45), radius: playing ? 6 : 2)
        .animation(reduceMotion ? nil : Motion.snap, value: playing)
        .animation(reduceMotion ? nil : Motion.snap, value: selected)
        .contentShape(Circle())
    }
}

/// Line with an arrowhead, for swipes/drags.
struct Arrow: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in _: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let head: CGFloat = 12
        for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x + head * cos(angle + side), y: to.y + head * sin(angle + side)))
        }
        return p
    }
}

// MARK: - Timeline

struct ActionTimeline: View {
    let groups: [ActionGroup]
    let total: Double
    let editing: ActionEditing
    let playing: Int?

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 10
            let w = max(1, geo.size.width - inset * 2)
            let x: (Double) -> CGFloat = { t in inset + CGFloat(total > 0 ? t / total : 0) * w }

            ZStack(alignment: .topLeading) {
                Capsule().fill(.quaternary)
                    .frame(width: w, height: 4)
                    .offset(x: inset, y: 16)

                // Pauses show as a span, so long waits are visible.
                ForEach(groups.filter { if case .wait = $0.kind { true } else { false } }) { g in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.35))
                        .frame(width: max(2, x(g.start) - x(g.start - g.wait)), height: 12)
                        .offset(x: x(g.start - g.wait), y: 12)
                }

                ForEach(Array(groups.enumerated()), id: \.element.id) { i, g in
                    let selected = editing.isSelected(g)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(g.tint)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(selected ? Color.yellow : .white.opacity(0.6),
                                                                                lineWidth: selected ? 2 : 1))
                        .frame(width: 9, height: selected || playing == i ? 30 : 22)
                        .position(x: x(g.start), y: 18)
                        .onTapGesture { editing.select(g) }
                        .help("\(i + 1). \(g.title(touch: editing.isTouch)) · at \(ActionRow.timestamp(g.start))")
                }

                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { f in
                    Text(ActionRow.timestamp(total * f))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(x(total * f), inset + 16), geo.size.width - inset - 16), y: 42)
                }
            }
        }
    }
}
