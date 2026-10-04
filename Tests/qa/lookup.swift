import SwiftUI
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

// Smart recording: what's under a click becomes a label.
let (sx, sb) = window([("Daily login", CGPoint(x: 40, y: 40)), ("Claim", CGPoint(x: 600, y: 60)),
                       ("Claim", CGPoint(x: 600, y: 300)),
                       ("This is a long sentence that explains the rewards screen in detail", CGPoint(x: 30, y: 420))])
let lines = TextFinder.read(sx)
let size = CGSize(width: sx.width, height: sx.height)
func centre(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
let l1 = ClickReader.label(in: lines, at: centre(sb["Daily login"]!), window: size)
check("a click on a label reads the label", l1?.text == "Daily login" && l1?.area == nil, "\(String(describing: l1))")
let l2 = ClickReader.label(in: lines, at: centre(sb["Claim"]!), window: size)
check("a word that appears twice gets a search area around the click",
      l2?.text == "Claim" && (l2?.area?.contains(centre(sb["Claim"]!)) ?? false), "\(String(describing: l2))")
let sentence = sb["This is a long sentence that explains the rewards screen in detail"]!
let wordPoint = CGPoint(x: sentence.minX + sentence.width * 0.62, y: sentence.midY)
let l3 = ClickReader.label(in: lines, at: wordPoint, window: size)
check("a click inside a long sentence stays a plain click", l3 == nil, "\(String(describing: l3))")
check("a click on empty space reads nothing", ClickReader.label(in: lines, at: CGPoint(x: 400, y: 200), window: size) == nil)

let clickSteps = [MacroStep(delay: 0.5, action: .move(x: 10, y: 10)),
                  MacroStep(delay: 0.2, action: .mouseDown(button: .left, x: 80, y: 52, clickCount: 1, flags: 0)),
                  MacroStep(delay: 0.08, action: .mouseUp(button: .left, x: 80, y: 52, clickCount: 1, flags: 0)),
                  MacroStep(delay: 1.0, action: .mouseDown(button: .left, x: 300, y: 300, clickCount: 1, flags: 0)),
                  MacroStep(delay: 0.08, action: .mouseUp(button: .left, x: 300, y: 300, clickCount: 1, flags: 0))]
let conv = ClickReader.convert(clickSteps, labels: [clickSteps[1].id: ClickReader.Label(text: "Daily login", area: nil)])
if conv.steps.count == 3, case .findImage(let f) = conv.steps[0].action {
    check("a labelled click becomes a text step with the recorded spot as fallback",
          f.text == "Daily login" && f.fallbackX == 80 && f.fallbackY == 52 && f.mode == .click && f.timeout == 5)
    check("…the cursor travel before it is dropped, its time kept as the step's delay", abs(conv.steps[0].delay - 0.7) < 1e-9)
    check("…and other clicks stay as they were", { if case .mouseDown = conv.steps[1].action { return true }; return false }())
} else {
    check("a labelled click becomes a text step", false, "\(conv.steps.map(\.action))")
}
let fb = try! JSONDecoder().decode(ImageStep.self, from: JSONEncoder().encode({ () -> ImageStep in
    var s = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0); s.fallbackX = 5; s.fallbackY = 6; return s }()))
check("the fallback spot saves and loads", fb.fallbackX == 5 && fb.fallbackY == 6)

// All at once: taking turns vs higher steps win.
var fair = AllAtOnceChooser(rules: [0: .init(settle: 0, repeatUntilGone: true, repeatEvery: 0.1),
                                    5: .init(settle: 0, repeatUntilGone: true, repeatEvery: 0.1)])
let f1 = fair.choose(found: [0, 5], now: 1); fair.clicked(f1!, at: 1)
let f2 = fair.choose(found: [0, 5], now: 2)
check("taking turns: the other one goes next", f1 != f2, "\(String(describing: f1)) then \(String(describing: f2))")
var prio = AllAtOnceChooser(rules: [0: .init(settle: 0, repeatUntilGone: true, repeatEvery: 0.1),
                                    5: .init(settle: 0, repeatUntilGone: true, repeatEvery: 0.1)], prioritized: true)
let p1 = prio.choose(found: [0, 5], now: 1); prio.clicked(p1!, at: 1)
let p2 = prio.choose(found: [0, 5], now: 2)
check("higher steps win: step 1 every time", p1 == 0 && p2 == 0, "\(String(describing: p1)) \(String(describing: p2))")
var pb = PlaybackOptions(); pb.prioritized = true; pb.idleTapAfter = 4; pb.idleTapX = 195; pb.idleTapY = 700
let pb2 = try! JSONDecoder().decode(PlaybackOptions.self, from: JSONEncoder().encode(pb))
check("priority and tap-when-stuck save and load", pb2.prioritized && pb2.idleTapAfter == 4 && pb2.idleTapX == 195 && pb2.idleTapY == 700)
let oldPB = try! JSONDecoder().decode(PlaybackOptions.self, from: #"{"speed":1}"#.data(using: .utf8)!)
check("older macros: no priority, no idle tap", !oldPB.prioritized && oldPB.idleTapAfter == 0)

// Describe: the model's reply becomes steps; anything else is ignored.
let planned = PlannedStep.parse("""
1. CLICK Claim
- WAIT 2
TYPE "hello"
PRESS Return
Sure! Here are your steps:
PRESS F13
CLICK
""")
check("a drafted plan becomes steps", planned == [.click("Claim"), .wait(2), .type("hello"), .press("Return")], "\(planned)")

// Live (informational): what the on-device model suggests on a typical results screen.
let screenLines = ["K.O.", "Battle Results", "OK", "Link Skill Level"].map { TextFinder.Line(text: $0, rect: .zero, words: []) }
let sem = DispatchSemaphore(value: 0)
var suggestion: String?
Task.detached { suggestion = await Assistant.suggestTap(on: screenLines); sem.signal() }
sem.wait()
print("INFO suggestion for [K.O., Battle Results, OK, Link Skill Level]: \(suggestion ?? "none") (model available: \(Assistant.modelAvailable))")
check("a suggestion is always one of the words on screen", suggestion == nil || screenLines.contains { $0.text == suggestion })

// Smart recording, icons: a detailed spot becomes a picture; a flat one doesn't.
let (ix, ib) = window([("Claim", CGPoint(x: 600, y: 60))])
var iconRGBA = ix.rgba
for y in 300..<340 { for x in 100..<140 where (x / 8 + y / 8) % 2 == 0 { let o = (y * ix.width + x) * 4; iconRGBA[o] = 20; iconRGBA[o+1] = 20; iconRGBA[o+2] = 200 } }
let icon = ScreenReader.WindowPixels(rgba: iconRGBA, width: ix.width, height: ix.height)
let iconLabel = ClickReader.picture(in: icon, at: CGPoint(x: 120, y: 320))
check("a click on a detailed icon keeps a picture of it", iconLabel?.picture != nil && (iconLabel?.area?.contains(CGPoint(x: 120, y: 320)) ?? false))
check("a click on a flat area keeps nothing", ClickReader.picture(in: icon, at: CGPoint(x: 400, y: 450)) == nil)
_ = ib
let picConv = ClickReader.convert(clickSteps, labels: [clickSteps[3].id: iconLabel!])
if case .findImage(let f) = picConv.steps.last?.action {
    check("an icon click becomes a picture step with the recorded spot as fallback",
          f.text == nil && !f.png.isEmpty && f.fallbackX == 300 && f.timeout == 3 && picConv.pictures == 1)
} else { check("an icon click becomes a picture step", false) }

// Counters: “Repeat from” plays the steps again, then carries on.
var presses: [Double] = []
EventSynth.testSink = { e in if e.type == .leftMouseDown { presses.append(Double(e.location.x)) } }
DoubleClickEverywhere.configure(enabled: false)
ClickSpread.configure(enabled: false, radius: 0)
let stepA = MacroStep(delay: 0, action: .click(button: .left, x: 11, y: 11, count: 1))
let loopMacro = Macro(name: "loop", steps: [stepA,
                                            MacroStep(delay: 0, action: .repeatFrom(step: stepA.id, times: 2)),
                                            MacroStep(delay: 0, action: .click(button: .left, x: 22, y: 22, count: 1))])
let player = Player()
var finishedRun = false
player.play(loopMacro, progress: { _, _, _ in }, finished: { _ in finishedRun = true })
let deadline = Date().addingTimeInterval(5)
while !finishedRun && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
check("repeat from: the step runs 3 times, then the next one once", presses == [11, 11, 11, 22], "\(presses)")
EventSynth.testSink = nil

// Words found among lines read once (the shared read in All at once chains).
let one = TextFinder.find("claim", in: lines, area: nil)
check("a word is found among lines already read", one != nil)
let near = TextFinder.find("Claim", in: lines, area: CGRect(x: 500, y: 250, width: 300, height: 150))
check("…and a search area picks the copy inside it", near.map { $0.midY > 250 } ?? false, "\(String(describing: near))")
check("…and a word that isn't there isn't found", TextFinder.find("Collect", in: lines, area: nil) == nil)

// Click areas: where on a found picture the click lands.
var ca = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
ca.clickArea = CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5)
let t1 = ca.clickTarget(in: CGRect(x: 100, y: 100, width: 200, height: 100))
check("a click area puts the click in its box", t1.point == CGPoint(x: 275, y: 125) && t1.bounds == CGRect(x: 250, y: 100, width: 50, height: 50), "\(t1)")
ca.offsetX = 10
check("…and the click offset still applies", ca.clickTarget(in: CGRect(x: 100, y: 100, width: 200, height: 100)).point == CGPoint(x: 285, y: 125))
ca.clickArea = nil; ca.offsetX = 0
check("no click area: the middle of the picture", ca.clickTarget(in: CGRect(x: 0, y: 0, width: 40, height: 20)).point == CGPoint(x: 20, y: 10))
let dragged = ClickAreaEditor.area(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 30), in: CGSize(width: 100, height: 50))
check("dragging on the picture sets the box", abs(dragged.minX - 0.1) < 1e-9 && abs(dragged.minY - 0.2) < 1e-9 && abs(dragged.width - 0.4) < 1e-9 && abs(dragged.height - 0.4) < 1e-9, "\(dragged)")
let clicked = ClickAreaEditor.area(from: CGPoint(x: 50, y: 25), to: CGPoint(x: 51, y: 25), in: CGSize(width: 100, height: 50))
check("clicking sets a small box around that spot", abs(clicked.midX - 0.51) < 0.01 && abs(clicked.midY - 0.5) < 0.01 && clicked.width < 0.1, "\(clicked)")

// Variants: any of the step's pictures counts.
func pngOf(_ px: ScreenReader.WindowPixels, _ r: CGRect) -> (Data, Double, Double) {
    let c = px.cropped(to: r.integral)!
    return (NSBitmapImageRep(cgImage: c.cgImage!).representation(using: .png, properties: [:])!, Double(c.width), Double(c.height))
}
let settingsPic = pngOf(px, boxes["Settings"]!)
let claimPic = pngOf(ix, ib["Claim"]!)
var vstep = ImageStep(png: settingsPic.0, width: settingsPic.1, height: settingsPic.2, originX: 0, originY: 0)
check("without the variant, a picture that isn't on screen isn't found", Lookup(step: vstep)!.locate(in: ix) == nil)
vstep.variants = [PictureVariant(png: claimPic.0, width: claimPic.1, height: claimPic.2)]
let vfound = Lookup(step: vstep)!.locate(in: ix)
check("with it, the variant on screen is found", near(vfound, ib["Claim"]!), "\(String(describing: vfound))")

// Combine two picture steps into one.
var combineMacro = Macro(name: "c", steps: [
    MacroStep(delay: 0, action: .findImage(ImageStep(png: settingsPic.0, width: settingsPic.1, height: settingsPic.2, originX: 0, originY: 0))),
    MacroStep(delay: 0, action: .findImage(ImageStep(png: claimPic.0, width: claimPic.1, height: claimPic.2, originX: 0, originY: 0))),
    MacroStep(delay: 1, action: .wait)])
let cui = DetailUIState()
let cedit = ActionEditing(macro: Binding(get: { combineMacro }, set: { combineMacro = $0 }), ui: cui)
cui.selection = Set(combineMacro.steps.prefix(2).map(\.id))
cedit.combinePictures()
if combineMacro.steps.count == 2, case .findImage(let merged) = combineMacro.steps[0].action {
    check("combining makes one step that also matches the other picture", merged.variants.count == 1 && merged.png == settingsPic.0)
} else { check("combining two picture steps", false, "\(combineMacro.steps.count) steps") }

// Both: the picture or the words, whichever shows up.
var both = ImageStep(png: settingsPic.0, width: settingsPic.1, height: settingsPic.2, originX: 0, originY: 0)
both.text = "Claim"
both.alsoPicture = true
let bothLookup = Lookup(step: both)!
check("both: the picture is found when it's there (checked first)", near(bothLookup.locate(in: px), boxes["Settings"]!))
check("both: without the picture, the words are found", near(bothLookup.locate(in: ix), ib["Claim"]!),
      "\(String(describing: bothLookup.locate(in: ix)))")
check("both: skipping the word read only tries the picture", bothLookup.locate(in: ix, readText: false) == nil)
var bothEmpty = both; bothEmpty.text = ""
check("both with no words typed still looks for the picture", near(Lookup(step: bothEmpty)?.locate(in: px), boxes["Settings"]!))
var textOnly = both; textOnly.alsoPicture = false; textOnly.text = "Nowhere"
check("text mode ignores a picture left over from before", Lookup(step: textOnly)!.locate(in: px) == nil)
let both2 = try! JSONDecoder().decode(ImageStep.self, from: JSONEncoder().encode(both))
check("both saves and loads", both2.alsoPicture && both2.text == "Claim" && both2.usesPicture)
check("both title names the picture and the words", ActionGroup(id: UUID(), range: 0..<1, lead: 0...0, wait: 0, start: 0,
      kind: .image(both)).title(touch: false).contains("the picture or “Claim”"))

// Your own presses during a run become suggestions, unless a step already finds them.
let pressLines = TextFinder.read(px)
let onSettings = CGPoint(x: boxes["Settings"]!.midX, y: boxes["Settings"]!.midY)
let sug = PressWatcher.suggestion(in: px, at: onSettings, lookups: [])
check("a press on a label is suggested as that label", sug?.label.text == "Settings", "\(String(describing: sug?.label.text))")
var settingsText = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0); settingsText.text = "Settings"
check("…but not when a text step already finds it",
      PressWatcher.suggestion(in: px, at: onSettings, lookups: [Lookup(step: settingsText)!]) == nil)
let settingsPicStep = ImageStep(png: settingsPic.0, width: settingsPic.1, height: settingsPic.2, originX: 0, originY: 0)
check("…or a picture step already finds it",
      PressWatcher.suggestion(in: px, at: onSettings, lookups: [Lookup(step: settingsPicStep)!]) == nil)
_ = pressLines
if let sug {
    let twice = PressSuggestion.merge([sug], [PressSuggestion(label: sug.label, point: onSettings)])
    check("pressing the same thing again counts it twice", twice.count == 1 && twice[0].count == 2)
    let st = sug.step(inOrder: true)
    check("a suggestion becomes a text step that won't hold up an in-order run",
          st.text == "Settings" && st.timeout == 3 && st.otherwise == .continueAnyway)
    check("…and in All at once it waits as usual", sug.step(inOrder: false).untilAppears)
}

// Live: the press listener counts a real press and ignores one tagged as Heron's own.
do {
    let screen = NSScreen.screens[0].frame
    // A small window of our own in the bottom-left corner, on top of everything, so the presses land on it.
    let pw = NSWindow(contentRect: NSRect(x: screen.minX + 4, y: screen.minY + 4, width: 60, height: 60),
                      styleMask: [.borderless], backing: .buffered, defer: false)
    pw.level = .screenSaver
    pw.orderFrontRegardless()
    let target = CGPoint(x: screen.minX + 30, y: screen.height - 34) // top-left based
    let back = CGEvent(source: nil)?.location ?? .zero
    let watcher = PressWatcher(app: TargetApp(bundleID: "test.none", name: "None"), steps: [])
    var seen: [CGPoint] = []
    let seenLock = NSLock()
    watcher.onPress = { p in seenLock.withLock { seen.append(p) } }
    if watcher.start() {
        func press(ours: Bool) {
            for t in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: target, mouseButton: .left)!
                if ours { e.setIntegerValueField(.eventSourceUserData, value: EventSynth.marker << 32) }
                e.post(tap: .cghidEventTap)
            }
        }
        press(ours: true)
        press(ours: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        _ = watcher.finish()
        CGWarpMouseCursorPosition(back)
        let n = seenLock.withLock { seen.count }
        check("the press listener counts your press and ignores Heron's own", n == 1, "\(n) seen")
    } else {
        print("SKIP live press listener (no Input Monitoring for the test runner)")
    }
    pw.orderOut(nil)
}

// A single character only matches on its own, never inside a longer number.
let (nx, nb) = window([("HP 759981", CGPoint(x: 40, y: 40)), ("Turn 1", CGPoint(x: 400, y: 40)), ("4", CGPoint(x: 120, y: 300))])
let nlines = TextFinder.read(nx)
let oneHit = TextFinder.find("1", in: nlines, area: nil)
check("“1” matches the 1 in “Turn 1”, not the one inside 759981", oneHit.map { $0.minX >= nb["Turn 1"]!.minX } ?? false, "\(String(describing: oneHit))")
check("“1” in an area with only a number containing 1 isn't found",
      TextFinder.find("1", in: nlines, area: CGRect(x: 0, y: 0, width: 380, height: 120)) == nil)
check("“4” matches the 4 standing on its own", near(TextFinder.find("4", in: nlines, area: nil), nb["4"]!))
check("longer words still match inside a line", TextFinder.find("Turn", in: nlines, area: nil) != nil)

// Big pictures: found where they are, without taking seconds.
let bigScene = window([("Battle Results", CGPoint(x: 60, y: 60)), ("Link Skill Level", CGPoint(x: 60, y: 120)),
                       ("Claim", CGPoint(x: 500, y: 300)), ("Close", CGPoint(x: 300, y: 420))])
let bigRect = CGRect(x: 40, y: 40, width: 520, height: 330)
let bigPic = pngOf(bigScene.0, bigRect)
let bigStep = ImageStep(png: bigPic.0, width: bigPic.1, height: bigPic.2, originX: 0, originY: 0)
let bigT0 = Date()
let bigFound = Lookup(step: bigStep)!.matchPicture(in: bigScene.0)
let bigMs = Date().timeIntervalSince(bigT0) * 1000
check("a big picture is found exactly", bigFound.map { abs($0.rect.minX - 40) <= 1 && abs($0.rect.minY - 40) <= 1 && $0.score > 0.95 } ?? false,
      "\(String(describing: bigFound))")
check("…in well under a second", bigMs < 300, String(format: "%.0f ms", bigMs))

// Recording: quick repeated taps (as iPhone Mirroring often records them) still become find steps.
let multi = [MacroStep(delay: 0.3, action: .move(x: 200, y: 670)),
             MacroStep(delay: 0.03, action: .mouseDown(button: .left, x: 212, y: 680, clickCount: 1, flags: 0)),
             MacroStep(delay: 0.03, action: .mouseUp(button: .left, x: 212, y: 680, clickCount: 1, flags: 0)),
             MacroStep(delay: 0.05, action: .mouseDown(button: .left, x: 212, y: 680, clickCount: 2, flags: 0)),
             MacroStep(delay: 0.03, action: .drag(button: .left, x: 206, y: 684)),
             MacroStep(delay: 0.03, action: .mouseUp(button: .left, x: 206, y: 685, clickCount: 0, flags: 0))]
var bothLabel = ClickReader.Label(text: "Start", area: nil)
bothLabel.picture = claimPic.0; bothLabel.size = CGSize(width: claimPic.1, height: claimPic.2)
let mconv = ClickReader.convert(multi, labels: [multi[1].id: bothLabel])
if mconv.steps.count == 1, case .findImage(let f) = mconv.steps[0].action {
    check("a double tap with a wobble becomes one find step that keeps tapping until it's gone",
          f.repeatUntilGone && f.fallbackX == 212 && f.fallbackY == 680, "\(f.repeatUntilGone)")
    check("…looking for both the picture and the words", f.text == "Start" && f.alsoPicture && f.usesPicture)
    check("…counted once in the summary", mconv.words == 1 && mconv.pictures == 0)
} else { check("a double tap becomes one find step", false, "\(mconv.steps.map(\.action))") }
let words = ClickReader.both(in: px, at: CGPoint(x: boxes["Settings"]!.midX, y: boxes["Settings"]!.midY))
check("a click on a word keeps the word (and a picture when the spot has detail)", words?.text == "Settings")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
