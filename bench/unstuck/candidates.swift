// Reads every saved stuck screen and lists the tappable-looking text on it as numbered candidates
// (data/candidates.json), plus review sheets with the numbers drawn on (data/sheets/), for labelling.
//   bench/unstuck/run.sh candidates
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let screensDir = root.appendingPathComponent("screens")
let sheetsDir = root.appendingPathComponent("sheets")
try? FileManager.default.createDirectory(at: sheetsDir, withIntermediateDirectories: true)

struct Candidate: Codable { let id: Int; let text: String; let box: [Int] }
struct Screen: Codable { let file: String; let size: [Int]; let candidates: [Candidate] }

let files = ((try? FileManager.default.contentsOfDirectory(atPath: screensDir.path)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
var screens: [Screen] = []
var thumbs: [NSImage] = []
for f in files {
    guard let img = NSImage(contentsOf: screensDir.appendingPathComponent(f)),
          let px = ScreenReader.WindowPixels(image: img) else { continue }
    // Lines of text short enough to be a button label; skip the window's own title bar.
    let lines = TextFinder.read(px).filter { $0.text.count <= 24 && $0.rect.minY > 30 }
    let cands = lines.enumerated().map { i, l in
        Candidate(id: i + 1, text: l.text, box: [Int(l.rect.minX), Int(l.rect.minY), Int(l.rect.width), Int(l.rect.height)])
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
