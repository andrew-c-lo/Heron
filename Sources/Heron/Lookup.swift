import CoreGraphics
import Foundation
import Vision

/// What a picture step or watcher looks for: a picture or a piece of text, optionally only inside an area of
/// the window. One place for "is it on screen, and where?", shared by chains, watchers and Test Now.
struct Lookup {
    var template: TemplateMatcher.Prepared?
    /// More pictures that count as the same thing; the best match among all of them wins.
    var variants: [TemplateMatcher.Prepared] = []
    var text: String?
    var area: CGRect?
    var strictness: Double

    init?(step s: ImageStep) {
        self.init(png: s.png, width: s.width, height: s.height, text: s.text, area: s.area,
                  strictness: s.strictness)
        if !isText {
            variants = s.variants.compactMap { TemplateMatcher.prepare(png: $0.png, width: $0.width, height: $0.height) }
        }
    }

    init?(watcher w: Watcher) {
        self.init(png: w.templatePNG, width: w.templateWidth, height: w.templateHeight, text: w.text,
                  area: w.area, strictness: w.strictness)
    }

    init?(png: Data?, width: Double, height: Double, text: String?, area: CGRect?, strictness: Double) {
        self.text = text?.trimmingCharacters(in: .whitespaces)
        self.area = area
        self.strictness = strictness
        // Text mode (even with nothing typed yet) never falls back to an old picture.
        if let t = self.text { if t.isEmpty { return nil } else { return } }
        guard let png, let t = TemplateMatcher.prepare(png: png, width: width, height: height) else { return nil }
        template = t
    }

    var isText: Bool { text?.isEmpty == false }

    /// Best match in the window (window coordinates), or nil. `scene` is reused for picture searches over the
    /// whole window, so several pictures can share one prepared frame.
    func find(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil) -> TemplateMatcher.Match? {
        var pixels = px, offset = CGPoint.zero
        if let a = area?.integral.intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height)),
           !a.isEmpty, let cropped = px.cropped(to: a) {
            pixels = cropped
            offset = a.origin
        }
        let local: TemplateMatcher.Match?
        if let text, !text.isEmpty {
            local = TextFinder.find(text, in: pixels)
        } else if let template {
            let useScene = offset == .zero && area == nil ? scene : nil
            let sc = useScene ?? TemplateMatcher.Scene(rgba: pixels.rgba, width: pixels.width, height: pixels.height)
            local = ([template] + variants).compactMap { TemplateMatcher.find($0, in: sc) }.max { $0.score < $1.score }
        } else {
            local = nil
        }
        return local.map { TemplateMatcher.Match(rect: $0.rect.offsetBy(dx: offset.x, dy: offset.y), score: $0.score) }
    }

    /// Where it is, if it's on screen right now (text counts as found whenever it's read; pictures must
    /// meet the strictness).
    func locate(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil) -> CGRect? {
        guard let m = find(in: px, scene: scene), isText || m.score >= strictness else { return nil }
        return m.rect
    }
}

/// On-device text recognition (Apple's Vision framework). Nothing leaves the Mac.
enum TextFinder {
    /// The first place `query` appears (case- and accent-insensitive), as a rectangle around just that text.
    static func find(_ query: String, in px: ScreenReader.WindowPixels) -> TemplateMatcher.Match? {
        guard let image = px.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // game and UI text isn't prose
        try? VNImageRequestHandler(cgImage: image).perform([request])

        let w = CGFloat(px.width), h = CGFloat(px.height)
        var best: (rect: CGRect, confidence: Float)?
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            // Vision boxes are normalized with the origin at the bottom left.
            let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
            let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
            // A line that is exactly the text beats one that merely contains it ("Claim" vs "Claim reward").
            let exact = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            let rank = candidate.confidence + (exact ? 1 : 0)
            if best == nil || rank > best!.confidence { best = (rect, rank) }
        }
        return best.map { TemplateMatcher.Match(rect: $0.rect, score: Double(min($0.confidence, 1))) }
    }

    /// Where `query` is among already-read lines (window coordinates), preferring a line that is exactly the
    /// text, then a word, then any line containing it. `area` limits where it may be.
    static func find(_ query: String, in lines: [Line], area: CGRect?) -> CGRect? {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func inArea(_ r: CGRect) -> Bool { area.map { $0.contains(CGPoint(x: r.midX, y: r.midY)) } ?? true }
        let q = query.trimmingCharacters(in: .whitespaces)
        if let l = lines.first(where: { $0.text.trimmingCharacters(in: .whitespaces).compare(q, options: opts) == .orderedSame && inArea($0.rect) }) {
            return l.rect
        }
        for l in lines {
            if let w = l.words.first(where: { $0.text.compare(q, options: opts) == .orderedSame && inArea($0.rect) }) { return w.rect }
        }
        return lines.first { $0.text.range(of: q, options: opts) != nil && inArea($0.rect) }?.rect
    }

    struct Line {
        let text: String
        let rect: CGRect
        let words: [(text: String, rect: CGRect)]
    }

    /// Every line of text in the picture, with a box for the line and for each word (window coordinates).
    static func read(_ px: ScreenReader.WindowPixels) -> [Line] {
        guard let image = px.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let w = CGFloat(px.width), h = CGFloat(px.height)
        func rect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let string = candidate.string
            var words: [(String, CGRect)] = []
            string.enumerateSubstrings(in: string.startIndex..., options: .byWords) { word, range, _, _ in
                guard let word, let box = try? candidate.boundingBox(for: range)?.boundingBox else { return }
                words.append((word, rect(box)))
            }
            return Line(text: string, rect: rect(observation.boundingBox), words: words)
        }
    }
}

extension ScreenReader.WindowPixels {
    /// The pixels inside `rect` (window points = pixels here).
    func cropped(to rect: CGRect) -> ScreenReader.WindowPixels? {
        let x0 = max(0, Int(rect.minX)), y0 = max(0, Int(rect.minY))
        let x1 = min(width, Int(rect.maxX)), y1 = min(height, Int(rect.maxY))
        guard x1 > x0, y1 > y0 else { return nil }
        let cw = x1 - x0, ch = y1 - y0
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<ch {
                    let s = ((y0 + y) * width + x0) * 4, d = y * cw * 4
                    for i in 0..<(cw * 4) { dst[d + i] = src[s + i] }
                }
            }
        }
        return ScreenReader.WindowPixels(rgba: out, width: cw, height: ch)
    }

    var cgImage: CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
