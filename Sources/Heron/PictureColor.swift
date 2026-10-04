import Foundation

/// A plain colour word for a picture with no words in it, so its step can be told apart (“Tap the red picture”).
enum PictureColor {
    static func name(_ px: ScreenReader.WindowPixels) -> String {
        let n = px.width * px.height
        guard n > 0 else { return "" }
        let stride = max(1, Int((Double(n) / 4096).squareRoot()))
        // Hue buckets weighted by how colourful each pixel is; greys tallied by brightness.
        var hues = [Double](repeating: 0, count: 8)
        var colourful = 0.0, total = 0.0, light = 0.0
        for y in Swift.stride(from: 0, to: px.height, by: stride) {
            for x in Swift.stride(from: 0, to: px.width, by: stride) {
                let i = (y * px.width + x) * 4
                let a = Double(px.rgba[i + 3]) / 255
                guard a > 0.5 else { continue }
                let r = Double(px.rgba[i]) / 255 / a, g = Double(px.rgba[i + 1]) / 255 / a, b = Double(px.rgba[i + 2]) / 255 / a
                let hi = max(r, g, b), lo = min(r, g, b), c = hi - lo
                total += 1
                light += hi
                let sat = hi > 0 ? c / hi : 0
                guard sat > 0.35, hi > 0.25 else { continue }
                var h: Double
                if hi == r { h = (g - b) / c } else if hi == g { h = (b - r) / c + 2 } else { h = (r - g) / c + 4 }
                h = (h * 60 + 360).truncatingRemainder(dividingBy: 360)
                let w = sat * hi
                colourful += w
                hues[bucket(h)] += w
            }
        }
        guard total > 0 else { return "" }
        if colourful / total > 0.12, let best = hues.indices.max(by: { hues[$0] < hues[$1] }) {
            return ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink"][best]
        }
        let l = light / total
        return l > 0.8 ? "white" : l < 0.2 ? "black" : l > 0.65 ? "light grey" : l < 0.35 ? "dark grey" : "grey"
    }

    private static func bucket(_ h: Double) -> Int {
        switch h {
        case ..<15, 345...: 0
        case ..<40: 1
        case ..<70: 2
        case ..<160: 3
        case ..<195: 4
        case ..<255: 5
        case ..<290: 6
        default: 7
        }
    }
}
