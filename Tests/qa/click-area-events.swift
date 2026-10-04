import AppKit
import SwiftUI
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { failures += 1 }
}
func close(_ a: CGRect?, _ b: CGRect) -> Bool {
    guard let a else { return false }
    return abs(a.minX - b.minX) < 0.011 && abs(a.minY - b.minY) < 0.011 && abs(a.width - b.width) < 0.011 && abs(a.height - b.height) < 0.011
}

// The picture is 200×100 points; the input view covers it exactly.
let size = CGSize(width: 200, height: 100)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 200, height: 100), styleMask: [.borderless],
                      backing: .buffered, defer: false)
let view = ClickAreaInput.InputView(frame: NSRect(origin: .zero, size: size))
window.contentView = view
window.orderFrontRegardless() // events are only delivered to a window that's on screen (here, far off to the side)
var result: CGRect?
var live: [CGRect] = []
view.onChange = { a, b in live.append(ClickAreaEditor.area(from: a, to: b, in: size)) }
view.onEnd = { a, b in result = ClickAreaEditor.area(from: a, to: b, in: size) }

/// Sends a mouse event at a point in the view's own (top-left) coordinates.
func send(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) {
    let inWindow = NSPoint(x: x, y: size.height - y) // the window is bottom-left based
    let e = NSEvent.mouseEvent(with: type, location: inWindow, modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    window.sendEvent(e)
}

// 1. A real drag from (20,10) to (120,60): the box is 0.1–0.6 across and 0.1–0.6 down.
send(.leftMouseDown, 20, 10); send(.leftMouseDragged, 70, 30); send(.leftMouseDragged, 120, 60); send(.leftMouseUp, 120, 60)
check("a drag sets the box where it was dragged", close(result, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)), "\(String(describing: result))")
check("…and the box follows the pointer while dragging", live.count == 3 && close(live.last, CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))

// 2. Press and release at different spots with no drag events in between (some input devices and tools).
result = nil
send(.leftMouseDown, 150, 20); send(.leftMouseUp, 190, 80)
check("press here, release there still makes a box", close(result, CGRect(x: 0.75, y: 0.2, width: 0.2, height: 0.6)), "\(String(describing: result))")

// 3. A click: a small box centred on that spot.
result = nil
send(.leftMouseDown, 100, 50); send(.leftMouseUp, 100, 50)
check("a click sets a precise spot", result.map { abs($0.midX - 0.5) < 0.01 && abs($0.midY - 0.5) < 0.01 && $0.width < 0.1 } ?? false, "\(String(describing: result))")

// 4. Dragging past the edge stays on the picture.
result = nil
send(.leftMouseDown, 180, 90); send(.leftMouseDragged, 260, 140); send(.leftMouseUp, 260, 140)
check("dragging past the edge stays on the picture", result.map { $0.maxX <= 1.0001 && $0.maxY <= 1.0001 && $0.minX > 0.85 } ?? false, "\(String(describing: result))")

print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
