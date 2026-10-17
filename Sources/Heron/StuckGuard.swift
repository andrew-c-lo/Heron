import Foundation
import Vision

/// What "tap when stuck" checks before tapping (measured in bench/unstuck: the stuck tap kept tapping finished
/// runs, and tapped a shop).
enum StuckGuard {
    /// A price: a currency sign next to a number ("$0.99", "€4,99", "¥120", "1.99 £").
    static func isPrice(_ text: String) -> Bool {
        text.range(of: #"[$€£¥]\s?\d|\d[\d.,]*\s?[$€£¥]"#, options: .regularExpression) != nil
    }

    /// Words that ask for money, in any app: with a price beside them, a purchase is one tap away.
    static let spendWords = ["buy", "purchase", "pay", "subscribe", "checkout", "add to cart", "top up", "recharge"]

    static func asksToSpend(_ text: String) -> Bool {
        spendWords.contains { TextFinder.wholeWordRange(of: $0, in: text) != nil }
    }

    /// A shop or purchase screen, where a blind tap could spend money: two or more prices, or a price with words
    /// like “Buy” or “Purchase” (a single “Buy for $4.99” confirmation).
    static func looksLikeShop(_ lines: [TextFinder.Line]) -> Bool {
        let prices = lines.filter { isPrice($0.text) }.count
        return prices >= 2 || (prices == 1 && lines.contains { asksToSpend($0.text) })
    }

    // MARK: Where a blind tap is safe

    /// What counts as empty space for a blind tap. Fitted in bench/tapspot (synthetic screens with known buttons,
    /// and the labelled stuck screens).
    struct SpotRule {
        /// Half the side of the square that must be empty, in window points (a fingertip-sized area).
        var radius: Double = 18
        /// Text closer than this to the square counts as touching it (a label sits inside its button's border).
        var textMargin: Double = 10
        /// Mean edge strength (0–1) above which the square looks like a control: a border, an icon, a glyph.
        var edgeLimit: Double = 0.04
        /// Spacing of the spots tried when the preferred one isn't empty.
        var step: Double = 12
        /// Inside a shape: a hard edge within this many points on both sides (a button's flat inside has no edges
        /// of its own, but its border is around it).
        var enclosedWithin: Double = 60
        /// A brightness step (0–1) this big is a hard edge: a border or a panel's side, not shading in artwork.
        var hardEdge: Double = 0.06
        /// The window's own edge closes a shape too (a tab bar along the bottom has no border below it).
        var windowEdgeCloses = true
        static let standard = SpotRule()
    }

    /// Mean edge strength of every square, answered in constant time each (a summed-area table of gradients).
    struct EdgeMap {
        let width: Int, height: Int
        private let sums: [Double] // (width+1) × (height+1)
        private let luma: [Double]

        init(_ px: ScreenReader.WindowPixels) {
            let width = px.width, height = px.height
            self.width = width; self.height = height
            var luma = [Double](repeating: 0, count: width * height)
            px.rgba.withUnsafeBufferPointer { b in
                for i in 0..<(width * height) {
                    luma[i] = (0.299 * Double(b[i * 4]) + 0.587 * Double(b[i * 4 + 1]) + 0.114 * Double(b[i * 4 + 2])) / 255
                }
            }
            var s = [Double](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row = 0.0
                for x in 0..<width {
                    let i = y * width + x
                    let gx = x + 1 < width ? abs(luma[i + 1] - luma[i]) : 0
                    let gy = y + 1 < height ? abs(luma[i + width] - luma[i]) : 0
                    row += gx + gy
                    s[(y + 1) * (width + 1) + x + 1] = s[y * (width + 1) + x + 1] + row
                }
            }
            sums = s
            self.luma = luma
        }

        /// Brightness (0–1) at a point, clamped to the picture.
        func brightness(_ x: Int, _ y: Int) -> Double {
            luma[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        /// Whether walking from `p` in direction (dx, dy) meets a hard edge within `limit` points.
        func edge(from p: CGPoint, dx: Int, dy: Int, limit: Double, step: Double, windowCloses: Bool = true) -> Bool {
            var x = Int(p.x), y = Int(p.y)
            var prev = brightness(x, y)
            for _ in 0..<Int(limit / 2) {
                x += dx * 2; y += dy * 2
                if x < 0 || y < 0 || x >= width || y >= height { return windowCloses }
                let b = brightness(x, y)
                if abs(b - prev) >= step { return true }
                prev = b
            }
            return false
        }

        /// Where the app draws: inside the flat bands along the window's edges (a mirrored phone's bezel, a
        /// letterbox, an empty margin). A row or column is flat when almost all of it matches its own median.
        /// Scanning a row costs a sort, so it's done once per stuck tap, not per spot.
        func content() -> CGRect {
            func flatRow(_ y: Int) -> Bool {
                let row = (0..<width).map { brightness($0, y) }
                let m = row.sorted()[width / 2]
                return Double(row.filter { abs($0 - m) > 0.08 }.count) < Double(width) * 0.05
            }
            func flatColumn(_ x: Int) -> Bool {
                let col = (0..<height).map { brightness(x, $0) }
                let m = col.sorted()[height / 2]
                return Double(col.filter { abs($0 - m) > 0.08 }.count) < Double(height) * 0.05
            }
            // A band is at most a fifth of the window: a plain screen (“Tap to continue” on a flat background)
            // is all flat, and its middle is exactly where to tap.
            let capY = height / 5, capX = width / 5
            var top = 0, bottom = height - 1, left = 0, right = width - 1
            while top < capY && flatRow(top) { top += 1 }
            while bottom > height - 1 - capY && flatRow(bottom) { bottom -= 1 }
            while left < capX && flatColumn(left) { left += 1 }
            while right > width - 1 - capX && flatColumn(right) { right -= 1 }
            return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }

        /// Inside a shape: hard edges close by on both sides, above and below or left and right (a wide button or
        /// a list row is closed in only from above and below).
        func enclosed(_ p: CGPoint, within limit: Double, step: Double, windowCloses: Bool = true) -> Bool {
            func e(_ dx: Int, _ dy: Int) -> Bool { edge(from: p, dx: dx, dy: dy, limit: limit, step: step, windowCloses: windowCloses) }
            return (e(0, -1) && e(0, 1)) || (e(-1, 0) && e(1, 0))
        }

        /// Mean edge strength inside `r` (clipped to the picture).
        func mean(in r: CGRect) -> Double {
            let x0 = max(0, Int(r.minX)), y0 = max(0, Int(r.minY))
            let x1 = min(width, Int(r.maxX)), y1 = min(height, Int(r.maxY))
            guard x1 > x0, y1 > y0 else { return 1 }
            let w = width + 1
            let total = sums[y1 * w + x1] - sums[y0 * w + x1] - sums[y1 * w + x0] + sums[y0 * w + x0]
            return total / Double((x1 - x0) * (y1 - y0))
        }
    }

    /// Is a fingertip at `p` on empty space: no text near it, and nothing drawn there that looks like a control?
    static func isEmpty(_ p: CGPoint, edges: EdgeMap, text: [CGRect], rule: SpotRule = .standard) -> Bool {
        let box = CGRect(x: p.x - rule.radius, y: p.y - rule.radius, width: rule.radius * 2, height: rule.radius * 2)
        guard box.minX >= 0, box.minY >= 0, box.maxX <= Double(edges.width), box.maxY <= Double(edges.height) else { return false }
        if text.contains(where: { $0.insetBy(dx: -rule.textMargin, dy: -rule.textMargin).intersects(box) }) { return false }
        guard edges.mean(in: box) <= rule.edgeLimit else { return false }
        // A fingertip touching a control's border is on the control.
        if [(1, 0), (-1, 0), (0, 1), (0, -1)].contains(where: {
            edges.edge(from: p, dx: $0.0, dy: $0.1, limit: rule.radius, step: rule.hardEdge, windowCloses: false)
        }) { return false }
        return !edges.enclosed(p, within: rule.enclosedWithin, step: rule.hardEdge, windowCloses: rule.windowEdgeCloses)
    }

    /// Where a blind “tap when stuck” should go: the chosen spot if it's empty space, otherwise the nearest empty
    /// spot, or nil when nothing on the screen is empty (then it's better not to tap at all). A “tap anywhere to
    /// continue” screen takes a tap on empty space; a menu, a tab bar, a shop button never is empty space, in any
    /// app, so no list of words is needed.
    static func safeSpot(_ px: ScreenReader.WindowPixels, lines: [TextFinder.Line], preferred: CGPoint,
                         rule: SpotRule = .standard) -> CGPoint? {
        let edges = EdgeMap(px)
        let text = lines.map(\.rect)
        // Only where the app draws: a tap on a bezel or a letterbox is safe but does nothing.
        let content = edges.content()
        let inside = content.insetBy(dx: rule.radius, dy: rule.radius)
        if inside.contains(preferred), isEmpty(preferred, edges: edges, text: text, rule: rule) { return preferred }
        var best: (d: Double, p: CGPoint)?
        var y = max(rule.radius, inside.minY)
        while y <= min(Double(px.height) - rule.radius, inside.maxY) {
            var x = max(rule.radius, inside.minX)
            while x <= min(Double(px.width) - rule.radius, inside.maxX) {
                let p = CGPoint(x: x, y: y)
                let d = hypot(x - preferred.x, y - preferred.y)
                if d < (best?.d ?? .infinity), isEmpty(p, edges: edges, text: text, rule: rule) { best = (d, p) }
                x += rule.step
            }
            y += rule.step
        }
        return best?.p
    }

    /// Below this, two screens are the same screen (Vision feature-print distance; set on the eval's practice set).
    static let sameScreen: Float = 0.30

    static func fingerprint(_ px: ScreenReader.WindowPixels) -> VNFeaturePrintObservation? {
        guard let cg = px.cgImage else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return req.results?.first
    }

    static func same(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Bool {
        var d: Float = .infinity
        try? a.computeDistance(&d, to: b)
        return d < sameScreen
    }
}
