// Renders the app icon and menu bar icon from their SVG sources.
//   swift scripts/make-icon.swift
// Writes Resources/AppIcon.icns, Resources/MenuBarIcon.png (+@2x) and docs/icon.png.
import AppKit

func render(_ svg: String, size: Int) -> Data {
    guard let image = NSImage(contentsOfFile: svg) else { fatalError("Can't read \(svg)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render("Resources/AppIcon.svg", size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render("Resources/AppIcon.svg", size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render("Resources/MenuBarIcon.svg", size: 18).write(to: URL(fileURLWithPath: "Resources/MenuBarIcon.png"))
try! render("Resources/MenuBarIcon.svg", size: 36).write(to: URL(fileURLWithPath: "Resources/MenuBarIcon@2x.png"))
try! render("Resources/AppIcon.svg", size: 256).write(to: URL(fileURLWithPath: "docs/icon.png"))
print("Icons written.")
