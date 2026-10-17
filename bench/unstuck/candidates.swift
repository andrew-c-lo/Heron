// Reads every saved stuck screen and lists the tappable-looking text on it as numbered candidates
// (data/candidates.json), plus review sheets with the numbers drawn on (data/sheets/), for labelling.
//   bench/unstuck/run.sh candidates
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let screensDir = root.appendingPathComponent("screens")
let sheetsDir = root.appendingPathComponent("sheets")
try? FileManager.default.createDirectory(at: sheetsDir, withIntermediateDirectories: true)

struct Candidate: Codable { let id: Int; let text: String; let box: [Int]; var score: Double? = nil }
struct Screen: Codable { let file: String; let size: [Int]; let candidates: [Candidate] }

// The macros the screens came from (frozen copies in data/macros/, named by id): their picture steps are
// looked for on each screen, and wherever one roughly shows up it becomes a candidate too ("picture 4 (step 8)").
let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
let enc8601 = JSONEncoder(); enc8601.dateEncodingStrategy = .iso8601
var macroByPrefix: [String: Macro] = [:]
for f in (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("macros").path)) ?? [] where f.hasSuffix(".json") {
    if let d = FileManager.default.contents(atPath: root.appendingPathComponent("macros").appendingPathComponent(f).path),
       let m = Lenient.decode(d, defaults: Macro(name: "", steps: []), encoder: enc8601, decoder: dec) {
        macroByPrefix[String(f.prefix(8))] = m
    }
}
/// What a picture step shows, in words: its own words if it has any, else its colour.
func describe(_ p: ImageStep) -> String {
    let w = (p.pictureWords ?? p.text ?? "").trimmingCharacters(in: .whitespaces)
    if !w.isEmpty, w.count <= 20 { return "picture “\(w)”" }
    return "\(p.pictureColor ?? "") picture".trimmingCharacters(in: .whitespaces)
}
let pictureFloor = 0.55

let files = ((try? FileManager.default.contentsOfDirectory(atPath: screensDir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
var screens: [Screen] = []
var thumbs: [NSImage] = []
for f in files {
    guard let img = NSImage(contentsOf: screensDir.appendingPathComponent(f)),
          let px = ScreenReader.WindowPixels(image: img) else { continue }
    // Lines of text short enough to be a button label; skip the window's own title bar.
    let lines = TextFinder.read(px).filter { $0.text.count <= 24 && $0.rect.minY > 30 }
    var cands = lines.enumerated().map { i, l in
        Candidate(id: i + 1, text: l.text, box: [Int(l.rect.minX), Int(l.rect.minY), Int(l.rect.width), Int(l.rect.height)])
    }
    // The macro's own pictures, wherever each roughly matches (numbered from 101), best first, no overlaps.
    if let m = macroByPrefix[String(f.prefix(8))] {
        let scene = TemplateMatcher.Scene(rgba: px.rgba, width: px.width, height: px.height)
        var found: [(String, CGRect, Double)] = []
        for (i, st) in m.steps.enumerated() where st.enabled {
            guard case .findImage(var p) = st.action, !p.png.isEmpty else { continue }
            p.text = nil // the picture itself, not its words (words are already in the text candidates)
            guard let l = Lookup(step: p, reference: m.target.windowSize, emulator: m.target.isAndroidEmulator),
                  let r = l.matchPicture(in: px, scene: scene), r.score >= pictureFloor else { continue }
            found.append(("\(describe(p)) (step \(i + 1))", r.rect, r.score))
        }
        var kept: [(String, CGRect, Double)] = []
        for c in found.sorted(by: { $0.2 > $1.2 }) where !kept.contains(where: { $0.1.intersection(c.1).width * $0.1.intersection(c.1).height > 0.5 * c.1.width * c.1.height }) {
            kept.append(c)
        }
        for (k, c) in kept.enumerated() {
            cands.append(Candidate(id: 101 + k, text: c.0, box: [Int(c.1.minX), Int(c.1.minY), Int(c.1.width), Int(c.1.height)],
                                   score: (c.2 * 100).rounded() / 100))
        }
    }
    screens.append(Screen(file: f, size: [px.width, px.height], candidates: cands))
    // A thumbnail with each candidate boxed and numbered.
    let scale = 420.0 / Double(px.width)
    let tw = 420.0, th = Double(px.height) * scale
    let thumb = NSImage(size: NSSize(width: tw, height: th + 22))
    thumb.lockFocus()
    NSColor.black.setFill(); NSRect(x: 0, y: 0, width: tw, height: th + 22).fill()
    img.draw(in: NSRect(x: 0, y: 0, width: tw, height: th))
    let label: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
    NSString(string: f).draw(at: NSPoint(x: 4, y: th + 4), withAttributes: label)
    for c in cands {
        let r = NSRect(x: Double(c.box[0]) * scale, y: th - Double(c.box[1] + c.box[3]) * scale,
                       width: Double(c.box[2]) * scale, height: Double(c.box[3]) * scale)
        NSColor.systemYellow.setStroke(); NSBezierPath(rect: r).stroke()
        let tag = NSAttributedString(string: "\(c.id)", attributes: [.font: NSFont.boldSystemFont(ofSize: 12),
                                                                     .foregroundColor: NSColor.black, .backgroundColor: NSColor.systemYellow])
        tag.draw(at: NSPoint(x: r.minX, y: r.maxY))
    }
    thumb.unlockFocus()
    thumbs.append(thumb)
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(screens).write(to: root.appendingPathComponent("candidates.json"))

// Sheets of 4 thumbnails side by side.
for start in stride(from: 0, to: thumbs.count, by: 4) {
    let group = Array(thumbs[start..<min(start + 4, thumbs.count)])
    let h = group.map(\.size.height).max() ?? 0
    let sheet = NSImage(size: NSSize(width: 430 * Double(group.count), height: h))
    sheet.lockFocus()
    NSColor.darkGray.setFill(); NSRect(origin: .zero, size: sheet.size).fill()
    for (i, t) in group.enumerated() { t.draw(at: NSPoint(x: Double(i) * 430, y: h - t.size.height), from: .zero, operation: .copy, fraction: 1) }
    sheet.unlockFocus()
    let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
    try rep.representation(using: .png, properties: [:])!.write(to: sheetsDir.appendingPathComponent(String(format: "sheet-%02d.png", start / 4 + 1)))
}
print("\(screens.count) screens, \(screens.map(\.candidates.count).reduce(0, +)) candidates, \((thumbs.count + 3) / 4) sheets")
