// Resize stress test: does every picture step still get found, in the right place, when the window is a
// different size? Real backgrounds and the macros' own pictures (bench/unstuck/data, local), rendered at
// 70–140% of the size each picture was picked at, in two layouts:
//   plain      the whole window scales (iPhone Mirroring, most apps)
//   bluestacks a fixed 32 pt top bar, the Android screen scaling, and a 32 pt sidebar shown or collapsed
// Metrics per slice, with 95% Wilson intervals: found (meets its strictness), placed (found where it really
// is: overlap ≥ 50%), false alarm (found on the same background with nothing planted, where it wasn't found
// at the original size). Results go to bench/resize/results/ with the machine, OS and commit.
//   bench/resize/run.sh
import AppKit

let data = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])
let scales = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.4]
let bar = 32.0, sidebarWidth = 32.0

// The macros' picture steps.
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
var steps: [(macro: String, index: Int, step: ImageStep, reference: CGSize)] = []
var unreliable = 0
for f in (try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("macros").path)).sorted() where f.hasSuffix(".json") {
    let d = try Data(contentsOf: data.appendingPathComponent("macros").appendingPathComponent(f))
    guard let m = Lenient.decode(d, defaults: Macro(name: "", steps: []), encoder: enc, decoder: dec) else { continue }
    for (i, s) in m.steps.enumerated() where s.enabled {
        guard case .findImage(var p) = s.action, !p.png.isEmpty, p.width >= 8, p.height >= 8 else { continue }
        p.text = nil; p.alsoPicture = false
        guard let ref = p.reference(fallback: m.target.windowSize) else { unreliable += 1; continue }
        steps.append((m.name, i + 1, p, ref))
    }
}

// Backgrounds: every 8th saved screen (a spread of screens from different moments).
let screenFiles = (try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("screens").path))
    .filter { $0.hasSuffix(".png") }.sorted().enumerated().filter { $0.offset % 8 == 0 }.map(\.element)
let backgrounds: [CGImage] = screenFiles.compactMap {
    NSImage(contentsOf: data.appendingPathComponent("screens").appendingPathComponent($0))?.cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func context(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}
/// Draws in top-left coordinates.
func draw(_ img: CGImage, _ r: CGRect, in c: CGContext, height: Double) {
    c.draw(img, in: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
}
func fill(_ r: CGRect, _ gray: Double, in c: CGContext, height: Double) {
    c.setFillColor(CGColor(gray: gray, alpha: 1)); c.fill(CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height))
}

enum Layout: String { case plain, bluestacks, bluestacksSidebar = "bluestacks+sidebar" }

/// The window at the size the picture was picked at, with the background in its content area and, optionally,
/// the picture at the spot it was picked from.
func referenceWindow(_ ref: CGSize, _ bg: CGImage, _ layout: Layout, picture: (CGImage, CGRect)?) -> CGImage {
    let w = Int(ref.width.rounded()), h = Int(ref.height.rounded())
    let c = context(w, h)
    if layout == .plain {
        draw(bg, CGRect(x: 0, y: 0, width: ref.width, height: ref.height), in: c, height: Double(h))
    } else {
        fill(CGRect(x: 0, y: 0, width: ref.width, height: ref.height), 0.18, in: c, height: Double(h))
        let a = WindowFit.androidScreen(in: ref) ?? CGRect(origin: .zero, size: ref)
        draw(bg, a, in: c, height: Double(h))
        fill(CGRect(x: 0, y: 0, width: ref.width, height: bar), 0.1, in: c, height: Double(h))
    }
    if let (pic, r) = picture { draw(pic, r, in: c, height: Double(h)) }
    return c.makeImage()!
}

/// The same window resized: its whole picture scaled (plain), or BlueStacks-style.
func resized(_ refImage: CGImage, _ ref: CGSize, _ k: Double, _ layout: Layout) -> (CGImage, CGSize) {
    if layout == .plain {
        let size = CGSize(width: (ref.width * k).rounded(), height: (ref.height * k).rounded())
        let c = context(Int(size.width), Int(size.height))
        draw(refImage, CGRect(origin: .zero, size: size), in: c, height: Double(size.height))
        return (c.makeImage()!, size)
    }
    let a = WindowFit.androidScreen(in: ref)!
    let height = (ref.height * k).rounded()
    let contentW = ((height - bar) * a.width / a.height).rounded()
    let size = CGSize(width: contentW + (layout == .bluestacksSidebar ? sidebarWidth : 0), height: height)
    let b = WindowFit.androidScreen(in: size)!
    let c = context(Int(size.width), Int(size.height))
    fill(CGRect(origin: .zero, size: size), 0.18, in: c, height: Double(size.height))
    // Only the Android screen scales.
    let content = refImage.cropping(to: CGRect(x: a.minX, y: a.minY, width: a.width, height: a.height).integral)!
    draw(content, b, in: c, height: Double(size.height))
    fill(CGRect(x: 0, y: 0, width: size.width, height: bar), 0.1, in: c, height: Double(size.height))
    return (c.makeImage()!, size)
}

func pixels(_ img: CGImage) -> ScreenReader.WindowPixels {
    ScreenReader.WindowPixels(rgba: TemplateMatcher.rgba(img, width: img.width, height: img.height)!, width: img.width, height: img.height)
}
func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let i = a.intersection(b); guard !i.isNull else { return 0 }
    return Double(i.width * i.height) / Double(a.width * a.height + b.width * b.height - i.width * i.height)
}
/// 95% Wilson interval.
func wilson(_ k: Int, _ n: Int) -> (Double, Double) {
    guard n > 0 else { return (0, 0) }
    let z = 1.96, p = Double(k) / Double(n), d = 1 + z * z / Double(n)
    let c = (p + z * z / (2 * Double(n))) / d, h = z * sqrt(p * (1 - p) / Double(n) + z * z / (4 * Double(n * n))) / d
    return (max(0, c - h), min(1, c + h))
}

struct Tally { var n = 0, found = 0, placed = 0, negatives = 0, falseAlarms = 0 }
var bySlice: [String: Tally] = [:]
var failures: [[String: Any]] = []
let t0 = Date()
var looks = 0

for st in steps {
    guard let pic = NSImage(data: st.step.png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let picked = CGRect(x: st.step.originX, y: st.step.originY, width: st.step.width, height: st.step.height)
    let short = min(st.step.width, st.step.height)
    let sizeBucket = short < 40 ? "small (<40 pt)" : short < 100 ? "medium" : "large (≥100 pt)"
    for layout in [Layout.plain, .bluestacks, .bluestacksSidebar] {
        let emulator = layout != .plain
        guard let lookup = Lookup(step: st.step, reference: st.reference, emulator: emulator) else { continue }
        // The picture belongs inside the step's search area (as this layout maps it): when the area was drawn
        // somewhere else than the picture was picked, put it there.
        var original = picked
        if let area = st.step.area, let aref = st.step.areaReference(fallback: st.reference) {
            let a = WindowFit.between(aref, st.reference, emulator: emulator).rect(area)
            if !a.contains(original), a.width >= original.width, a.height >= original.height {
                original.origin = CGPoint(x: a.midX - original.width / 2, y: a.midY - original.height / 2)
            }
        }
        for bg in backgrounds {
            let withPic = referenceWindow(st.reference, bg, layout, picture: (pic, original))
            let without = referenceWindow(st.reference, bg, layout, picture: nil)
            // Already there without planting (the same button is on this background): not a fair negative.
            let presentAtOriginal = lookup.locatePicture(in: pixels(without)) != nil
            for k in scales {
                let (img, size) = resized(withPic, st.reference, k, layout)
                let expected = WindowFit.between(st.reference, size, emulator: emulator).rect(original)
                let found = lookup.locatePicture(in: pixels(img))
                looks += 1
                let ok = found.map { iou($0, expected) >= 0.5 } ?? false
                for key in ["\(layout.rawValue) ×\(k)", "\(layout.rawValue) all", "size \(sizeBucket)"] {
                    var t = bySlice[key] ?? Tally()
                    t.n += 1; t.found += found == nil ? 0 : 1; t.placed += ok ? 1 : 0
                    if !presentAtOriginal {
                        let (neg, _) = resized(without, st.reference, k, layout)
                        if key.hasSuffix("all") || key.contains("×") {
                            t.negatives += 1
                            if lookup.locatePicture(in: pixels(neg)) != nil { t.falseAlarms += 1 }
                        }
                    }
                    bySlice[key] = t
                }
                if !ok, failures.count < 400 {
                    failures.append(["macro": st.macro, "step": st.index, "layout": layout.rawValue, "scale": k,
                                     "picture": [Int(st.step.width), Int(st.step.height)], "reference": [Int(st.reference.width), Int(st.reference.height)],
                                     "found": found.map { [Int($0.minX), Int($0.minY), Int($0.width), Int($0.height)] } as Any,
                                     "expected": [Int(expected.minX), Int(expected.minY), Int(expected.width), Int(expected.height)]])
                }
            }
        }
    }
}

func pct(_ k: Int, _ n: Int) -> String {
    let (lo, hi) = wilson(k, n)
    return n == 0 ? "   –" : String(format: "%3.0f%% (%2.0f–%3.0f)", Double(k) / Double(n) * 100, lo * 100, hi * 100)
}
print("\(steps.count) pictures (\(unreliable) skipped: saved size can't be right), \(backgrounds.count) backgrounds, \(looks) looks in \(Int(Date().timeIntervalSince(t0))) s")
print(String(format: "%-26@ %5@  %-17@ %-17@ %@", "slice" as NSString, "n" as NSString, "found" as NSString, "placed" as NSString, "false alarms" as NSString))
for key in bySlice.keys.sorted(by: { a, b in
    func order(_ s: String) -> (Int, String) { (s.hasPrefix("plain") ? 0 : s.hasPrefix("bluestacks+") ? 2 : s.hasPrefix("bluestacks") ? 1 : 3, s) }
    return order(a) < order(b) }) {
    let t = bySlice[key]!
    print(String(format: "%-26@ %5d  %-17@ %-17@ %@", key as NSString, t.n, pct(t.found, t.n) as NSString, pct(t.placed, t.n) as NSString,
                 (t.negatives == 0 ? "–" : pct(t.falseAlarms, t.negatives)) as NSString))
}

func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
let commit = sh("git rev-parse --short HEAD") + (sh("git status --porcelain Sources bench | head -1").isEmpty ? "" : "+dirty")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let file = outDir.appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()).prefix(10))-\(commit).local.json")
let slices = bySlice.mapValues { ["n": $0.n, "found": $0.found, "placed": $0.placed, "negatives": $0.negatives, "falseAlarms": $0.falseAlarms] }
try JSONSerialization.data(withJSONObject: ["meta": ["commit": commit, "machine": sh("sysctl -n machdep.cpu.brand_string"),
                                                     "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                                     "pictures": steps.count, "backgrounds": backgrounds.count, "scales": scales],
                                            "slices": slices, "failures": failures], options: [.prettyPrinted, .sortedKeys]).write(to: file)
print("saved \(file.path)")

// Regression gate: resizing must not cost detection. Every layout at every size has to place at least 93% of
// pictures (the level measured on 2026-10-17 was 95–98%).
let gate = 0.93
let below = bySlice.filter { $0.key.contains("×") && Double($0.value.placed) / Double(max(1, $0.value.n)) < gate }
if below.isEmpty { print("gate: every layout and size places ≥ \(Int(gate * 100))%") } else {
    print("gate FAILED: " + below.keys.sorted().joined(separator: ", ")); exit(1)
}
