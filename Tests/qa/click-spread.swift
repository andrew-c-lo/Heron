import CoreGraphics
import Foundation
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail)); if !ok { failures += 1 }
}
func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

ClickSpread.configure(enabled: true, radius: 15)
let p = Performer(route: Route(mode: .normal, pid: 0, windowNumber: 0, origin: CGPoint(x: 1000, y: 500)))
let target = CGPoint(x: 1200, y: 800)

var ds: [Double] = []
var quadrants = [0, 0, 0, 0]
for _ in 0..<20_000 {
    let q = p.spreadPoint(target, newPress: true, absolute: false)
    let d = dist(q, target); ds.append(d)
    quadrants[(q.x >= target.x ? 1 : 0) + (q.y >= target.y ? 2 : 0)] += 1
}
check("every click lands within 15 points", ds.max()! <= 15.0001, String(format: "max %.2f", ds.max()!))
let mean = ds.reduce(0, +) / Double(ds.count)
check("spread evenly over the circle (mean distance ≈ 10 = 2/3 of 15)", abs(mean - 10) < 0.3, String(format: "mean %.2f", mean))
check("no direction favored", quadrants.allSatisfy { abs($0 - 5000) < 300 }, "\(quadrants)")
let inner = ds.filter { $0 <= 7.5 }.count
check("not bunched in the middle (~25% within half the radius)", abs(Double(inner) / 20_000 - 0.25) < 0.02, "\(inner)")

// A press and its release (and drags) share the spot; the next press of a double-click too.
let down = p.spreadPoint(target, newPress: true, absolute: false)
let drag = p.spreadPoint(CGPoint(x: target.x + 40, y: target.y), newPress: false, absolute: false)
let up = p.spreadPoint(target, newPress: false, absolute: false)
check("press and release land on the same spot", down == up)
check("a drag keeps the press's offset (swipe shape intact)", abs((drag.x - down.x) - 40) < 0.001 && abs(drag.y - down.y) < 0.001)
let second = p.spreadPoint(target, newPress: false, absolute: false)
check("2nd press of a double-click reuses the spot", second == down)

check("clicks at the user's own cursor never move", p.spreadPoint(target, newPress: true, absolute: true) == target)

// Picture clicks stay on the picture: a 110×30 button found at (150, 290) in the window.
p.spreadBounds = CGRect(x: 150, y: 290, width: 110, height: 30)
let screenRect = CGRect(x: 1150, y: 790, width: 110, height: 30)
var allInside = true
for _ in 0..<5000 {
    let q = p.spreadPoint(CGPoint(x: screenRect.midX, y: screenRect.midY), newPress: true, absolute: false)
    if !screenRect.insetBy(dx: 1.9, dy: 1.9).contains(q) { allInside = false }
}
check("clicks on a found 110×30 button always stay on it", allInside)
p.spreadBounds = nil

ClickSpread.configure(enabled: false, radius: 15)
check("switched off: clicks land exactly on target", p.spreadPoint(target, newPress: true, absolute: false) == target)
print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
