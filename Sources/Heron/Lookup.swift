import AppKit
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

    /// The window size the picture and area belong to; when the window is now a different size, both are
    /// resized to match (nil = use them as they are).
    var reference: CGSize?
    /// The target is an Android emulator: resizing follows its Android screen, not the whole window (`WindowFit`).
    var emulator = false
    /// Where the words are inside the picture, as fractions of it (for steps with a click box).
    var wordsInPicture: CGRect?
    /// The pictures as stored, for resizing.
    private var sources: [(png: Data, width: Double, height: Double)] = []
    private let resized = ResizedCache()

    init?(step s: ImageStep, reference: CGSize? = nil, emulator: Bool = false) {
        self.init(png: s.png, width: s.width, height: s.height, text: s.text, area: s.area,
                  strictness: s.strictness, alsoPicture: s.alsoPicture)
        self.reference = s.captureWindow ?? reference
        self.emulator = emulator
        // A click box is drawn on the picture: when the words are what's found, the box is placed by where the
        // words sit in the picture, not squeezed onto the words themselves.
        if s.clickArea != nil, !s.png.isEmpty, let t = self.text, !t.isEmpty {
            wordsInPicture = Self.wordsRect(t, inPicture: s.png)
        }
        if template != nil {
            variants = s.variants.compactMap { TemplateMatcher.prepare(png: $0.png, width: $0.width, height: $0.height) }
            sources = [(s.png, s.width, s.height)] + s.variants.map { ($0.png, $0.width, $0.height) }
        }
    }

    /// Prepared pictures at each size used so far.
    private final class ResizedCache: @unchecked Sendable {
        let lock = NSLock()
        var byScale: [Int: [TemplateMatcher.Prepared]] = [:]
    }

    /// How much bigger the window is than the one the picture was picked in (1 = same).
    func scale(for size: CGSize) -> Double { fit(for: size).s }

    /// How the step's window coordinates land on a window this size.
    func fit(for size: CGSize) -> WindowFit { .between(reference, size, emulator: emulator) }

    /// The search area in this window's coordinates.
    func scaledArea(for size: CGSize) -> CGRect? {
        let f = fit(for: size)
        guard !f.isSame, let a = area else { return area }
        return f.rect(a)
    }

    /// The pictures prepared at scale `s`.
    private func pictures(at s: Double) -> [TemplateMatcher.Prepared] {
        if s == 1 { return (template.map { [$0] } ?? []) + variants }
        let key = Int((s * 100).rounded())
        if let hit = resized.lock.withLock({ resized.byScale[key] }) { return hit }
        let made = sources.compactMap { TemplateMatcher.prepare(png: $0.png, width: $0.width * s, height: $0.height * s) }
        resized.lock.withLock { resized.byScale[key] = made }
        return made
    }

    init?(watcher w: Watcher) {
        self.init(png: w.templatePNG, width: w.templateWidth, height: w.templateHeight, text: w.text,
                  area: w.area, strictness: w.strictness)
    }

    /// `text` set = look for words; with `alsoPicture` the picture counts too.
    init?(png: Data?, width: Double, height: Double, text: String?, area: CGRect?, strictness: Double,
          alsoPicture: Bool = false) {
        self.text = text?.trimmingCharacters(in: .whitespaces)
        self.area = area
        self.strictness = strictness
        if self.text == nil || alsoPicture, let png, !png.isEmpty {
            template = TemplateMatcher.prepare(png: png, width: width, height: height)
        }
        // Text mode (even with nothing typed yet) never falls back to an old picture.
        if self.text?.isEmpty == true { self.text = nil; if !alsoPicture { return nil } }
        guard template != nil || hasText else { return nil }
    }

    var hasPicture: Bool { template != nil }
    var hasText: Bool { text?.isEmpty == false }
    /// Only words (no picture).
    var isText: Bool { hasText && !hasPicture }

    /// The pixels inside the search area, and where they sit in the window.
    private func searchPixels(_ px: ScreenReader.WindowPixels) -> (ScreenReader.WindowPixels, CGPoint) {
        if let a = scaledArea(for: CGSize(width: px.width, height: px.height))?.integral.intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height)),
           !a.isEmpty, let cropped = px.cropped(to: a) {
            return (cropped, a.origin)
        }
        return (px, .zero)
    }

    /// Best picture match (any score), window coordinates.
    func matchPicture(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil) -> TemplateMatcher.Match? {
        guard template != nil else { return nil }
        let (pixels, offset) = searchPixels(px)
        let sc = (offset == .zero && area == nil ? scene : nil)
            ?? TemplateMatcher.Scene(rgba: pixels.rgba, width: pixels.width, height: pixels.height)
        let pics = pictures(at: scale(for: CGSize(width: px.width, height: px.height)))
        let m = pics.compactMap { TemplateMatcher.find($0, in: sc) }.max { $0.score < $1.score }
        return m.map { TemplateMatcher.Match(rect: $0.rect.offsetBy(dx: offset.x, dy: offset.y), score: $0.score) }
    }

    /// The words, if they're on screen (window coordinates). The whole window is read and only words inside the
    /// search area count: text recognition misreads tight crops (a big “31” came back as “LE”).
    func matchText(in px: ScreenReader.WindowPixels) -> TemplateMatcher.Match? {
        guard let text, !text.isEmpty else { return nil }
        return TextFinder.find(text, in: TextFinder.read(px), area: scaledArea(for: CGSize(width: px.width, height: px.height)))
            .map { TemplateMatcher.Match(rect: pictureFrame(forWords: $0), score: 1) }
    }

    /// Where the picture would be, given where its words were found (window coordinates); the words' own rect
    /// when it isn't known where they sit in the picture.
    func pictureFrame(forWords r: CGRect) -> CGRect {
        guard let w = wordsInPicture, w.width > 0.01, w.height > 0.01 else { return r }
        let width = r.width / w.width, height = r.height / w.height
        return CGRect(x: r.minX - w.minX * width, y: r.minY - w.minY * height, width: width, height: height)
    }

    /// Where `text` is inside a picture, as fractions of it (read once per picture and text, then remembered).
    static func wordsRect(_ text: String, inPicture png: Data) -> CGRect? {
        let key = "\(png.count):\(png.hashValue):\(text)"
        if let hit = wordsCache.lock.withLock({ wordsCache.rects[key] }) { return hit }
        var rect: CGRect?
        if let image = NSImage(data: png), let px = ScreenReader.WindowPixels(image: image), px.width > 0, px.height > 0,
           let r = TextFinder.find(text, in: TextFinder.read(px), area: nil) {
            rect = CGRect(x: r.minX / CGFloat(px.width), y: r.minY / CGFloat(px.height),
                          width: r.width / CGFloat(px.width), height: r.height / CGFloat(px.height))
        }
        wordsCache.lock.withLock { wordsCache.rects[key] = rect }
        return rect
    }

    private final class WordsCache: @unchecked Sendable {
        let lock = NSLock()
        var rects: [String: CGRect?] = [:]
    }
    private static let wordsCache = WordsCache()

    /// The biggest whole number read inside the search area (“x35”, “1,250” and “Lv. 31” all count).
    func largestNumber(in px: ScreenReader.WindowPixels) -> Int? {
        Self.largestNumber(in: TextFinder.read(px), area: scaledArea(for: CGSize(width: px.width, height: px.height)))
    }

    static func largestNumber(in lines: [TextFinder.Line], area: CGRect?) -> Int? {
        var best: Int?
        for l in lines where area.map({ $0.contains(CGPoint(x: l.rect.midX, y: l.rect.midY)) }) ?? true {
            for n in numbers(in: l.text) where n < 1_000_000_000 { best = max(best ?? n, n) }
        }
        return best
    }

    /// The whole numbers a person would read in `text`: “x1,250” is 1250, “30/50” is 30 (progress, not the
    /// goal), “1.5k” is 1500, “12.5” is 12, and full-width digits count too.
    static func numbers(in text: String) -> [Int] {
        var t = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        // “30 / 50”, “HP 120/500”: the part after the slash is a maximum, not a value that has been reached.
        t = t.replacingOccurrences(of: #"(\d)\s*/\s*[\d,]+"#, with: "$1", options: .regularExpression)
        var out: [Int] = []
        let pattern = #"\d{1,3}(?:,\d{3})+(?!\d)|\d++(?:\.\d++)?\s?[kKmM]?(?![A-Za-z])|\d+"#
        let re = try! NSRegularExpression(pattern: pattern)
        for m in re.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
            guard let r = Range(m.range, in: t) else { continue }
            var part = String(t[r]).replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
            var scale = 1.0
            if let last = part.last, "kKmM".contains(last) {
                scale = "kK".contains(last) ? 1_000 : 1_000_000
                part = String(part.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            guard let v = Double(part) else { continue }
            let n = (v * scale).rounded(.down)
            if n < 1e15 { out.append(Int(n)) }
        }
        return out
    }

    /// The picture, if it's on screen and meets the strictness.
    func locatePicture(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil) -> CGRect? {
        guard let m = matchPicture(in: px, scene: scene), m.score >= strictness else { return nil }
        return m.rect
    }

    /// Where it is, if it's on screen right now: the picture first (fast), then the words.
    /// `readText: false` skips the (slow) word reading this time.
    func locate(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil, readText: Bool = true) -> CGRect? {
        if let r = locatePicture(in: px, scene: scene) { return r }
        return readText ? matchText(in: px)?.rect : nil
    }

    /// For Test Now: a picture that meets the strictness, else the words, else the closest picture.
    func find(in px: ScreenReader.WindowPixels, scene: TemplateMatcher.Scene? = nil) -> TemplateMatcher.Match? {
        let picture = matchPicture(in: px, scene: scene)
        if let p = picture, p.score >= strictness { return p }
        if let t = matchText(in: px) { return t }
        return picture
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
                  let range = wholeWordRange(of: query, in: candidate.string)
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
        guard !q.isEmpty else { return nil }
        if let l = lines.first(where: { $0.text.trimmingCharacters(in: .whitespaces).compare(q, options: opts) == .orderedSame && inArea($0.rect) }) {
            return l.rect
        }
        for l in lines {
            if let w = l.words.first(where: { $0.text.compare(q, options: opts) == .orderedSame && inArea($0.rect) }) { return w.rect }
        }
        // Part of a longer line, for phrases only: a single character like “1” would otherwise match any number
        // containing it (a score, a counter, “Turn 1”…).
        guard q.count >= 3 else { return nil }
        return lines.first { wholeWordRange(of: q, in: $0.text) != nil && inArea($0.rect) }?.rect
    }

    /// Where `query` is in `text` as whole words: “Claim” is in “Claim all” but not in “Claimed”.
    /// Only checked at Latin letters and digits, so scripts written without spaces still match inside a line.
    static func wholeWordRange(of query: String, in text: String) -> Range<String.Index>? {
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func wordy(_ c: Character?) -> Bool { c.map { $0.isASCII && ($0.isLetter || $0.isNumber) } ?? false }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var from = text.startIndex
        while let r = text.range(of: q, options: opts, range: from..<text.endIndex) {
            let before = r.lowerBound > text.startIndex ? text[text.index(before: r.lowerBound)] : nil
            let after = r.upperBound < text.endIndex ? text[r.upperBound] : nil
            let startOK = !(wordy(q.first) && wordy(before))
            let endOK = !(wordy(q.last) && wordy(after))
            if startOK && endOK { return r }
            from = text.index(after: r.lowerBound)
        }
        return nil
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
