import AppKit
import CoreGraphics
import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { failures += 1 }
}

/// A fake 800×500 window: grey background with labels drawn at known places (top-left origin, like the app).
func window(_ labels: [(String, CGPoint)]) -> (ScreenReader.WindowPixels, [String: CGRect]) {
    let w = 800, h = 500
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    var boxes: [String: CGRect] = [:]
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    rgba.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.93, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) // draw in top-left coordinates
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (s, p) in labels {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold),
                                                              .foregroundColor: NSColor.black])
            a.draw(at: p)
            boxes[s] = CGRect(origin: p, size: a.size())
        }
        NSGraphicsContext.current = nil
    }
    return (ScreenReader.WindowPixels(rgba: rgba, width: w, height: h), boxes)
}

func near(_ r: CGRect?, _ box: CGRect) -> Bool {
    guard let r else { return false }
    return box.insetBy(dx: -6, dy: -6).contains(CGPoint(x: r.midX, y: r.midY))
}

let (px, boxes) = window([("Settings", CGPoint(x: 40, y: 40)), ("Claim reward", CGPoint(x: 520, y: 380)),
                          ("Claim", CGPoint(x: 60, y: 400))])

// Text is found where it's drawn (window coordinates, top-left origin).
let claimReward = Lookup(png: nil, width: 0, height: 0, text: "claim reward", area: nil, strictness: 0.8)!
let r1 = claimReward.locate(in: px)
check("finds text, ignoring capitals", near(r1, boxes["Claim reward"]!), "\(String(describing: r1)) vs \(boxes["Claim reward"]!)")

// A word inside a longer line gets a box around just that word.
let settings = Lookup(png: nil, width: 0, height: 0, text: "Settings", area: nil, strictness: 0.8)!
check("finds a single word", near(settings.locate(in: px), boxes["Settings"]!))

// Missing text isn't "found".
let missing = Lookup(png: nil, width: 0, height: 0, text: "Collect", area: nil, strictness: 0.8)!
check("missing text isn't found", missing.locate(in: px) == nil)

// Search area: only looks inside it, and answers in window coordinates.
let bottomLeft = CGRect(x: 0, y: 330, width: 300, height: 170)
let claimLeft = Lookup(png: nil, width: 0, height: 0, text: "Claim", area: bottomLeft, strictness: 0.8)!
let r2 = claimLeft.locate(in: px)
check("area limits text search to the left “Claim”", near(r2, boxes["Claim"]!), "\(String(describing: r2))")
let settingsOutside = Lookup(png: nil, width: 0, height: 0, text: "Settings", area: bottomLeft, strictness: 0.8)!
check("text outside the area is ignored", settingsOutside.locate(in: px) == nil)

// Picture search inside an area, with the result offset back to window coordinates.
let pic = px.cropped(to: boxes["Claim reward"]!.integral)!
let png = NSBitmapImageRep(cgImage: pic.cgImage!).representation(using: .png, properties: [:])!
let picWhole = Lookup(png: png, width: Double(pic.width), height: Double(pic.height), text: nil, area: nil, strictness: 0.8)!
let r3 = picWhole.locate(in: px)
check("picture found in whole window", near(r3, boxes["Claim reward"]!), "\(String(describing: r3))")
let rightHalf = CGRect(x: 400, y: 0, width: 400, height: 500)
let picArea = Lookup(png: png, width: Double(pic.width), height: Double(pic.height), text: nil, area: rightHalf, strictness: 0.8)!
let r4 = picArea.locate(in: px)
check("picture found inside an area, in window coordinates", near(r4, boxes["Claim reward"]!), "\(String(describing: r4))")
let picWrongArea = Lookup(png: png, width: Double(pic.width), height: Double(pic.height), text: nil, area: bottomLeft, strictness: 0.8)!
check("picture outside the area isn't matched", picWrongArea.locate(in: px) == nil)

// Text mode with nothing typed never falls back to the old picture.
check("empty text mode has nothing to look for",
      Lookup(png: png, width: Double(pic.width), height: Double(pic.height), text: "", area: nil, strictness: 0.8) == nil)
var w = Watcher(name: "w")
w.templatePNG = png; w.templateWidth = Double(pic.width); w.templateHeight = Double(pic.height)
check("watcher with a picture can search", w.canSearch)
w.text = ""
check("watcher switched to Text with an empty box can't search", !w.canSearch)
w.text = "Claim"
check("watcher with text can search", w.canSearch)

// Switches: an action that's off groups as off; older files (no `enabled`) load as on.
var steps = [MacroStep(delay: 0.1, action: .click(button: .left, x: 10, y: 10, count: 1)),
             MacroStep(delay: 0.1, action: .click(button: .left, x: 50, y: 50, count: 1))]
steps[1].enabled = false
let groups = ActionGrouper.groups(for: steps)
check("action switched off reads as off", groups.count == 2 && groups[0].enabled && !groups[1].enabled)
let old = #"{"delay":0.1,"action":{"wait":{}}}"#.data(using: .utf8)!
if let s = try? JSONDecoder().decode(MacroStep.self, from: old) { check("old step without `enabled` loads as on", s.enabled) }
else { check("old step without `enabled` loads", false, "decode failed") }
let roundTrip = try! JSONDecoder().decode(MacroStep.self, from: JSONEncoder().encode(steps[1]))
check("switched-off step saves and loads as off", !roundTrip.enabled)
var ts = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
ts.text = "Claim"; ts.area = CGRect(x: 1, y: 2, width: 3, height: 4)
let ts2 = try! JSONDecoder().decode(ImageStep.self, from: JSONEncoder().encode(ts))
check("text step keeps its text and area", ts2.text == "Claim" && ts2.area == ts.area)
check("text step title", ActionGroup(id: UUID(), range: 0..<1, lead: 0...0, wait: 0, start: 0, kind: .image(ts2))
    .title(touch: true) == "Tap “Claim”")

// Exact matches win over longer lines that merely contain the text.
let claim = Lookup(png: nil, width: 0, height: 0, text: "Claim", area: nil, strictness: 0.8)!
check("exact “Claim” preferred over “Claim reward”", near(claim.locate(in: px), boxes["Claim"]!))

// How long one read of a whole window takes (watchers throttle text checks around this).
let t0 = Date()
for _ in 0..<5 { _ = claim.find(in: px) }
print(String(format: "INFO text read of an 800×500 window: %.0f ms", Date().timeIntervalSince(t0) / 5 * 1000))

// Background macros: the switch and the click limit survive saving and loading.
var bg = Macro(name: "bg", steps: [])
bg.runsInBackground = true
bg.playback.order = .allAtOnce
bg.playback.maxClicks = 3
let bg2 = try! JSONDecoder().decode(Macro.self, from: JSONEncoder().encode(bg))
check("background switch saves and loads", bg2.runsInBackground)
check("click limit saves and loads", bg2.playback.maxClicks == 3, "\(bg2.playback.maxClicks)")
let oldMacro = #"{"name":"old","steps":[]}"#.data(using: .utf8)!
let om = Lenient.decode(oldMacro, defaults: Macro(name: "", steps: []))
check("older macros load as not-background with no limit", om?.runsInBackground == false && om?.playback.maxClicks == 0)

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
