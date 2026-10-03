// Generates neutral demo content (mock phone screen, macros, a chain, a watcher) for README screenshots.
// Compiled together with the app's model files by scripts/make-demo.sh. Usage: demo-data <output folder>
import AppKit

let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let macroDir = home.appendingPathComponent("Macros", isDirectory: true)
try? FileManager.default.removeItem(at: home)
try! FileManager.default.createDirectory(at: macroDir, withIntermediateDirectories: true)

// MARK: Mock phone screen (390×844 points, drawn at 2×)

let W: CGFloat = 390, H: CGFloat = 844
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
// Flip so we can lay out top-down like the app's window coordinates.
gctx.cgContext.translateBy(x: 0, y: H)
gctx.cgContext.scaleBy(x: 1, y: -1)
let flipped = NSGraphicsContext(cgContext: gctx.cgContext, flipped: true)
NSGraphicsContext.current = flipped

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func text(_ s: String, _ p: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, _ c: NSColor = .white, center: Bool = false) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c]
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: CGPoint(x: center ? p.x - sz.width / 2 : p.x, y: p.y - sz.height / 2))
}
func pill(_ r: CGRect, _ fill: NSColor, _ label: String, _ labelColor: NSColor = .white, size: CGFloat = 15) {
    let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
    fill.setFill(); path.fill()
    text(label, CGPoint(x: r.midX, y: r.midY), size: size, weight: .semibold, labelColor, center: true)
}

NSGradient(colors: [color(0x0E1424), color(0x1A2747)])!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)
let skip = CGRect(x: 296, y: 64, width: 72, height: 30)
pill(skip, color(0xFFFFFF, 0.16), "Skip", size: 14)
text("Rewards", CGPoint(x: 24, y: 130), size: 34, weight: .bold)
text("Day 7 streak · 3 to collect", CGPoint(x: 24, y: 166), size: 15, weight: .regular, color(0xFFFFFF, 0.6))

let rows: [(String, String, UInt32)] = [("Daily login", "50 coins", 0xFF9F0A), ("Weekly quest", "Rare chest", 0xBF5AF2),
                                        ("Event pass", "Level 12 reached", 0x64D2FF), ("Friends", "4 gifts waiting", 0x30D158)]
var claims: [CGRect] = []
for (i, row) in rows.enumerated() {
    let card = CGRect(x: 16, y: 206 + CGFloat(i) * 92, width: W - 32, height: 78)
    color(0xFFFFFF, 0.07).setFill()
    NSBezierPath(roundedRect: card, xRadius: 18, yRadius: 18).fill()
    color(row.2).setFill()
    NSBezierPath(ovalIn: CGRect(x: card.minX + 16, y: card.midY - 20, width: 40, height: 40)).fill()
    text(row.0, CGPoint(x: card.minX + 70, y: card.midY - 10), size: 17, weight: .semibold)
    text(row.1, CGPoint(x: card.minX + 70, y: card.midY + 12), size: 14, weight: .regular, color(0xFFFFFF, 0.55))
    let claim = CGRect(x: card.maxX - 92, y: card.midY - 17, width: 76, height: 34)
    pill(claim, color(0x34C759), "Claim")
    claims.append(claim)
}
let cont = CGRect(x: 24, y: 742, width: W - 48, height: 54)
let contPath = NSBezierPath(roundedRect: cont, xRadius: 16, yRadius: 16)
color(0x0A84FF).setFill(); contPath.fill()
text("Continue", CGPoint(x: cont.midX, y: cont.midY), size: 18, weight: .semibold, center: true)
NSGraphicsContext.restoreGraphicsState()

let phonePNG = rep.representation(using: .png, properties: [:])!
func crop(_ r: CGRect) -> (Data, Double, Double, CGRect) {
    let px = CGRect(x: r.minX * 2, y: r.minY * 2, width: r.width * 2, height: r.height * 2).integral
    let c = rep.cgImage!.cropping(to: px)!
    return (NSBitmapImageRep(cgImage: c).representation(using: .png, properties: [:])!, Double(r.width), Double(r.height), r)
}

// MARK: Macros

let phone = TargetApp(bundleID: "com.example.rewards", name: "Rewards")
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
func save(_ m: Macro, snapshot: Bool) {
    try! enc.encode(m).write(to: macroDir.appendingPathComponent("\(m.id.uuidString).json"))
    if snapshot { try! phonePNG.write(to: macroDir.appendingPathComponent("\(m.id.uuidString).png")) }
}
func tap(_ x: Double, _ y: Double, wait: Double, count: Int = 1) -> [MacroStep] {
    (1...count).flatMap { i in [
        MacroStep(delay: i == 1 ? wait : 0.08, action: .mouseDown(button: .left, x: x, y: y, clickCount: i, flags: 0)),
        MacroStep(delay: 0.07, action: .mouseUp(button: .left, x: x, y: y, clickCount: i, flags: 0)),
    ] }
}

var routine = Macro(name: "Morning routine", steps: [])
routine.created = Date(timeIntervalSinceNow: -3600)
routine.target = TargetOptions(app: phone, delivery: .jumpReturn)
routine.playback.repeatMode = .times
routine.playback.loops = 3
routine.playback.loopDelay = 5
routine.steps += tap(Double(claims[0].midX), Double(claims[0].midY), wait: 0)
routine.steps += tap(Double(claims[1].midX), Double(claims[1].midY), wait: 0.8)
routine.steps.append(MacroStep(delay: 0.6, action: .waitForColor(at: CGPoint(x: claims[2].midX, y: claims[2].midY), .detect("#34C759"))))
routine.steps += tap(Double(claims[2].midX), Double(claims[2].midY), wait: 0)
routine.steps += tap(120, 560, wait: 1.1, count: 2)
// Swipe up the list.
routine.steps.append(MacroStep(delay: 0.9, action: .mouseDown(button: .left, x: 195, y: 650, clickCount: 1, flags: 0)))
for (i, y) in [600.0, 520, 430, 340].enumerated() {
    routine.steps.append(MacroStep(delay: 0.03 + Double(i) * 0.002, action: .drag(button: .left, x: 196, y: y)))
}
routine.steps.append(MacroStep(delay: 0.03, action: .mouseUp(button: .left, x: 196, y: 330, clickCount: 1, flags: 0)))
routine.steps += tap(Double(cont.midX), Double(cont.midY), wait: 1.2)
routine.steps += tap(Double(skip.midX), Double(skip.midY), wait: 1.4)
save(routine, snapshot: true)

var chain = Macro(name: "Collect daily rewards", steps: [])
chain.created = Date(timeIntervalSinceNow: -1800)
chain.target = TargetOptions(app: phone, delivery: .jumpReturn)
chain.playback.repeatMode = .untilStopped
chain.playback.loopDelay = 30
for (i, r) in [claims[0], claims[1], cont, skip].enumerated() {
    let c = crop(r)
    var s = ImageStep(png: c.0, width: c.1, height: c.2, originX: Double(r.minX), originY: Double(r.minY))
    s.repeatUntilGone = i < 2
    s.timeout = i == 3 ? 3 : -1
    s.otherwise = .continueAnyway
    s.strictness = 0.85
    chain.steps.append(MacroStep(delay: i == 0 ? 0 : 0.3, action: .findImage(s)))
    if i == 1 {
        // A text step: tap the last card's "Claim", searching only that card.
        var t = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
        t.text = "Claim"
        t.area = CGRect(x: 16, y: 482, width: W - 32, height: 78)
        t.timeout = 5
        t.otherwise = .continueAnyway
        chain.steps.append(MacroStep(delay: 0.3, action: .findImage(t)))
    }
}
chain.steps[chain.steps.count - 1].enabled = false // "Skip" switched off
save(chain, snapshot: true)

// MARK: Watcher

let skipCrop = crop(skip)
var watcher = Watcher(name: "Close pop-ups")
watcher.target = TargetOptions(app: phone, delivery: .jumpReturn)
watcher.templatePNG = skipCrop.0
watcher.templateWidth = skipCrop.1
watcher.templateHeight = skipCrop.2
watcher.interval = 0.5
watcher.firstClickDelay = 0.3
var gifts = Watcher(name: "Claim gifts")
gifts.target = TargetOptions(app: phone, delivery: .jumpReturn)
gifts.text = "4 gifts waiting"
gifts.interval = 2
try! JSONEncoder().encode([watcher, gifts]).write(to: home.appendingPathComponent("Watchers.json"))

// MARK: Preferences for the demo copy (its own bundle id, so its own settings)

let defaults = UserDefaults(suiteName: "local.heron.demo")!
defaults.removePersistentDomain(forName: "local.heron.demo")
// Default hotkeys are shown; HERON_SCREENSHOTS stops the demo copy from registering them.
defaults.set(2, forKey: "hotkeysVersion")
var ac = AutoClickSettings()
ac.intervalMs = 80
ac.location = .points
ac.points = [ClickPoint(x: 312, y: 251, color: "#34C759"), ClickPoint(x: 312, y: 343, color: "#34C759")]
ac.target = TargetOptions(app: phone, delivery: .jumpReturn)
ac.colorCheck = true
ac.stopMode = .afterClicks
ac.stopClicks = 500
defaults.set(try! JSONEncoder().encode(ac), forKey: "autoClick")
defaults.set("visual", forKey: "stepsViewMode")
defaults.synchronize()
print("Demo data written to \(home.path)")
