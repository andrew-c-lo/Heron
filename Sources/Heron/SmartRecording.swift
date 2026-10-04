import AppKit
import CoreGraphics
import Foundation

/// Smart recording: remembers *what* was clicked, not just where. While recording, the spot under each click is
/// looked at (on this Mac): a short word becomes “Click “word””, and an icon or button without words becomes a
/// picture to find. When recording stops, those clicks find their target wherever it is, falling back to the
/// recorded spot.
final class ClickReader: @unchecked Sendable {
    /// What was under one click.
    struct Label: Equatable {
        var text: String?
        /// A small picture of the spot (PNG) and its size in points (with words too, the step finds either).
        var picture: Data?
        var size: CGSize = .zero
        /// The window's size (points) when it was recorded.
        var window: CGSize = .zero
        /// Where to look: around the click (always for pictures; for words, when the word appears more than once).
        var area: CGRect?

        init(text: String, area: CGRect?) { self.text = text; self.area = area }
        init(picture: Data, size: CGSize, area: CGRect) { self.picture = picture; self.size = size; self.area = area }
    }

    /// One press, with the window it landed in.
    private struct Press { let app: TargetApp; let origin: CGPoint; var label: Label? }

    private let queue = DispatchQueue(label: "heron.click-reader", qos: .userInitiated)
    private let lock = NSLock()
    private var presses: [UUID: Press] = [:]
    /// Set when recording only inside one app (positions are already relative to its window).
    private let target: TargetApp?
    private let resolver: TargetResolver?

    init(target: TargetApp?) {
        self.target = target
        resolver = target.map { TargetResolver(app: $0) }
        // Start the window's live feed now, so the picture at the first click is already there.
        queue.async { [resolver] in
            if let win = resolver?.window() { _ = FrameSource.shared.frame(for: win, after: 0, timeout: 0.5) }
        }
    }

    /// `p` is in window points when recording inside one app, otherwise in screen points.
    func notePress(_ id: UUID, at p: CGPoint) {
        queue.async { [self] in
            let app: TargetApp, win: TargetWindow, local: CGPoint
            if let target, let w = resolver?.window() {
                (app, win, local) = (target, w, p)
            } else if let hit = WindowFinder.window(at: p) {
                (app, win) = hit
                local = CGPoint(x: p.x - hit.window.frame.minX, y: p.y - hit.window.frame.minY)
            } else { return }
            var press = Press(app: app, origin: win.frame.origin, label: nil)
            if let frame = FrameSource.shared.frame(for: win, after: 0, timeout: target == nil ? 0.3 : 0.05) {
                press.label = Self.both(in: frame.pixels, at: local)
                press.label?.window = CGSize(width: frame.pixels.width, height: frame.pixels.height)
            }
            lock.withLock { presses[id] = press }
        }
    }

    struct Result {
        var steps: [MacroStep]
        /// When recording the whole screen and every click went to one app's window: that app (positions in
        /// `steps` are now relative to its window).
        var app: TargetApp?
        var words = 0, pictures = 0
    }

    /// Waits for reads still in progress, then turns the recording into its smart version.
    func finish(_ steps: [MacroStep]) -> Result {
        queue.sync {}
        let all = lock.withLock { presses }
        var steps = steps
        var app: TargetApp?
        if target == nil {
            // Whole screen: only when every click went to the same window can positions become window-relative.
            let windows = Set(all.values.map { "\($0.app.bundleID) \(Int($0.origin.x)) \(Int($0.origin.y))" })
            guard windows.count == 1, let first = all.values.first else { return Result(steps: steps) }
            app = first.app
            for i in steps.indices {
                if let p = steps[i].action.point {
                    steps[i].action.point = CGPoint(x: p.x - first.origin.x, y: p.y - first.origin.y)
                }
            }
        }
        let labels = all.compactMapValues(\.label)
        let converted = Self.convert(steps, labels: labels)
        return Result(steps: converted.steps, app: app, words: converted.words, pictures: converted.pictures)
    }

    /// What's under `p`: its words and a picture of it when there are both (found by either when played back),
    /// otherwise whichever there is.
    static func both(in px: ScreenReader.WindowPixels, at p: CGPoint) -> Label? {
        let words = label(in: TextFinder.read(px), at: p, window: CGSize(width: px.width, height: px.height))
        let pic = picture(in: px, at: p)
        guard var l = words else { return pic }
        if let pic { l.picture = pic.picture; l.size = pic.size }
        return l
    }

    /// The short label under `p`, if there is one.
    static func label(in lines: [TextFinder.Line], at p: CGPoint, window: CGSize) -> Label? {
        let hits = lines.filter { $0.rect.insetBy(dx: -6, dy: -6).contains(p) }
        guard let line = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Labels are short. A click inside a sentence is usually placing the text cursor, so it stays a
        // plain click at its position.
        guard text.count <= 30, text.split(separator: " ").count <= 4 else { return nil }
        // Something a person would call a label: at least two characters, including a letter.
        guard text.count >= 2, text.contains(where: \.isLetter) else { return nil }
        let copies = lines.filter {
            $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.count
        let area = copies > 1 ? around(p, in: window) : nil
        return Label(text: text, area: area)
    }

    /// A small picture of the spot under `p`, when it has enough detail to be found again (plain
    /// backgrounds and flat areas don't).
    static func picture(in px: ScreenReader.WindowPixels, at p: CGPoint) -> Label? {
        let side: CGFloat = 56
        let rect = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height)).integral
        guard rect.width >= 24, rect.height >= 24, let crop = px.cropped(to: rect), detail(crop) >= 22,
              let cg = crop.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        return Label(picture: png, size: rect.size,
                     area: around(p, in: CGSize(width: px.width, height: px.height)))
    }

    /// Spread of brightness (standard deviation, 0–255): low means a flat, featureless spot.
    static func detail(_ px: ScreenReader.WindowPixels) -> Double {
        var sum = 0.0, sq = 0.0
        let n = px.width * px.height
        guard n > 0 else { return 0 }
        for i in 0..<n {
            let o = i * 4
            let y = 0.299 * Double(px.rgba[o]) + 0.587 * Double(px.rgba[o + 1]) + 0.114 * Double(px.rgba[o + 2])
            sum += y; sq += y * y
        }
        let mean = sum / Double(n)
        return (sq / Double(n) - mean * mean).squareRoot()
    }

    private static func around(_ p: CGPoint, in window: CGSize) -> CGRect {
        CGRect(x: p.x - 200, y: p.y - 120, width: 400, height: 240)
            .intersection(CGRect(origin: .zero, size: window)).integral
    }

    /// Replaces left clicks with “find it, then click” steps: words wait up to 5 s, pictures up to 3 s, then the
    /// recorded spot is clicked. Several quick taps on one spot become “keep tapping until it's gone”. The cursor
    /// travel before a click is dropped (the step clicks wherever its target is), keeping its time as the step's delay.
    static func convert(_ steps: [MacroStep], labels: [UUID: Label]) -> (steps: [MacroStep], words: Int, pictures: Int) {
        guard !labels.isEmpty else { return (steps, 0, 0) }
        var out: [MacroStep] = []
        var words = 0, pictures = 0
        for g in ActionGrouper.groups(for: steps) {
            guard case .click(.left, let count, let at?, let hold) = g.kind, hold < 0.5,
                  g.actionIndex < g.range.upperBound,
                  let label = labels[steps[g.actionIndex].id] else {
                out.append(contentsOf: steps[g.range])
                continue
            }
            var find: ImageStep
            if let text = label.text {
                if let png = label.picture {
                    // Both: the picture (quick, exact) or the words.
                    find = ImageStep(png: png, width: label.size.width, height: label.size.height,
                                     originX: Double(at.x) - label.size.width / 2, originY: Double(at.y) - label.size.height / 2)
                    find.strictness = 0.85
                    find.alsoPicture = true
                } else {
                    find = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
                }
                find.text = text
                find.timeout = 5
                words += 1
            } else if let png = label.picture {
                find = ImageStep(png: png, width: label.size.width, height: label.size.height,
                                 originX: Double(at.x) - label.size.width / 2, originY: Double(at.y) - label.size.height / 2)
                find.strictness = 0.85
                find.timeout = 3
                pictures += 1
            } else {
                out.append(contentsOf: steps[g.actionIndex..<g.range.upperBound])
                continue
            }
            find.area = label.area
            if label.window != .zero { find.captureWindow = label.window }
            find.otherwise = .continueAnyway
            find.fallbackX = Double(at.x)
            find.fallbackY = Double(at.y)
            if count > 1 {
                // Tapped several times: keep tapping until it's gone (a laggy button, or one that takes a few taps).
                find.repeatUntilGone = true
                find.repeatEvery = 0.4
            }
            let travel = steps[g.range.lowerBound...g.actionIndex].reduce(0) { $0 + $1.delay }
            out.append(MacroStep(delay: travel, action: .findImage(find)))
        }
        return (out, words, pictures)
    }
}
