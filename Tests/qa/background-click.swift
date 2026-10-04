import AppKit
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { failures += 1 }
}

// Background clicks are posted straight to the app, so they must carry the window and the spot in it
// themselves. Check how AppKit reads them, against a real window of our own.
_ = NSApplication.shared
let win = NSWindow(contentRect: NSRect(x: 300, y: 200, width: 400, height: 470),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.orderFrontRegardless()
let mainHeight = NSScreen.screens[0].frame.height
let topLeft = CGPoint(x: win.frame.minX, y: mainHeight - win.frame.maxY) // window origin, global top-left coordinates

var seen: [NSEvent] = []
EventSynth.testSink = { e in if let ns = NSEvent(cgEvent: e) { seen.append(ns) } }
ClickSpread.configure(enabled: false, radius: 0)
DoubleClickEverywhere.configure(enabled: false)
let p = Performer(route: Route(mode: .background, pid: getpid(), windowNumber: win.windowNumber, origin: topLeft))
p.perform(.mouseDown(button: .left, x: 200, y: 300, clickCount: 1, flags: 0))
p.perform(.mouseUp(button: .left, x: 200, y: 300, clickCount: 1, flags: 0))

// The hover first (some apps only take a press where the pointer is), then the press and release.
check("hover, press and release are sent", seen.map(\.type) == [.mouseMoved, .leftMouseDown, .leftMouseUp],
      "\(seen.map(\.type.rawValue))")
let names: [NSEvent.EventType: String] = [.mouseMoved: "hover", .leftMouseDown: "down", .leftMouseUp: "up"]
for e in seen {
    check("\(names[e.type] ?? "?"): AppKit puts it in the target window",
          e.windowNumber == win.windowNumber, "window \(e.windowNumber), want \(win.windowNumber)")
    // AppKit window coordinates start at the bottom left.
    let want = NSPoint(x: 200, y: win.frame.height - 300)
    check("\(names[e.type] ?? "?"): at the spot the step found (not the window corner)",
          abs(e.locationInWindow.x - want.x) < 0.5 && abs(e.locationInWindow.y - want.y) < 0.5,
          "\(e.locationInWindow), want \(want)")
}

// Normal delivery (through the pointer) leaves the window fields to the window server.
seen = []
let screen = Performer(route: Route(mode: .normal, pid: getpid(), windowNumber: win.windowNumber, origin: topLeft))
screen.perform(.mouseDown(button: .left, x: 200, y: 300, clickCount: 1, flags: 0))
screen.perform(.mouseUp(button: .left, x: 200, y: 300, clickCount: 1, flags: 0))
check("normal delivery: no window filled in", seen.count == 2 && seen.allSatisfy { $0.windowNumber == 0 })

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
