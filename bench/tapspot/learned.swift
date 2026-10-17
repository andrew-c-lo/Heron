// Learned rescue taps, measured online: walk the stuck screens Heron kept (Evals/unstuck, local) in time order,
// and on each one predict from earlier screens only (as the app would have, at that moment): the nearest earlier
// screen of the same macro that has an outcome; when it's a rescue (your own tap) closer than `sameScreen`,
// tap where you tapped. Scored against what really happened next:
//   rescue    correct if the predicted tap is within 60 pt of your actual tap; missed if nothing predicted
//   resolved  (a step fired by itself) a predicted tap was unnecessary
//   stopped   (you stopped the run) a predicted tap was wrong
// Usage: swiftc -O -o /tmp/learned bench/tapspot/learned.swift && /tmp/learned "<Heron>/Evals/unstuck"
import AppKit
import Vision

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let thresholds: [Float] = [0.15, 0.20, 0.25, 0.30, 0.35]

struct Example { let name: String; let macro: String; let outcome: String; let tap: CGPoint?; let fp: VNFeaturePrintObservation }
var examples: [Example] = []
for f in ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
where f.hasSuffix(".json") && !f.hasSuffix(".shadow.json") {
    let base = dir.appendingPathComponent(String(f.dropLast(5)))
    guard let d = try? Data(contentsOf: dir.appendingPathComponent(f)),
          let label = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let outcome = label["outcome"] as? String, outcome != "unresolved" else { continue }
    let req = VNGenerateImageFeaturePrintRequest()
    guard (try? VNImageRequestHandler(url: base.appendingPathExtension("png")).perform([req])) != nil, let fp = req.results?.first else { continue }
    let tap = (label["tap"] as? [Double]).map { CGPoint(x: $0[0], y: $0[1]) }
    // Names start with the macro id and then the time, so sorting by name within a macro is time order.
    examples.append(Example(name: f, macro: String(f.prefix(8)), outcome: outcome, tap: tap, fp: fp))
}
examples.sort { $0.name.dropFirst(9) < $1.name.dropFirst(9) }
print("stuck screens with an outcome: \(examples.count) (" + ["rescue", "resolved", "stopped"].map { o in "\(examples.filter { $0.outcome == o }.count) \(o)" }.joined(separator: ", ") + ")")

for t in thresholds {
    var right = 0, wrongSpot = 0, missed = 0, unneeded = 0, wrongStop = 0
    for (i, e) in examples.enumerated() {
        var best: (d: Float, ex: Example)?
        for prev in examples[..<i] where prev.macro == e.macro {
            var d: Float = .infinity
            try? e.fp.computeDistance(&d, to: prev.fp)
            if d < (best?.d ?? .infinity) { best = (d, prev) }
        }
        let predicted: CGPoint? = (best.map { $0.d < t && $0.ex.outcome == "rescue" } ?? false) ? best!.ex.tap : nil
        switch e.outcome {
        case "rescue":
            if let p = predicted, let real = e.tap { if hypot(p.x - real.x, p.y - real.y) <= 60 { right += 1 } else { wrongSpot += 1 } }
            else { missed += 1 }
        case "resolved": if predicted != nil { unneeded += 1 }
        default: if predicted != nil { wrongStop += 1 }
        }
    }
    print(String(format: "  same screen < %.2f: rescues right %d, wrong spot %d, not predicted %d | unneeded taps %d | taps where you stopped %d",
                 t, right, wrongSpot, missed, unneeded, wrongStop))
}
