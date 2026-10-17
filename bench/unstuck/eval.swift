// Scores "what to do on a stuck screen" strategies against the labelled screens in data/.
//   bench/unstuck/run.sh eval [strategy …]      strategies: fixed, wait (more to come)
// Writes results/<date>-<commit>.local.json (with the machine) and prints a summary table.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let strategies = Array(CommandLine.arguments.dropFirst(2)).isEmpty ? ["fixed", "wait"] : Array(CommandLine.arguments.dropFirst(2))

struct Candidate: Codable { let id: Int; let text: String; let box: [Int] }
struct Screen: Codable { let file: String; let size: [Int]; let candidates: [Candidate] }
struct EvalLabel: Codable { let action: String; let target: [Int]?; let boxes: [[Int]]?; let unsafe: [Int]?; let note: String? }
struct Labels: Codable { let labels: [String: EvalLabel] }
struct MacroInfo: Codable { let macro: String; let window: [Double]?; let idleTap: [Double?]? }

/// What a strategy decides on one screen: tap a point (window coordinates), or wait.
enum Decision { case tap(CGPoint), wait }

let screens = try JSONDecoder().decode([Screen].self, from: Data(contentsOf: root.appendingPathComponent("candidates.json")))
let labels = try JSONDecoder().decode(Labels.self, from: Data(contentsOf: root.appendingPathComponent("labels.json"))).labels
let macros = try JSONDecoder().decode([String: MacroInfo].self, from: Data(contentsOf: root.appendingPathComponent("macros.json")))

func rect(_ b: [Int]) -> CGRect { CGRect(x: b[0], y: b[1], width: b[2], height: b[3]) }

func decide(_ strategy: String, _ s: Screen) -> (Decision, Double) {
    let t = Date()
    let d: Decision
    switch strategy {
    case "fixed":
        // Today's behaviour: the macro's own stuck-tap spot, resized to this screen.
        let m = macros[String(s.file.prefix(8))]
        if let spot = m?.idleTap, let x = spot.first ?? nil, let y = spot.last ?? nil {
            let ref = m?.window.map { CGSize(width: $0[0], height: $0[1]) }
            let fit = WindowFit.between(ref, CGSize(width: s.size[0], height: s.size[1]), emulator: m?.macro.contains("Bluestax") == true)
            d = .tap(fit.point(CGPoint(x: x, y: y)))
        } else { d = .wait }
    case "wait":
        d = .wait
    default:
        fatalError("unknown strategy \(strategy)")
    }
    return (d, Date().timeIntervalSince(t))
}

struct Score { var scored = 0, correct = 0, unsafe = 0; var byAction: [String: (Int, Int)] = [:]; var latencies: [Double] = [] }

func score(_ d: Decision, _ l: EvalLabel, _ s: Screen) -> (correct: Bool, unsafe: Bool) {
    let boxes = (l.target ?? []).compactMap { id in s.candidates.first { $0.id == id }.map { rect($0.box) } }
        + (l.boxes ?? []).map(rect)
    let forbidden = (l.unsafe ?? []).compactMap { id in s.candidates.first { $0.id == id }.map { rect($0.box) } }
    switch (l.action, d) {
    case ("target", .tap(let p)): return (boxes.contains { $0.contains(p) }, false)
    case ("target", .wait): return (false, false)
    case ("anywhere", .tap): return (true, false)
    case ("anywhere", .wait): return (false, false)
    case ("wait", _): return (true, false) // owner's rule: a tap during an animation is harmless
    case ("none", .wait), ("stop", .wait): return (true, false)
    case ("stop", .tap): return (false, false) // tapping on keeps playing a run that should have ended
    case ("none", .tap(let p)): return (false, forbidden.contains { $0.insetBy(dx: -4, dy: -4).contains(p) })
    default: return (false, false)
    }
}

var results: [String: Any] = [:]
print(String(format: "%-8@ %7@ %8@ %7@  %@", "strategy" as NSString, "scored" as NSString, "correct" as NSString, "unsafe" as NSString, "by label (correct/total)" as NSString))
for strategy in strategies {
    var sc = Score()
    var perScreen: [[String: Any]] = []
    for s in screens {
        guard let l = labels[s.file], ["target", "anywhere", "wait", "none", "stop"].contains(l.action) else { continue }
        let (d, secs) = decide(strategy, s)
        let r = score(d, l, s)
        sc.scored += 1; sc.correct += r.correct ? 1 : 0; sc.unsafe += r.unsafe ? 1 : 0
        let a = sc.byAction[l.action] ?? (0, 0); sc.byAction[l.action] = (a.0 + (r.correct ? 1 : 0), a.1 + 1)
        sc.latencies.append(secs)
        var row: [String: Any] = ["file": s.file, "label": l.action, "correct": r.correct, "unsafe": r.unsafe]
        if case .tap(let p) = d { row["tap"] = [Int(p.x), Int(p.y)] }
        perScreen.append(row)
    }
    let lat = sc.latencies.sorted()
    let by = sc.byAction.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", ")
    print(String(format: "%-8@ %7d %7.0f%% %7d  %@", strategy as NSString, sc.scored, Double(sc.correct) / Double(max(1, sc.scored)) * 100, sc.unsafe, by as NSString))
    results[strategy] = ["scored": sc.scored, "correct": sc.correct, "unsafe": sc.unsafe,
                         "byLabel": Dictionary(uniqueKeysWithValues: sc.byAction.map { ($0.key, ["correct": $0.value.0, "total": $0.value.1]) }),
                         "latencyMedian": lat.isEmpty ? 0 : lat[lat.count / 2], "latencyP95": lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))],
                         "screens": perScreen]
}

// Saved with what produced it: machine, OS, commit, label counts.
func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let o = Pipe(); p.standardOutput = o; try? p.run(); p.waitUntilExit()
    return String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}
let commit = sh("git rev-parse --short HEAD") + (sh("git status --porcelain Sources bench | head -1").isEmpty ? "" : "+dirty")
let meta: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "commit": commit,
                           "machine": sh("sysctl -n machdep.cpu.brand_string") + ", " + sh("sysctl -n hw.memsize | awk '{print $1/1073741824 \" GB\"}'"),
                           "os": ProcessInfo.processInfo.operatingSystemVersionString,
                           "labelled": labels.values.reduce(into: [String: Int]()) { $0[$1.action, default: 0] += 1 }]
let resultsDir = root.deletingLastPathComponent().appendingPathComponent("results")
try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
let file = resultsDir.appendingPathComponent("\(stamp)-\(commit).local.json")
try JSONSerialization.data(withJSONObject: ["meta": meta, "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: file)
print("saved \(file.path)")
