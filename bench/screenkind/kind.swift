// Does Apple's on-device model tell what kind of screen a stuck screen is? Truth comes from the notes on the
// labelled stuck screens (bench/unstuck/data/labels.json, local), mapped to kinds by keyword; extra screens can
// be given as file=kind pairs. Reports accuracy, a confusion list, and store precision/recall (the case that
// matters: a store screen must never get a blind tap). Results go to bench/screenkind/results/.
//   bench/screenkind/run.sh [file=kind ...]
import AppKit

let data = URL(fileURLWithPath: CommandLine.arguments[1])
let outDir = URL(fileURLWithPath: CommandLine.arguments[2])

func kind(fromNote n: String) -> String? {
    let s = n.lowercased()
    if s.contains("shop") || s.contains("price") { return "store" }
    if s.contains("dice") || s.contains("map") { return "map" }
    if s.contains("stage list") || s.contains("cleared stage") || s.contains("same screen as before") { return "menu" }
    if s.contains("dialogue") || s.contains("popup") { return "dialog" }
    if s.contains("result") || s.contains("reward") { return "results" }
    if s.contains("loading") || s.contains("transition") || s.contains("flash") { return "loading" }
    if ["cutscene", "animation", "k.o", "skill", "attack", "damage", "boss", "vs intro", "warning"].contains(where: s.contains) { return "battle" }
    return nil
}

var items: [(URL, String)] = []
let labels = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("labels.json")))) as? [String: Any])?["labels"] as? [String: [String: Any]] ?? [:]
for (f, l) in labels.sorted(by: { $0.key < $1.key }) {
    if let note = l["note"] as? String, let k = kind(fromNote: note) { items.append((data.appendingPathComponent("screens").appendingPathComponent(f), k)) }
}
for a in CommandLine.arguments.dropFirst(3) {
    let parts = a.split(separator: "=", maxSplits: 1).map(String.init)
    if parts.count == 2 { items.append((URL(fileURLWithPath: parts[0]), parts[1])) }
}

func pixels(_ cg: CGImage) -> ScreenReader.WindowPixels {
    let w = cg.width, h = cg.height
    var rgba = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ScreenReader.WindowPixels(rgba: rgba, width: w, height: h)
}

var out = ""
func say(_ s: String) { print(s); out += s + "\n" }
say("Screen kind (on-device model)  \(Date())  screens: \(items.count)")
let sem = DispatchSemaphore(value: 0)
Task {
    var right = 0, n = 0, secs = 0.0
    var store = (tp: 0, fp: 0, fn: 0)
    var confusion: [String: Int] = [:]
    for (url, truth) in items {
        guard let cg = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
        let t = Date()
        guard let said = await ShadowAdvisor.screenKind(pixels(cg)) else { say("model not available"); break }
        secs += Date().timeIntervalSince(t); n += 1
        if said == truth { right += 1 } else { confusion["\(truth) → \(said)", default: 0] += 1 }
        if said == "store" && truth == "store" { store.tp += 1 } else if said == "store" { store.fp += 1 } else if truth == "store" { store.fn += 1 }
    }
    if n > 0 {
        say("accuracy \(right)/\(n), \(String(format: "%.2f", secs / Double(n))) s a screen")
        say("store: \(store.tp) found, \(store.fn) missed, \(store.fp) false alarms")
        for (k, v) in confusion.sorted(by: { $0.value > $1.value }) { say("  \(k): \(v)") }
    }
    sem.signal()
}
sem.wait()
let commit = (try? String(contentsOfFile: ".git/HEAD"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
out += "\nmachine: \(Host.current().localizedName ?? "?"), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(commit)\n"
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try! out.write(to: outDir.appendingPathComponent("screenkind-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")).txt"), atomically: true, encoding: .utf8)
