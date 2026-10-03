import Accelerate
import AppKit
import CoreGraphics

// MARK: - Model

/// What a watcher was before watchers became background macros. Kept only to convert old files.
struct Watcher: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Watchers always look inside a target app's window.
    var target = TargetOptions(delivery: .jumpReturn)
    /// The picture to look for (PNG, 2× pixels) and its size in points.
    var templatePNG: Data?
    var templateWidth: Double = 0
    var templateHeight: Double = 0
    /// 0…1. How closely the screen must match the picture.
    var strictness: Double = 0.8
    var button: MouseButton = .left
    /// Seconds between clicks while the picture stays visible.
    var interval: Double = 0.5
    /// Seconds the picture must be visible before the first click.
    var firstClickDelay: Double = 0
    /// Stop after this many clicks (0 = never).
    var maxClicks: Int = 0
    /// Where to click, relative to the picture's centre (points).
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Look for this text instead of the picture (nil = picture).
    var text: String?
    /// Only search inside this part of the window (window points; nil = whole window).
    var area: CGRect?

    var isText: Bool { !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    /// Has something to look for.
    var canSearch: Bool { text != nil ? isText : hasTemplate }

    var templateSize: CGSize { CGSize(width: templateWidth, height: templateHeight) }
    var hasTemplate: Bool { templatePNG != nil && templateWidth >= 4 && templateHeight >= 4 }
}

struct WatcherStore {
    let url: URL

    init() {
        let dir = AppFolder.url
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("Watchers.json")
    }

    func load() -> [Watcher] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Watcher].self, from: data) else { return [] }
        return list
    }

    /// After the watchers became background macros: keep the old file as a backup, out of the way.
    func retire() {
        let backup = url.deletingLastPathComponent().appendingPathComponent("Watchers (converted to macros).json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}

// MARK: - Template matching

struct GrayImage {
    let width: Int
    let height: Int
    var pixels: [Float]
}

enum TemplateMatcher {
    struct Prepared {
        let full: GrayImage
        let coarse: GrayImage
        let factor: Int
        let meanColor: SIMD3<Float>
        /// The middle of the picture (where text and icons usually are), checked separately so look-alikes
        /// sharing the same frame (e.g. "Confirm" vs "Cancel") don't count.
        let inner: (img: GrayImage, x: Int, y: Int)?
    }

    struct Match {
        /// Window-relative rectangle, in points.
        let rect: CGRect
        /// 0…1 similarity (zero-mean normalized cross-correlation, lowered if the colors differ).
        let score: Double
    }

    /// RGBA bytes of `image` drawn at `width`×`height`, top row first.
    static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? buf : nil
    }

    static func gray(_ rgba: [UInt8], width: Int, height: Int) -> GrayImage {
        let n = width * height
        var px = [Float](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { src in
            px.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let j = i &* 4
                    dst[i] = 0.299 * Float(src[j]) + 0.587 * Float(src[j &+ 1]) + 0.114 * Float(src[j &+ 2])
                }
            }
        }
        return GrayImage(width: width, height: height, pixels: px)
    }

    static func meanColor(_ rgba: [UInt8], width: Int, rect: (x: Int, y: Int, w: Int, h: Int)) -> SIMD3<Float> {
        var sum = SIMD3<Float>(0, 0, 0)
        for y in rect.y..<(rect.y + rect.h) {
            for x in rect.x..<(rect.x + rect.w) {
                let i = (y * width + x) * 4
                sum += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]))
            }
        }
        return sum / Float(max(1, rect.w * rect.h))
    }

    /// Light blur (3×3 box, twice ≈ Gaussian σ≈1). Applied to both picture and screen so video noise,
    /// compression and slight blur matter less than the actual shapes.
    static func smooth(_ g: GrayImage) -> GrayImage {
        // A 3×3 box blur applied twice is the separable kernel [1 2 3 2 1]/9 in each direction.
        guard g.width >= 5, g.height >= 5 else { return smoothSlow(g) }
        var out = [Float](repeating: 0, count: g.pixels.count)
        let kernel: [Float] = [1, 2, 3, 2, 1].map { $0 / 9 }
        let ok = g.pixels.withUnsafeBufferPointer { sp -> Bool in
            out.withUnsafeMutableBufferPointer { dp -> Bool in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: sp.baseAddress), height: vImagePixelCount(g.height),
                                        width: vImagePixelCount(g.width), rowBytes: g.width * 4)
                var dst = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(g.height),
                                        width: vImagePixelCount(g.width), rowBytes: g.width * 4)
                return vImageSepConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, 5, kernel, 5, 0, 0,
                                                 vImage_Flags(kvImageEdgeExtend)) == kvImageNoError
            }
        }
        return ok ? GrayImage(width: g.width, height: g.height, pixels: out) : smoothSlow(g)
    }

    private static func smoothSlow(_ g: GrayImage) -> GrayImage {
        var img = g
        for _ in 0..<2 {
            var tmp = img.pixels
            let w = img.width, h = img.height
            for y in 0..<h {
                for x in 0..<w {
                    let l = img.pixels[y * w + max(0, x - 1)], c = img.pixels[y * w + x], r = img.pixels[y * w + min(w - 1, x + 1)]
                    tmp[y * w + x] = (l + c + r) / 3
                }
            }
            var out = tmp
            for y in 0..<h {
                for x in 0..<w {
                    let u = tmp[max(0, y - 1) * w + x], c = tmp[y * w + x], d = tmp[min(h - 1, y + 1) * w + x]
                    out[y * w + x] = (u + c + d) / 3
                }
            }
            img.pixels = out
        }
        return img
    }

    /// Box-filter shrink by an integer factor.
    static func downscale(_ g: GrayImage, by f: Int) -> GrayImage {
        guard f > 1 else { return g }
        let w = g.width / f, h = g.height / f
        var px = [Float](repeating: 0, count: max(0, w * h))
        let inv = 1 / Float(f * f)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for j in 0..<f {
                    let row = (y * f + j) * g.width + x * f
                    for i in 0..<f { s += g.pixels[row + i] }
                }
                px[y * w + x] = s * inv
            }
        }
        return GrayImage(width: w, height: h, pixels: px)
    }

    static func prepare(_ w: Watcher) -> Prepared? {
        guard w.hasTemplate, let data = w.templatePNG else { return nil }
        return prepare(png: data, width: w.templateWidth, height: w.templateHeight)
    }

    /// Prepares a stored picture (2× PNG) for matching at 1 pixel per point.
    static func prepare(png data: Data, width: Double, height: Double) -> Prepared? {
        guard width >= 4, height >= 4, let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        let tw = Int(width.rounded()), th = Int(height.rounded())
        guard let px = rgba(cg, width: tw, height: th) else { return nil }
        let full = smooth(gray(px, width: tw, height: th))
        // Keep the coarse template at least ~8 px on its short side.
        let factor = max(1, min(tw, th) / 8)
        var inner: (img: GrayImage, x: Int, y: Int)?
        let ix = tw / 5, iy = th / 4, iw = tw - 2 * ix, ih = th - 2 * iy
        if iw >= 6, ih >= 6 {
            var img = GrayImage(width: iw, height: ih, pixels: [])
            img.pixels.reserveCapacity(iw * ih)
            for j in 0..<ih { for i in 0..<iw { img.pixels.append(full.pixels[(iy + j) * tw + ix + i]) } }
            inner = (img, ix, iy)
        }
        return Prepared(full: full, coarse: downscale(full, by: factor), factor: factor,
                        meanColor: meanColor(px, width: tw, rect: (0, 0, tw, th)), inner: inner)
    }

    /// Finds the best match of `t` in a window image captured at 1 pixel per point.
    /// One captured window, processed once and shared by every picture searched in it.
    final class Scene {
        let rgba: [UInt8]
        let width: Int
        let height: Int
        let image: GrayImage
        let integral: Integral
        private var coarse: [Int: (img: GrayImage, ii: Integral)] = [:]

        init(rgba: [UInt8], width: Int, height: Int) {
            self.rgba = rgba
            self.width = width
            self.height = height
            image = TemplateMatcher.smooth(TemplateMatcher.gray(rgba, width: width, height: height))
            integral = Integral(image)
        }

        func coarse(_ f: Int) -> (img: GrayImage, ii: Integral) {
            if let c = coarse[f] { return c }
            let img = TemplateMatcher.downscale(image, by: f)
            let c = (img, Integral(img))
            coarse[f] = c
            return c
        }
    }

    static func find(_ t: Prepared, inRGBA rgbaBuf: [UInt8], width W: Int, height H: Int) -> Match? {
        find(t, in: Scene(rgba: rgbaBuf, width: W, height: H))
    }

    static func find(_ t: Prepared, in scene: Scene) -> Match? {
        let W = scene.width, H = scene.height, rgbaBuf = scene.rgba
        let tw = t.full.width, th = t.full.height
        guard W >= tw, H >= th, tw > 0, th > 0 else { return nil }
        let image = scene.image
        let f = t.factor
        let (coarse, coarseII) = scene.coarse(f)
        guard coarse.width >= t.coarse.width, coarse.height >= t.coarse.height else { return nil }

        // 1. Coarse scan: keep the few best, well-separated candidates.
        let coarseScores = scoreMap(image: coarse, integral: coarseII, template: t.coarse)
        let cw = coarse.width - t.coarse.width + 1
        var candidates: [(x: Int, y: Int)] = []
        var scores = coarseScores
        let sep = max(2, max(t.coarse.width, t.coarse.height) / 2)
        for _ in 0..<3 {
            guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] > -1 else { break }
            let bx = best % cw, by = best / cw
            candidates.append((bx, by))
            for y in max(0, by - sep)...min(scores.count / cw - 1, by + sep) {
                for x in max(0, bx - sep)...min(cw - 1, bx + sep) { scores[y * cw + x] = -2 }
            }
        }

        // 2. Refine each candidate at full resolution.
        let ii = scene.integral
        let tz = zeroMean(t.full)
        var best: (x: Int, y: Int, s: Double) = (0, 0, -1)
        for c in candidates {
            let x0 = max(0, c.x * f - f - 1), x1 = min(W - tw, c.x * f + f + 1)
            let y0 = max(0, c.y * f - f - 1), y1 = min(H - th, c.y * f + f + 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            var spot: (x: Int, y: Int, s: Float) = (0, 0, -1)
            for y in y0...y1 {
                for x in x0...x1 {
                    let s = zncc(image, tz.pixels, tw, th, tz.norm, tz.mean, ii, x, y)
                    if s > spot.s { spot = (x, y, s) }
                }
            }
            guard spot.s > -1 else { continue }
            // 3. The middle must match too, not just the overall shape.
            var combined = Double(spot.s)
            if let inner = t.inner {
                combined = min(combined, patchScore(image, inner.img, spot.x + inner.x, spot.y + inner.y))
            }
            if combined > best.s { best = (spot.x, spot.y, combined) }
        }
        guard best.s > -1 else { return nil }

        // 4. Same shape in a clearly different color (e.g. a greyed-out button) shouldn't count.
        var score = max(0, best.s)
        let mc = meanColor(rgbaBuf, width: W, rect: (best.x, best.y, tw, th))
        let d = mc - t.meanColor
        if (Swift.abs(d.x) + Swift.abs(d.y) + Swift.abs(d.z)) / 3 > 45 { score *= 0.5 }
        return Match(rect: CGRect(x: best.x, y: best.y, width: tw, height: th), score: score)
    }

    /// Edge strength (Sobel magnitude): outlines of shapes and letters.
    static func edges(_ g: GrayImage) -> GrayImage {
        let w = g.width, h = g.height
        var out = [Float](repeating: 0, count: w * h)
        guard w > 2, h > 2 else { return GrayImage(width: w, height: h, pixels: out) }
        let p = g.pixels
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = (p[i - w + 1] + 2 * p[i + 1] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - 1] + p[i + w - 1])
                let gy = (p[i + w - 1] + 2 * p[i + w] + p[i + w + 1]) - (p[i - w - 1] + 2 * p[i - w] + p[i - w + 1])
                out[i] = (gx * gx + gy * gy).squareRoot()
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Plain ZNCC between a template and the same-size patch of `img` at (x, y).
    static func patchScore(_ img: GrayImage, _ t: GrayImage, _ x: Int, _ y: Int) -> Double {
        let n = t.width * t.height
        var a = [Float](repeating: 0, count: n)
        for j in 0..<t.height { for i in 0..<t.width { a[j * t.width + i] = img.pixels[(y + j) * img.width + x + i] } }
        let ma = a.reduce(0, +) / Float(n), mb = t.pixels.reduce(0, +) / Float(n)
        var num: Float = 0, da: Float = 0, db: Float = 0
        for k in 0..<n {
            let u = a[k] - ma, v = t.pixels[k] - mb
            num += u * v; da += u * u; db += v * v
        }
        return da > 0 && db > 0 ? Double(num / (da * db).squareRoot()) : 0
    }

    // MARK: Scoring internals

    struct Integral {
        let w: Int
        var s: [Double], s2: [Double]
        init(_ g: GrayImage) {
            let w = g.width + 1
            self.w = w
            var s = [Double](repeating: 0, count: w * (g.height + 1))
            var s2 = s
            g.pixels.withUnsafeBufferPointer { p in
                s.withUnsafeMutableBufferPointer { a in
                    s2.withUnsafeMutableBufferPointer { b in
                        for y in 0..<g.height {
                            var row = 0.0, row2 = 0.0
                            let src = y &* g.width, up = y &* w, here = (y &+ 1) &* w
                            for x in 0..<g.width {
                                let v = Double(p[src &+ x])
                                row += v; row2 += v * v
                                a[here &+ x &+ 1] = a[up &+ x &+ 1] + row
                                b[here &+ x &+ 1] = b[up &+ x &+ 1] + row2
                            }
                        }
                    }
                }
            }
            self.s = s
            self.s2 = s2
        }
        func sum(_ a: [Double], _ x: Int, _ y: Int, _ rw: Int, _ rh: Int) -> Double {
            a[(y + rh) * w + x + rw] - a[y * w + x + rw] - a[(y + rh) * w + x] + a[y * w + x]
        }
    }

    private static func zeroMean(_ t: GrayImage) -> (pixels: [Float], norm: Double, mean: Float) {
        let mean = t.pixels.reduce(0, +) / Float(max(1, t.pixels.count))
        let z = t.pixels.map { $0 - mean }
        let norm = sqrt(z.reduce(0) { $0 + Double($1 * $1) })
        return (z, norm, mean)
    }

    /// Zero-mean normalized cross-correlation of the template at (x, y). 1 = identical pattern.
    private static func zncc(_ img: GrayImage, _ tz: [Float], _ tw: Int, _ th: Int, _ tNorm: Double, _ tMean: Float,
                             _ ii: Integral, _ x: Int, _ y: Int) -> Float {
        let n = Double(tw * th)
        let sum = ii.sum(ii.s, x, y, tw, th), sum2 = ii.sum(ii.s2, x, y, tw, th)
        let varI = max(0, sum2 - sum * sum / n)
        if tNorm < 1 {
            // A flat, single-color picture has no pattern; compare brightness instead.
            let mean = Float(sum / n)
            return varI / n < 4 ? max(0, 1 - abs(mean - tMean) / 64) : 0
        }
        guard varI > 1e-3 else { return 0 }
        var cross: Float = 0
        img.pixels.withUnsafeBufferPointer { ip in
            tz.withUnsafeBufferPointer { tp in
                for j in 0..<th {
                    let row = (y + j) * img.width + x, trow = j * tw
                    for i in 0..<tw { cross += ip[row + i] * tp[trow + i] }
                }
            }
        }
        return Float(Double(cross) / (sqrt(varI) * tNorm))
    }

    /// ZNCC at every position (row-major, width = image.width - template.width + 1).
    private static func scoreMap(image: GrayImage, integral ii: Integral, template: GrayImage) -> [Float] {
        let tw = template.width, th = template.height
        let cw = image.width - tw + 1, ch = image.height - th + 1
        guard cw > 0, ch > 0 else { return [] }
        let tz = zeroMean(template)
        if tz.norm < 1 {
            // Flat picture: rare, keep the simple path.
            var out = [Float](repeating: -1, count: cw * ch)
            for y in 0..<ch { for x in 0..<cw { out[y * cw + x] = zncc(image, tz.pixels, tw, th, tz.norm, tz.mean, ii, x, y) } }
            return out
        }
        var out = [Float](repeating: 0, count: cw * ch)
        let n = Double(tw * th), W = image.width, iw = ii.w, tNorm = tz.norm
        // Same maths as `zncc`, with everything hoisted out of the hot loop.
        image.pixels.withUnsafeBufferPointer { ip in
            tz.pixels.withUnsafeBufferPointer { tp in
                ii.s.withUnsafeBufferPointer { s in
                    ii.s2.withUnsafeBufferPointer { s2 in
                        out.withUnsafeMutableBufferPointer { op in
                            for y in 0..<ch {
                                for x in 0..<cw {
                                    let a = y &* iw &+ x, b = a &+ tw, c = (y &+ th) &* iw &+ x, d = c &+ tw
                                    let sum = s[d] - s[b] - s[c] + s[a]
                                    let varI = s2[d] - s2[b] - s2[c] + s2[a] - sum * sum / n
                                    guard varI > 1e-3 else { continue }
                                    var cross: Float = 0
                                    for j in 0..<th {
                                        let row = (y &+ j) &* W &+ x, trow = j &* tw
                                        for i in 0..<tw { cross += ip[row &+ i] * tp[trow &+ i] }
                                    }
                                    op[y &* cw &+ x] = Float(Double(cross) / (varI.squareRoot() * tNorm))
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}

enum PictureCrop {
    /// Crops `rect` (window points) from a full-resolution window screenshot. Returns PNG data and the size in points.
    static func crop(_ rect: CGRect, from image: NSImage) -> (png: Data, width: Double, height: Double)? {
        guard let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
              let cg = rep.cgImage else { return nil }
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let px = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = cg.cropping(to: px),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { return nil }
        return (png, Double(rect.width.rounded()), Double(rect.height.rounded()))
    }
}

