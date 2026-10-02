// Renders Resources/AppIcon.icns: a flat black cursor with a tilted, Saturn-style orbit ring on a light tile.
// The glyph is drawn here from scratch. The ring passes behind the cursor at the back and in front of it
// at the front, separated by small cut-out gaps.
// Usage: swift scripts/make-icon.swift [project root]
import AppKit

/// Classic pointer outline, tip at (0,0), y pointing down, height 1.
let pointer: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.82), (0.21, 0.63), (0.35, 0.95), (0.47, 0.90), (0.33, 0.59), (0.60, 0.59)]

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// A ring that is thickest in the middle and tapers to sharp points at both ends (like a blade).
func taperedRing(center c: CGPoint, radius r: CGFloat, thickness w: CGFloat,
                 from start: CGFloat, sweep: CGFloat, sharpness: CGFloat) -> CGPath {
    let steps = 240
    var outer: [CGPoint] = [], inner: [CGPoint] = []
    for i in 0...steps {
        let u = CGFloat(i) / CGFloat(steps)
        let a = start + sweep * u
        let half = w / 2 * pow(sin(.pi * u), sharpness)
        outer.append(CGPoint(x: c.x + (r + half) * cos(a), y: c.y + (r + half) * sin(a)))
        inner.append(CGPoint(x: c.x + (r - half) * cos(a), y: c.y + (r - half) * sin(a)))
    }
    let path = CGMutablePath()
    path.addLines(between: outer + inner.reversed())
    path.closeSubpath()
    return path
}

/// Variant knobs so a few looks can be compared side by side.
struct GlyphStyle {
    var ringInFront = true      // ring cuts the cursor (true) or cursor cuts the ring (false)
    var startDeg: CGFloat = 255 // where the ring begins (degrees, counter-clockwise from +x)
    var sweepDeg: CGFloat = 285
    var sharpness: CGFloat = 1.1
}

/// Open ring with tapered, pointed ends, and a cursor crossing it; the crossing is a cut-out gap.
func glyph(_ style: GlyphStyle = GlyphStyle()) -> CGPath {
    let arrowHeight: CGFloat = 296
    let gap: CGFloat = 13
    let c = CGPoint.zero
    let ring = taperedRing(center: c, radius: 164, thickness: 56,
                           from: style.startDeg * .pi / 180, sweep: style.sweepDeg * .pi / 180, sharpness: style.sharpness)

    let arrow = CGMutablePath()
    for (i, p) in pointer.enumerated() {
        let pt = CGPoint(x: c.x + p.0 * arrowHeight, y: c.y - p.1 * arrowHeight) // tip at the ring's centre
        i == 0 ? arrow.move(to: pt) : arrow.addLine(to: pt)
    }
    arrow.closeSubpath()

    func grown(_ p: CGPath) -> CGPath {
        p.union(p.copy(strokingWithWidth: gap * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    }
    var shape = style.ringInFront
        ? arrow.subtracting(grown(ring)).union(ring)
        : ring.subtracting(grown(arrow)).union(arrow)

    // Centre it on the tile.
    let box = shape.boundingBoxOfPath
    var move = CGAffineTransform(translationX: 512 - box.midX, y: 512 - box.midY)
    shape = shape.copy(using: &move)!
    return shape
}

func render(size: Int, glyph: CGPath) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s) // draw in 1024 units

    // ---- Tile: macOS grid (824pt rounded square in a 1024 canvas)
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let radius: CGFloat = 185
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let tileShadow = NSShadow()
    tileShadow.shadowColor = .black.withAlphaComponent(0.25)
    tileShadow.shadowOffset = NSSize(width: 0, height: -10)
    tileShadow.shadowBlurRadius = 22
    tileShadow.set()
    srgb(0.92, 0.92, 0.93).setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Quiet, matte light gradient.
    NSGradient(colors: [srgb(0.985, 0.985, 0.99), srgb(0.93, 0.93, 0.945), srgb(0.86, 0.865, 0.885)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: tilePath, angle: -90)

    // Thin rim: light at the top, faintly dark at the bottom.
    let rimW: CGFloat = 3
    let rimPath = NSBezierPath(roundedRect: tile.insetBy(dx: rimW / 2, dy: rimW / 2),
                               xRadius: radius - rimW / 2, yRadius: radius - rimW / 2)
    ctx.saveGState()
    ctx.addPath(rimPath.cgPath)
    ctx.setLineWidth(rimW)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    NSGradient(colors: [srgb(1, 1, 1, 0.9), srgb(1, 1, 1, 0.15), srgb(0, 0, 0, 0.12)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -90)
    ctx.restoreGState()

    // ---- Glyph: flat near-black, crisp edges.
    ctx.addPath(glyph)
    ctx.setFillColor(srgb(0.07, 0.07, 0.08).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "variants" {
    let looks: [(String, GlyphStyle)] = [
        ("a-cursor-front", GlyphStyle(ringInFront: true, startDeg: 262, sweepDeg: 300, sharpness: 0.9)),
        ("b-ring-front", GlyphStyle(ringInFront: true, startDeg: 255, sweepDeg: 285, sharpness: 1.1)),
        ("c-cursor-front-sharper", GlyphStyle(ringInFront: true, startDeg: 266, sweepDeg: 310, sharpness: 0.7)),
        ("d-ring-front-sharper", GlyphStyle(ringInFront: true, startDeg: 320, sweepDeg: 300, sharpness: 0.9)),
    ]
    for (name, look) in looks {
        try! render(size: 512, glyph: glyph(look)).write(to: root.appendingPathComponent("Resources/variant-\(name).png"))
    }
    print("Wrote variants")
    exit(0)
}
let shape = glyph()
for base in [16, 32, 128, 256, 512] {
    try! render(size: base, glyph: shape).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2, glyph: shape).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try? FileManager.default.removeItem(at: root.appendingPathComponent("Resources/AppIcon-preview.png"))
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"),
                                  to: root.appendingPathComponent("Resources/AppIcon-preview.png"))
try? FileManager.default.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
