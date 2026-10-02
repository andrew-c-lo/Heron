import CoreGraphics
import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { failures += 1 }
}

// Record what would be sent: "down1 up1 down2 up2…" (button presses with their click count).
var sent: [String] = []
EventSynth.testSink = { e in
    let c = e.getIntegerValueField(.mouseEventClickState)
    switch e.type {
    case .leftMouseDown, .rightMouseDown: sent.append("down\(c)")
    case .leftMouseUp, .rightMouseUp: sent.append("up\(c)")
    case .leftMouseDragged: sent.append("drag")
    default: break
    }
}
ClickSpread.configure(enabled: false, radius: 0)
let p = Performer(route: Route(mode: .normal, pid: 0, windowNumber: 0, origin: .zero))
func run(_ actions: [StepAction], holdBeforeLast: Double = 0) -> String {
    sent = []
    for (i, a) in actions.enumerated() {
        if i == actions.count - 1 && holdBeforeLast > 0 { usleep(UInt32(holdBeforeLast * 1_000_000)) }
        p.perform(a)
    }
    return sent.joined(separator: " ")
}
let down1 = StepAction.mouseDown(button: .left, x: 10, y: 10, clickCount: 1, flags: 0)
let up1 = StepAction.mouseUp(button: .left, x: 10, y: 10, clickCount: 1, flags: 0)
let down2 = StepAction.mouseDown(button: .left, x: 10, y: 10, clickCount: 2, flags: 0)
let up2 = StepAction.mouseUp(button: .left, x: 10, y: 10, clickCount: 2, flags: 0)

DoubleClickEverywhere.configure(enabled: false)
check("off: a click stays single", run([down1, up1]) == "down1 up1", run([down1, up1]))

DoubleClickEverywhere.configure(enabled: true)
check("on: a recorded click becomes a double click", run([down1, up1]) == "down1 up1 down2 up2", run([down1, up1]))
check("on: a recorded double click stays a double click (not 4 presses)",
      run([down1, up1, down2, up2]) == "down1 up1 down2 up2", run([down1, up1, down2, up2]))
check("on: two separate clicks become two double clicks",
      run([down1, up1, down1, up1]) == "down1 up1 down2 up2 down1 up1 down2 up2")
let drag = StepAction.drag(button: .left, x: 60, y: 10)
let dragUp = StepAction.mouseUp(button: .left, x: 60, y: 10, clickCount: 1, flags: 0)
check("on: a drag stays a drag", run([down1, drag, dragUp]) == "down1 drag up1", run([down1, drag, dragUp]))
check("on: a long press stays a long press", run([down1, up1], holdBeforeLast: 0.6) == "down1 up1")
check("on: a click action (auto clicker, picture steps) becomes double",
      run([.click(button: .left, x: 10, y: 10, count: 1)]) == "down1 up1 down2 up2")
check("on: a triple click action stays triple",
      run([.click(button: .left, x: 10, y: 10, count: 3)]) == "down1 up1 down2 up2 down3 up3")
let rDown = StepAction.mouseDown(button: .right, x: 10, y: 10, clickCount: 1, flags: 0)
let rUp = StepAction.mouseUp(button: .right, x: 10, y: 10, clickCount: 1, flags: 0)
check("on: right clicks are doubled too", run([rDown, rUp]) == "down1 up1 down2 up2")
// Both presses of the doubled click land on the same spot (with click spread on).
ClickSpread.configure(enabled: true, radius: 15)
var spots: [CGPoint] = []
EventSynth.testSink = { e in if e.type == .leftMouseDown || e.type == .leftMouseUp { spots.append(e.location) } }
p.perform(.mouseDown(button: .left, x: 100, y: 100, clickCount: 1, flags: 0))
p.perform(.mouseUp(button: .left, x: 100, y: 100, clickCount: 1, flags: 0))
check("on: both clicks of the double land on the same spot", spots.count == 4 && Set(spots.map { "\($0)" }).count == 1,
      "\(spots)")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
