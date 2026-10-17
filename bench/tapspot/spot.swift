// Tap-spot safety: where does a blind “tap when stuck” land? The old rule taps one fixed spot the macro's owner
// picked; the new rule (StuckGuard.safeSpot) taps there only when it's empty space, otherwise the nearest empty
// spot, or not at all. Nothing in it knows any app or game.
//
// Two sets:
//   synthetic  generated screens with known control boxes (text buttons, tab bars, icon-only buttons, dialogs)
//              on plain, textured and blurred-real backgrounds, phone and desktop sizes. Ground truth is exact.
//              The edge threshold is fitted on seed 1 and reported on seed 2 (held out).
//   real       the labelled stuck screens (bench/unstuck/data, local), each with its macro's own stuck-tap spot.
//              No control boxes exist for these, so it reports what can be checked: taps on text, on the
//              shop's never-tap candidates, and whether “tap anywhere” screens still get a tap.
// Metrics with 95% Wilson intervals; results go to bench/tapspot/results/ with machine, OS and commit.
//   bench/tapspot/run.sh
import AppKit
import CoreImage

let data = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

func wilson(_ k: Int, _ n: Int) -> String {
    guard n > 0 else { return "–" }
    let z = 1.96, p = Double(k) / Double(n), d = 1 + z * z / Double(n)
    let c = (p + z * z / (2 * Double(n))) / d
    let h = z * sqrt(p * (1 - p) / Double(n) + z * z / (4 * Double(n * n))) / d
    return String(format: "%5.1f%% [%4.1f–%4.1f] (%d/%d)", p * 100, max(0, c - h) * 100, min(1, c + h) * 100, k, n)
}

struct RNG: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func d(_ a: Double, _ b: Double) -> Double { Double.random(in: a..<b, using: &self) }
    mutating func i(_ a: Int, _ b: Int) -> Int { Int.random(in: a...b, using: &self) }
}

func pixels(_ cg: CGImage) -> ScreenReader.WindowPixels {
    let w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ScreenReader.WindowPixels(rgba: rgba, width: w, height: h)
}

// MARK: Synthetic screens

let realScreens: [CGImage] = ((try? FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("screens").path)) ?? [])
    .filter { $0.hasSuffix(".png") }.sorted()
    .compactMap { NSImage(contentsOf: data.appendingPathComponent("screens").appendingPathComponent($0))?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
let ci = CIContext()
let blurred: [CGImage] = realScreens.enumerated().filter { $0.offset % 4 == 0 }.compactMap { _, cg in
    let img = CIImage(cgImage: cg).clampedToExtent().applyingGaussianBlur(sigma: 14).cropped(to: CIImage(cgImage: cg).extent)
    return ci.createCGImage(img, from: img.extent)
}

struct Screen { let px: ScreenReader.WindowPixels; let controls: [CGRect]; let kind: String; let bg: String }
let words = ["OK", "Cancel", "Shop", "Settings", "Play", "Next", "Menu", "Back", "Store", "Buy", "Continue", "Close",
             "Home", "Profile", "Items", "Summon", "Quests", "Friends", "Retry", "Skip", "Claim", "Upgrade"]

func color(_ r: inout RNG, light: Bool? = nil) -> NSColor {
    let l = light ?? (r.d(0, 1) < 0.5)
    return NSColor(hue: r.d(0, 1), saturation: r.d(0.2, 0.9), brightness: l ? r.d(0.7, 1) : r.d(0.15, 0.5), alpha: 1)
}

func makeScreen(_ r: inout RNG) -> Screen {
    let phone = r.d(0, 1) < 0.6
    let W = phone ? 456.0 : Double([800, 1100, 1280][r.i(0, 2)]), H = phone ? 1002.0 : Double([600, 720, 800][r.i(0, 2)])
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    // Flip so y grows downward, like window coordinates.
    gc.cgContext.translateBy(x: 0, y: H); gc.cgContext.scaleBy(x: 1, y: -1)
    let bgKind = ["plain", "textured", "blurred real"][blurred.isEmpty ? r.i(0, 1) : r.i(0, 2)]
    switch bgKind {
    case "plain":
        NSGradient(starting: color(&r), ending: color(&r))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: r.d(0, 360))
    case "textured":
        NSGradient(starting: color(&r), ending: color(&r))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: r.d(0, 360))
        for _ in 0..<r.i(20, 60) { // soft blobs and stripes, like game art: busy but not controls
            color(&r).withAlphaComponent(r.d(0.05, 0.25)).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.d(-100, W), y: r.d(-100, H), width: r.d(40, 300), height: r.d(40, 300))).fill()
        }
    default:
        gc.cgContext.saveGState()
        gc.cgContext.translateBy(x: 0, y: H); gc.cgContext.scaleBy(x: 1, y: -1)
        gc.cgContext.draw(blurred[r.i(0, blurred.count - 1)], in: CGRect(x: 0, y: 0, width: W, height: H))
        gc.cgContext.restoreGState()
    }
    var controls: [CGRect] = []
    func label(_ s: String, in rect: CGRect, size: Double, color c: NSColor) {
        let attr: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: c]
        let str = NSAttributedString(string: s, attributes: attr)
        let sz = str.size()
        gc.cgContext.saveGState()
        // Text draws upright in the flipped context by flipping around its own baseline box.
        gc.cgContext.translateBy(x: rect.midX - sz.width / 2, y: rect.midY + sz.height / 2); gc.cgContext.scaleBy(x: 1, y: -1)
        str.draw(at: .zero)
        gc.cgContext.restoreGState()
    }
    func button(_ rect: CGRect, text: String?, icon: Bool) {
        let fill = color(&r)
        fill.setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: min(rect.height / 2, r.d(4, 16)), yRadius: min(rect.height / 2, r.d(4, 16)))
        path.fill()
        if r.d(0, 1) < 0.7 { color(&r, light: true).setStroke(); path.lineWidth = r.d(1, 3); path.stroke() }
        let ink: NSColor = fill.brightnessComponent > 0.6 ? .black : .white
        if icon {
            ink.setStroke()
            let c = CGPoint(x: rect.midX, y: text == nil ? rect.midY : rect.minY + rect.height * 0.38), s = min(rect.width, rect.height) * 0.22
            let g = NSBezierPath(); g.lineWidth = 2.5
            switch r.i(0, 2) {
            case 0: g.move(to: NSPoint(x: c.x - s, y: c.y - s)); g.line(to: NSPoint(x: c.x + s, y: c.y + s))
                g.move(to: NSPoint(x: c.x + s, y: c.y - s)); g.line(to: NSPoint(x: c.x - s, y: c.y + s))
            case 1: g.appendOval(in: NSRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
            default: g.move(to: NSPoint(x: c.x - s, y: c.y)); g.line(to: NSPoint(x: c.x + s, y: c.y))
                g.move(to: NSPoint(x: c.x, y: c.y - s)); g.line(to: NSPoint(x: c.x, y: c.y + s))
            }
            g.stroke()
        }
        if let text { label(text, in: icon ? CGRect(x: rect.minX, y: rect.minY + rect.height * 0.55, width: rect.width, height: rect.height * 0.4) : rect,
                            size: icon ? 10 : min(20, rect.height * 0.45), color: ink) }
        controls.append(rect)
    }
    let kind = ["menu", "tab bar", "dialog", "tap to continue", "icons"][r.i(0, 4)]
    // A tab bar along the bottom on most screens (the shop-tab case), icon + label or icon only.
    if kind == "tab bar" || r.d(0, 1) < 0.5 {
        let n = r.i(3, 5), h = r.d(48, 72), w = W / Double(n), iconOnly = r.d(0, 1) < 0.3
        for k in 0..<n { button(CGRect(x: Double(k) * w + 3, y: H - h - 4, width: w - 6, height: h), text: iconOnly ? nil : words.randomElement(using: &r), icon: true) }
    }
    switch kind {
    case "menu":
        for k in 0..<r.i(3, 7) {
            button(CGRect(x: W * 0.15, y: H * 0.15 + Double(k) * r.d(60, 90), width: W * 0.7, height: r.d(40, 56)), text: words.randomElement(using: &r), icon: false)
        }
    case "dialog":
        let d = CGRect(x: W * 0.1, y: H * 0.3, width: W * 0.8, height: H * 0.3)
        color(&r).setFill(); NSBezierPath(roundedRect: d, xRadius: 12, yRadius: 12).fill()
        label(["Are you sure?", "Reward received", "Level up!", "Connection lost"].randomElement(using: &r)!,
              in: CGRect(x: d.minX, y: d.minY + 20, width: d.width, height: 30), size: 18, color: .white)
        button(CGRect(x: d.minX + 20, y: d.maxY - 70, width: d.width / 2 - 30, height: 46), text: "Cancel", icon: false)
        button(CGRect(x: d.midX + 10, y: d.maxY - 70, width: d.width / 2 - 30, height: 46), text: "OK", icon: false)
    case "tap to continue":
        label(["Tap to continue", "TAP SCREEN", "Touch to start"].randomElement(using: &r)!,
              in: CGRect(x: 0, y: H * r.d(0.6, 0.8), width: W, height: 30), size: 22, color: .white)
    default:
        for _ in 0..<r.i(3, 8) {
            let s = r.d(28, 52)
            button(CGRect(x: r.d(4, W - s - 4), y: r.d(4, H - s - 80), width: s, height: s), text: nil, icon: true)
        }
    }
    // Corner buttons (close, settings) on many screens: icon only, no text to read.
    if r.d(0, 1) < 0.5 { button(CGRect(x: W - 52, y: 12, width: 40, height: 40), text: nil, icon: true) }
    NSGraphicsContext.restoreGraphicsState()
    return Screen(px: pixels(rep.cgImage!), controls: controls, kind: kind, bg: bgKind)
}

func onControl(_ p: CGPoint, _ s: Screen) -> Bool { s.controls.contains { $0.insetBy(dx: -2, dy: -2).contains(p) } }

func synthetic(seed: UInt64, n: Int) -> [(Screen, [TextFinder.Line], CGPoint)] {
    var r = RNG(s: seed)
    return (0..<n).map { _ in
        let s = makeScreen(&r)
        // The stuck-tap spot: anywhere on the window (an owner picks it on one screen; on others it lands anywhere).
        let p = CGPoint(x: r.d(20, Double(s.px.width) - 20), y: r.d(20, Double(s.px.height) - 20))
        return (s, TextFinder.read(s.px), p)
    }
}

func score(_ set: [(Screen, [TextFinder.Line], CGPoint)], rule: StuckGuard.SpotRule?) -> (hits: Int, taps: Int, abstain: Int, n: Int, perKind: [String: (Int, Int)]) {
    var hits = 0, taps = 0, abstain = 0
    var perKind: [String: (Int, Int)] = [:]
    for (s, lines, p) in set {
        let spot = rule.map { StuckGuard.safeSpot(s.px, lines: lines, preferred: p, rule: $0) } ?? p
        guard let spot else { abstain += 1; continue }
        taps += 1
        let hit = onControl(spot, s)
        if hit { hits += 1 }
        let k = "\(s.kind) / \(s.bg)"
        perKind[k, default: (0, 0)].0 += hit ? 1 : 0
        perKind[k, default: (0, 0)].1 += 1
    }
    return (hits, taps, abstain, set.count, perKind)
}

var out = ""
func say(_ s: String) { print(s); out += s + "\n" }

let n = Int(ProcessInfo.processInfo.environment["N"] ?? "400")!
say("Tap-spot safety  \(Date())")
let t0 = Date()
let fit = synthetic(seed: 0x5EED_0001, n: n)
if let dump = ProcessInfo.processInfo.environment["DUMP"] {
    for (k, (s, lines, p)) in fit.filter({ s in StuckGuard.safeSpot(s.0.px, lines: s.1, preferred: s.2).map { onControl($0, s.0) } ?? false }).prefix(6).enumerated() {
        let spot = StuckGuard.safeSpot(s.px, lines: lines, preferred: p)
        var buf = s.px.rgba
        let pw = s.px.width, ph = s.px.height
        func dot(_ q: CGPoint, _ c: [UInt8]) {
            for dy in -5...5 { for dx in -5...5 { let x = Int(q.x) + dx, y = Int(q.y) + dy
                if x >= 0, y >= 0, x < pw, y < ph { for j in 0..<3 { buf[(y * pw + x) * 4 + j] = c[j] } } } }
        }
        func box(_ r: CGRect, _ c: [UInt8]) {
            for x in Int(r.minX)..<Int(r.maxX) { for y in [Int(r.minY), Int(r.maxY) - 1] where x >= 0 && y >= 0 && x < pw && y < ph { for j in 0..<3 { buf[(y * pw + x) * 4 + j] = c[j] } } }
            for y in Int(r.minY)..<Int(r.maxY) { for x in [Int(r.minX), Int(r.maxX) - 1] where x >= 0 && y >= 0 && x < pw && y < ph { for j in 0..<3 { buf[(y * pw + x) * 4 + j] = c[j] } } }
        }
        s.controls.forEach { box($0, [255, 0, 255]) }
        lines.forEach { box($0.rect, [0, 255, 0]) }
        dot(p, [255, 0, 0]); if let spot { dot(spot, [0, 128, 255]) }
        try! NSBitmapImageRep(cgImage: ScreenReader.WindowPixels(rgba: buf, width: pw, height: ph).cgImage!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dump)/s\(k).png"))
        print(k, s.kind, s.bg, "lines", lines.count, "controls", s.controls.count, "p", p, "spot", spot as Any)
    }
    exit(0)
}
let test = synthetic(seed: 0x5EED_0002, n: n)
say(String(format: "synthetic: %d fit + %d held-out screens (%.0f s to render and read)", n, n, Date().timeIntervalSince(t0)))

// Fit the thresholds on seed 1: fewest taps on controls, with not tapping counted as half as bad as a hit
// (no tap can leave a run stuck, but tapping a control can spend or wander off).
func rule(_ e: Double, _ within: Double, _ hard: Double, _ closes: Bool = true) -> StuckGuard.SpotRule {
    var r = StuckGuard.SpotRule(); r.edgeLimit = e; r.enclosedWithin = within; r.hardEdge = hard; r.windowEdgeCloses = closes; return r
}
var best = (cost: Double.infinity, rule: StuckGuard.SpotRule.standard, label: "")
say("\nfit (seed 1): edge limit, enclosed within, hard edge → taps on a control, no tap")
for e in [0.04, 0.06, 1.0] {
    for within in [0.0, 60, 90, 140] {
        for hard in within == 0 ? [0.18] : [0.06, 0.10, 0.18] {
          for closes in within == 0 ? [true] : [true, false] {
            let r = rule(e, within, hard, closes)
            let s = score(fit, rule: r)
            let cost = Double(s.hits) + 0.5 * Double(s.abstain)
            let label = String(format: "edges %@  enclosed %@", e >= 1 ? "off " : String(format: "%.2f", e),
                               within == 0 ? "off               " : String(format: "%3.0f pt, %.2f%@", within, hard, closes ? ", win" : "     "))
            say("  \(label)   on control \(wilson(s.hits, s.taps))   no tap \(wilson(s.abstain, s.n))")
            if cost < best.cost { best = (cost, r, label) }
          }
        }
    }
}
say("chosen: \(best.label)")
let st = StuckGuard.SpotRule.standard
say(String(format: "in the app: edges %.2f, enclosed %.0f pt, %.2f", st.edgeLimit, st.enclosedWithin, st.hardEdge))

say("\nheld out (seed 2): taps that land on a control")
let fixed = score(test, rule: nil)
let tOnly = score(test, rule: rule(1, 0, 0.18))
let ch = score(test, rule: best.rule)
let std = score(test, rule: .standard)
say("  fixed spot (today)        \(wilson(fixed.hits, fixed.taps))")
say("  empty space, text only    \(wilson(tOnly.hits, tOnly.taps))   no tap \(wilson(tOnly.abstain, tOnly.n))")
say("  fitted on seed 1          \(wilson(ch.hits, ch.taps))   no tap \(wilson(ch.abstain, ch.n))")
say("  as shipped (standard)     \(wilson(std.hits, std.taps))   no tap \(wilson(std.abstain, std.n))")
say("\n  by screen (fixed → shipped rule, taps on a control):")
for k in fixed.perKind.keys.sorted() {
    let f = fixed.perKind[k]!, s = std.perKind[k] ?? (0, 0)
    say("    \(k.padding(toLength: 34, withPad: " ", startingAt: 0)) \(f.0)/\(f.1) → \(s.0)/\(s.1)")
}

// MARK: Real stuck screens

say("\nreal stuck screens (bench/unstuck/data)")
let labels = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("labels.json")))) as? [String: Any])?["labels"] as? [String: [String: Any]] ?? [:]
let cands = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("candidates.json")))) as? [[String: Any]]) ?? []
var candBoxes: [String: [Int: CGRect]] = [:]
for c in cands {
    guard let f = c["file"] as? String, let list = c["candidates"] as? [[String: Any]] else { continue }
    for x in list { if let id = x["id"] as? Int, let b = x["box"] as? [Double] { candBoxes[f, default: [:]][id] = CGRect(x: b[0], y: b[1], width: b[2], height: b[3]) } }
}
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
var macros: [String: Macro] = [:]
for f in (try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("macros").path)) where f.hasSuffix(".json") {
    if let m = Lenient.decode(try Data(contentsOf: data.appendingPathComponent("macros").appendingPathComponent(f)), defaults: Macro(name: "", steps: []), encoder: enc, decoder: dec) {
        macros[String(m.id.uuidString.prefix(8))] = m
    }
}
var onText = (fixed: 0, rule: 0), tapped = (fixed: 0, rule: 0), total = 0
var unsafeHits = (fixed: 0, rule: 0, n: 0), anywhere = (got: 0, n: 0), moved = 0
for (file, label) in labels.sorted(by: { $0.key < $1.key }) {
    guard let m = macros[String(file.prefix(8))], let ix = m.playback.idleTapX, let iy = m.playback.idleTapY,
          let cg = NSImage(contentsOf: data.appendingPathComponent("screens").appendingPathComponent(file))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { continue }
    let px = pixels(cg), lines = TextFinder.read(px)
    let p = m.target.fit(for: CGSize(width: px.width, height: px.height)).point(CGPoint(x: ix, y: iy))
    let spot = StuckGuard.safeSpot(px, lines: lines, preferred: p)
    total += 1
    if let dump = ProcessInfo.processInfo.environment["DUMPREAL"], spot != p {
        var buf = px.rgba
        func dot(_ q: CGPoint, _ c: [UInt8]) {
            for dy in -6...6 { for dx in -6...6 { let x = Int(q.x) + dx, y = Int(q.y) + dy
                if x >= 0, y >= 0, x < px.width, y < px.height { for j in 0..<3 { buf[(y * px.width + x) * 4 + j] = c[j] } } } }
        }
        dot(p, [255, 0, 0]); if let spot { dot(spot, [0, 160, 255]) }
        try? NSBitmapImageRep(cgImage: ScreenReader.WindowPixels(rgba: buf, width: px.width, height: px.height).cgImage!)
            .representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dump)/\(file)"))
        print("moved", file, p, "→", spot as Any, label["action"] as Any)
    }
    func textAt(_ q: CGPoint) -> Bool { lines.contains { $0.rect.insetBy(dx: -4, dy: -4).contains(q) } }
    tapped.fixed += 1; if textAt(p) { onText.fixed += 1 }
    if let spot { tapped.rule += 1; if textAt(spot) { onText.rule += 1 }; if spot != p { moved += 1 } }
    if label["action"] as? String == "none", let unsafe = label["unsafe"] as? [Int] {
        unsafeHits.n += 1
        let boxes = unsafe.compactMap { candBoxes[file]?[$0] }.map { $0.insetBy(dx: -6, dy: -6) }
        if boxes.contains(where: { $0.contains(p) }) { unsafeHits.fixed += 1 }
        if let spot, boxes.contains(where: { $0.contains(spot) }) { unsafeHits.rule += 1 }
    }
    if label["action"] as? String == "anywhere" { anywhere.n += 1; if spot != nil { anywhere.got += 1 } }
}
say("  screens with a stuck-tap spot: \(total)")
say("  tap on text:        fixed \(wilson(onText.fixed, tapped.fixed))   rule \(wilson(onText.rule, tapped.rule))")
say("  rule moved the tap: \(wilson(moved, total)); no tap: \(wilson(total - tapped.rule, total))")
say("  shop screens, tap on a never-tap button: fixed \(unsafeHits.fixed)/\(unsafeHits.n), rule \(unsafeHits.rule)/\(unsafeHits.n)")
say("  “tap anywhere” screens that still get a tap: \(anywhere.got)/\(anywhere.n)")

// Extra real screens given on the command line (folders of PNGs with a spot), e.g. the live stuck screens.
if CommandLine.arguments.count > 4 {
    let dir = URL(fileURLWithPath: CommandLine.arguments[3])
    let spot = CommandLine.arguments[4].split(separator: ",").compactMap { Double($0) }
    let ref = CGSize(width: spot[2], height: spot[3])
    say("\nlive stuck screens in \(dir.lastPathComponent) (spot \(Int(spot[0])),\(Int(spot[1])) on a \(Int(ref.width))×\(Int(ref.height)) window)")
    for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasSuffix(".png") }).sorted().suffix(12) {
        guard let cg = NSImage(contentsOf: dir.appendingPathComponent(f))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let px = pixels(cg), lines = TextFinder.read(px)
        let p = CGPoint(x: spot[0] * Double(px.width) / ref.width, y: spot[1] * Double(px.height) / ref.height)
        let under = lines.first { $0.rect.insetBy(dx: -4, dy: -4).contains(p) }?.text
        let s = StuckGuard.safeSpot(px, lines: lines, preferred: p)
        if let dump = ProcessInfo.processInfo.environment["DUMPLIVE"] {
            var buf = px.rgba
            func dot(_ q: CGPoint, _ c: [UInt8]) {
                for dy in -6...6 { for dx in -6...6 { let x = Int(q.x) + dx, y = Int(q.y) + dy
                    if x >= 0, y >= 0, x < px.width, y < px.height { for j in 0..<3 { buf[(y * px.width + x) * 4 + j] = c[j] } } } }
            }
            dot(p, [255, 0, 0]); if let s { dot(s, [0, 160, 255]) }
            try? NSBitmapImageRep(cgImage: ScreenReader.WindowPixels(rgba: buf, width: px.width, height: px.height).cgImage!)
                .representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(dump)/\(f)"))
        }
        say("  \(f.suffix(30))  fixed on \(under.map { "“\($0)”" } ?? "no text")  →  \(s.map { $0 == p ? "same spot" : "moved to \(Int($0.x)),\(Int($0.y))" } ?? "no tap")")
    }
}

let host = Host.current().localizedName ?? "?"
let commit = (try? String(contentsOfFile: ".git/HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
out += "\nmachine: \(host), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(commit)\n"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
try! out.write(to: outDir.appendingPathComponent("tapspot-\(stamp).txt"), atomically: true, encoding: .utf8)
