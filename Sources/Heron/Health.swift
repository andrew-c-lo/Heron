import AppKit

/// Checks a macro's picture steps for settings that can't work as saved, before a run finds out the hard way.
/// The strictness check is calibration: each step's picture is put on real screens from this macro (at its own
/// spot, at a few window sizes) to see how high a real copy scores, and the same screens without it show how high
/// a look-alike scores. A strictness above the real copies misses them; one near the look-alikes risks clicking
/// the wrong thing. (The same method as bench/resize, where it's measured.)
struct HealthIssue: Identifiable {
    enum Kind { case tooStrict, tooLoose, unreliableSize, areaMissesPicture, otherShape }
    enum Fix { case strictness(Double), showStep }
    let id = UUID()
    let step: UUID
    let number: Int
    let kind: Kind
    let title: String
    let detail: String
    let fix: Fix
}

enum MacroHealth {
    static let scales = [0.85, 1.0, 1.2]

    /// `backgrounds`: real screens from this macro's app (stuck screens, a capture of the window now).
    /// `window`: the target window's size now, if it's open.
    static func check(_ m: Macro, backgrounds: [ScreenReader.WindowPixels], window: CGSize?,
                      progress: (Double) -> Void = { _ in }) -> [HealthIssue] {
        var issues: [HealthIssue] = []
        let emulator = m.target.isAndroidEmulator
        let pictureSteps = m.steps.enumerated().filter { _, s in
            if case .findImage(let p) = s.action { return s.enabled && !p.png.isEmpty && p.width >= 8 && p.height >= 8 }
            return false
        }
        for (done, (i, s)) in pictureSteps.enumerated() {
            progress(Double(done) / Double(max(1, pictureSteps.count)))
            guard case .findImage(var p) = s.action else { continue }
            let n = i + 1
            if p.pictureSizeUnreliable(fallback: m.target.windowSize) {
                issues.append(HealthIssue(step: s.id, number: n, kind: .unreliableSize, title: "Step \(n): picked in a window of unknown size",
                    detail: "Its saved window size can't be right (the picture sits past its edge), so Heron has to guess how to resize it. Pick the picture again.",
                    fix: .showStep))
                continue
            }
            guard let ref = p.reference(fallback: m.target.windowSize) else { continue }
            let picked = CGRect(x: p.originX, y: p.originY, width: p.width, height: p.height)
            if let area = p.area, let aref = p.areaReference(fallback: m.target.windowSize) {
                let a = WindowFit.between(aref, ref, emulator: emulator).rect(area)
                if a.intersection(picked).isNull || a.intersection(picked).width * a.intersection(picked).height < picked.width * picked.height * 0.5 {
                    issues.append(HealthIssue(step: s.id, number: n, kind: .areaMissesPicture, title: "Step \(n): its search area is somewhere else",
                        detail: "The picture was picked outside the area it's looked for in. Fine if it shows up inside the area too; otherwise draw the area again.",
                        fix: .showStep))
                }
            }
            if let w = window, w.width > 0, ref.width > 0 {
                let shapeNow = w.height / w.width, shapeThen = ref.height / ref.width
                if abs(shapeNow - shapeThen) / shapeThen > 0.12 {
                    issues.append(HealthIssue(step: s.id, number: n, kind: .otherShape, title: "Step \(n): picked in a differently shaped window",
                        detail: String(format: "It was picked in a %d × %d window; the %@ window is %d × %d now. If it was picked in another app or on another device, positions and its area may not line up: pick it again here.",
                                       Int(ref.width), Int(ref.height), m.target.app?.name ?? "target", Int(w.width), Int(w.height)),
                        fix: .showStep))
                }
            }
            // Calibration needs screens to try it on.
            guard backgrounds.count >= 2, let pic = NSImage(data: p.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            p.text = nil; p.alsoPicture = false
            guard let lookup = Lookup(step: p, reference: ref, emulator: emulator) else { continue }
            var spot = picked
            if let area = p.area, let aref = p.areaReference(fallback: m.target.windowSize) {
                let a = WindowFit.between(aref, ref, emulator: emulator).rect(area)
                if !a.contains(spot), a.width >= spot.width, a.height >= spot.height {
                    spot.origin = CGPoint(x: a.midX - spot.width / 2, y: a.midY - spot.height / 2)
                }
            }
            var positives: [Double] = [], negatives: [Double] = []
            for bg in backgrounds {
                guard let bgImage = bg.cgImage else { continue }
                let plain = render(bgImage, at: ref, emulator: emulator, picture: nil)
                if lookup.locatePicture(in: pixels(plain)) != nil { continue } // already on this screen: not a fair negative
                let with = render(bgImage, at: ref, emulator: emulator, picture: (pic, spot))
                for k in scales {
                    let (img, size) = resize(with, ref, k, emulator: emulator)
                    let expected = WindowFit.between(ref, size, emulator: emulator).rect(spot)
                    if let r = lookup.matchPicture(in: pixels(img)), overlap(r.rect, expected) >= 0.5 { positives.append(r.score) } else { positives.append(0) }
                    let (neg, _) = resize(plain, ref, k, emulator: emulator)
                    negatives.append(lookup.matchPicture(in: pixels(neg))?.score ?? 0)
                }
            }
            guard positives.count >= 6 else { continue }
            let sorted = positives.sorted(), p10 = sorted[Int(Double(sorted.count - 1) * 0.1)]
            let negMax = negatives.max() ?? 0
            let misses = Double(positives.filter { $0 < lookup.strictness }.count) / Double(positives.count)
            let percent = { (v: Double) in "\(Int((v * 100).rounded()))%" }
            if misses > 0.1, p10 - negMax >= 0.1 {
                // The smallest change that catches real copies: just under the worst of them, while staying well
                // clear of the look-alikes.
                let suggested = max(0.5, min(lookup.strictness - 0.01, (max(negMax + 0.1, p10 - 0.05) * 100).rounded() / 100))
                issues.append(HealthIssue(step: s.id, number: n, kind: .tooStrict, title: "Step \(n): stricter than its own picture can meet",
                    detail: "Needs a \(percent(lookup.strictness)) match, but the real thing scores as low as \(percent(p10)) once it's captured and resized, so it was missed \(percent(misses)) of the time. Look-alikes never scored above \(percent(negMax)): \(percent(suggested)) is still safe.",
                    fix: .strictness(suggested)))
            } else if negMax >= lookup.strictness - 0.05, p10 > negMax + 0.04 {
                let suggested = min(0.98, ((negMax + p10) / 2 * 100).rounded() / 100)
                issues.append(HealthIssue(step: s.id, number: n, kind: .tooLoose, title: "Step \(n): look-alikes come close",
                    detail: "Needs \(percent(lookup.strictness)), and something else on these screens scored \(percent(negMax)), so it could click the wrong thing. The real thing scores at least \(percent(p10)): \(percent(suggested)) keeps it and rules the look-alike out.",
                    fix: .strictness(suggested)))
            }
        }
        progress(1)
        return grouped(issues).sorted { ($0.number, $0.title) < ($1.number, $1.title) }
    }

    /// The same problem on many steps (a macro moved to another app: every picture was picked in a differently
    /// shaped window) reads as one entry naming the steps, not a wall of repeats.
    static func grouped(_ issues: [HealthIssue]) -> [HealthIssue] {
        var out = issues.filter { $0.kind != .otherShape && $0.kind != .unreliableSize && $0.kind != .areaMissesPicture }
        for kind in [HealthIssue.Kind.otherShape, .unreliableSize, .areaMissesPicture] {
            let same = issues.filter { $0.kind == kind }
            guard same.count >= 3, let first = same.first else { out += same; continue }
            let list = steps(same.map(\.number))
            let (title, detail): (String, String) = {
                switch kind {
                case .otherShape:
                    return ("\(same.count) steps were picked in a differently shaped window",
                            "Steps \(list). If this macro was made in another app or on another device, their positions and areas may not line up here. Pick those pictures again in this window.")
                case .unreliableSize:
                    return ("\(same.count) steps were picked in a window of unknown size",
                            "Steps \(list): their saved window size can't be right, so Heron guesses how to resize them. Pick those pictures again.")
                default:
                    return ("\(same.count) steps look for their picture somewhere else",
                            "Steps \(list): each picture was picked outside the area it's looked for in. Fine if it shows up inside its area too; otherwise draw the areas again.")
                }
            }()
            out.append(HealthIssue(step: first.step, number: first.number, kind: kind, title: title, detail: detail, fix: .showStep))
        }
        return out
    }

    /// "1–6, 9, 12".
    static func steps(_ n: [Int]) -> String {
        let s = n.sorted()
        var parts: [String] = []
        var i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count, s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(j - i >= 2 ? "\(s[i])–\(s[j])" : (i...j).map { "\(s[$0])" }.joined(separator: ", "))
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Rendering (top-left coordinates)

    private static func context(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        return c
    }

    private static func draw(_ img: CGImage, _ r: CGRect, in c: CGContext, height: Double) {
        c.draw(img, in: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
    }

    /// A screen at the size the picture was picked at (the Android screen inside BlueStacks' frame for an
    /// emulator), with the picture at `picture`'s spot if given.
    static func render(_ bg: CGImage, at ref: CGSize, emulator: Bool, picture: (CGImage, CGRect)?) -> CGImage {
        let h = Double(Int(ref.height.rounded()))
        let c = context(Int(ref.width.rounded()), Int(h))
        let content = emulator ? (WindowFit.androidScreen(in: ref) ?? CGRect(origin: .zero, size: ref)) : CGRect(origin: .zero, size: ref)
        draw(bg, content, in: c, height: h)
        if let (pic, r) = picture { draw(pic, r, in: c, height: h) }
        return c.makeImage()!
    }

    /// The window resized by `k`: its whole picture scaled, or for an emulator only its Android screen.
    static func resize(_ img: CGImage, _ ref: CGSize, _ k: Double, emulator: Bool) -> (CGImage, CGSize) {
        if emulator, let a = WindowFit.androidScreen(in: ref) {
            let height = (ref.height * k).rounded()
            let size = CGSize(width: ((height - 32) * a.width / a.height).rounded(), height: height)
            let b = WindowFit.androidScreen(in: size) ?? CGRect(origin: .zero, size: size)
            let c = context(Int(size.width), Int(size.height))
            if let part = img.cropping(to: a.integral) { draw(part, b, in: c, height: Double(size.height)) }
            return (c.makeImage()!, size)
        }
        let size = CGSize(width: (ref.width * k).rounded(), height: (ref.height * k).rounded())
        let c = context(Int(size.width), Int(size.height))
        draw(img, CGRect(origin: .zero, size: size), in: c, height: Double(size.height))
        return (c.makeImage()!, size)
    }

    static func pixels(_ img: CGImage) -> ScreenReader.WindowPixels {
        ScreenReader.WindowPixels(rgba: TemplateMatcher.rgba(img, width: img.width, height: img.height) ?? [], width: img.width, height: img.height)
    }

    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b); guard !i.isNull else { return 0 }
        return Double(i.width * i.height) / Double(a.width * a.height + b.width * b.height - i.width * i.height)
    }
}
