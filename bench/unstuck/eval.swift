// Scores "what to do on a stuck screen" strategies against the labelled screens in data/.
//   bench/unstuck/run.sh eval [strategy …]
//   strategies: fixed, wait, repeat-stop, model-point, model-choose, memory, model-memory, knn, logreg
// Writes results/<date>-<commit>.local.json (with the machine) and prints a summary table.
import AppKit
import Foundation
import FoundationModels
import Vision
import CreateML

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let strategies = Array(CommandLine.arguments.dropFirst(2)).isEmpty ? ["fixed", "wait"] : Array(CommandLine.arguments.dropFirst(2))

struct Candidate: Codable { let id: Int; let text: String; let box: [Int]; var score: Double? }
struct Screen: Codable { let file: String; let size: [Int]; let candidates: [Candidate] }
struct EvalLabel: Codable { let set: String?; let action: String; let target: [Int]?; let boxes: [[Int]]?; let unsafe: [Int]?; let note: String? }
struct Labels: Codable { let labels: [String: EvalLabel] }
struct MacroInfo: Codable { let macro: String; let window: [Double]?; let idleTap: [Double?]?; let intent: String? }

/// What a strategy decides on one screen: tap a point (window coordinates), or wait.
enum Decision { case tap(CGPoint), wait }

/// What a model strategy said, kept for the results file.
var modelNotes: [String: [String: Any]] = [:]
var modelErrors = 0

// MARK: Model strategies (Apple's on-device model, which reads images from macOS 27)

let instructions = """
    You help an automation tool get past a screen in a phone app when its normal steps found nothing to do. \
    You see one screenshot and the goal of the automation. Decide one of: \
    tap (one tap is needed to move on), \
    wait (an animation, transition or loading screen that finishes by itself), \
    stop (the goal is already reached, or the only taps available would spend money or otherwise be unsafe). \
    Never choose a button that buys something or spends real money.
    """
let defaultIntent = "Keep the app moving through its normal flow."

/// Text near the top is the phone's status bar (time, signal, battery), not something to tap.
func tappable(_ s: Screen) -> [Candidate] { s.candidates.filter { Double($0.box[1]) > Double(s.size[1]) * 0.09 } }

func image(_ s: Screen) -> CGImage {
    NSImage(contentsOf: root.appendingPathComponent("screens").appendingPathComponent(s.file))!
        .cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

/// The goal, plus what the macro's own steps tap to get past screens (from the frozen copy in data/macros/).
func goal(_ s: Screen) -> String {
    let prefix = String(s.file.prefix(8))
    let intent = macros[prefix]?.intent ?? defaultIntent
    let dir = root.appendingPathComponent("macros")
    guard let f = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.first(where: { $0.hasPrefix(prefix) }),
          let d = FileManager.default.contents(atPath: dir.appendingPathComponent(f).path),
          let m = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let steps = m["steps"] as? [[String: Any]] else { return intent }
    var words: [String] = []
    for st in steps {
        guard let a = st["action"] as? [String: Any], let fi = a["findImage"] as? [String: Any], let p = fi["_0"] as? [String: Any] else { continue }
        let w = ((p["text"] as? String) ?? (p["pictureWords"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        if w.count >= 2, w.count <= 20, w.rangeOfCharacter(from: .letters) != nil, !words.contains(w) { words.append(w) }
    }
    return intent + (words.isEmpty ? "" : " Its own steps tap things like: " + words.joined(separator: ", ") +
        ", plus numbered dice (it picks the highest) and coloured orbs. Dismissing results and reward screens with OK or Close is part of the goal.")
}

@available(macOS 27.0, *)
func askModel(_ strategy: String, _ s: Screen) async -> Decision {
    let intent = goal(s)
    let decision = DynamicGenerationSchema.Property(name: "decision", schema: DynamicGenerationSchema(name: "Decision", anyOf: ["tap", "wait", "stop"]))
    let reason = DynamicGenerationSchema.Property(name: "reason", description: "A few words on what the screen is", schema: DynamicGenerationSchema(type: String.self))
    let cands = tappable(s)
    var props = [reason, decision]
    var question = "Goal: \(intent)\nWhat should happen on this screen?"
    if strategy == "model-memory" {
        let mem = remembered(s)
        if !mem.isEmpty { question += "\nWhat happened on the most similar screens seen before, most similar first:\n" + mem.map(memoryLine).joined(separator: "\n") }
    }
    if strategy == "model-point" {
        props += [DynamicGenerationSchema.Property(name: "x", description: "With tap: how far across the screen to tap, 0 (left) to 1 (right)", schema: DynamicGenerationSchema(type: Double.self), isOptional: true),
                  DynamicGenerationSchema.Property(name: "y", description: "With tap: how far down the screen to tap, 0 (top) to 1 (bottom)", schema: DynamicGenerationSchema(type: Double.self), isOptional: true)]
    } else {
        props += [DynamicGenerationSchema.Property(name: "label", description: "With tap: the words on the thing to tap, as they appear (e.g. SKIP, OK)", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
                  DynamicGenerationSchema.Property(name: "button", description: "With tap: its number from the list", schema: DynamicGenerationSchema(type: Int.self), isOptional: true)]
        question += "\nThings on the screen that could be tapped (number: what it is). Text read off the screen, then pictures from the automation's own steps where they roughly match:\n"
            + cands.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
    }
    do {
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", properties: props), dependencies: [])
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
        let img = image(s)
        let r = try await session.respond(to: Prompt { Attachment(img); question }, schema: schema,
                                          options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200))
        let c = r.content
        let d = (try? c.value(String.self, forProperty: "decision")) ?? "wait"
        var note: [String: Any] = ["decision": d, "reason": (try? c.value(String.self, forProperty: "reason")) ?? ""]
        defer { modelNotes[strategy + "/" + s.file] = note }
        guard d == "tap" else { return .wait }
        if strategy == "model-point" {
            let x = (try? c.value(Double.self, forProperty: "x")) ?? 0.5, y = (try? c.value(Double.self, forProperty: "y")) ?? 0.5
            note["xy"] = [x, y]
            return .tap(CGPoint(x: x * Double(s.size[0]), y: y * Double(s.size[1])))
        }
        // The words it wants first (read text is often garbled, e.g. "D) SKIPÙ"), then the number as a fallback.
        func key(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let said = (try? c.value(String.self, forProperty: "label")).map(key) ?? ""
        // Exact words first; inside longer text only for 4+ letters ("ok" must not match "Dokkan").
        let byWords = said.count >= 2 ? (cands.first { key($0.text) == said }
            ?? cands.first { $0.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { key(String($0)) }.contains(said) }
            ?? (said.count >= 4 ? cands.first { key($0.text).contains(said) || said.contains(key($0.text)) && key($0.text).count >= 4 } : nil)) : nil
        let byNumber = (try? c.value(Int.self, forProperty: "button")).flatMap { id in cands.first { $0.id == id } }
        note["label"] = said
        // Only tap what it named and Heron can find: a number on its own has picked unrelated text ("103,303").
        guard let cand = said.count >= 2 ? byWords : byNumber else { note["button"] = "not found"; return .wait }
        note["button"] = "\(cand.id): \(cand.text)"
        return .tap(CGPoint(x: cand.box[0] + cand.box[2] / 2, y: cand.box[1] + cand.box[3] / 2))
    } catch {
        modelErrors += 1
        modelNotes[strategy + "/" + s.file] = ["error": "\(error)"]
        return .wait
    }
}

// MARK: Screen memory: what was right on similar earlier screens

/// Image fingerprints (Apple's Vision feature prints), one per screen, made once.
var fingerprints: [String: VNFeaturePrintObservation] = [:]
func fingerprint(_ s: Screen) -> VNFeaturePrintObservation? {
    if let f = fingerprints[s.file] { return f }
    let req = VNGenerateImageFeaturePrintRequest()
    try? VNImageRequestHandler(url: root.appendingPathComponent("screens").appendingPathComponent(s.file)).perform([req])
    fingerprints[s.file] = req.results?.first
    return fingerprints[s.file]
}
/// Screens are named <macro>-<time>; only screens from before this one may be remembered.
func time(_ file: String) -> Substring { file.dropFirst(9) }
/// Below this distance the most similar earlier screen had the same right answer every time (set on the practice set).
let sameScreen: Float = 0.30

struct Memory { let screen: Screen; let label: EvalLabel; let distance: Float }

/// The most similar earlier screens that have an answer, closest first.
func remembered(_ s: Screen, k: Int = 3) -> [Memory] {
    guard let fp = fingerprint(s) else { return [] }
    var out: [Memory] = []
    for o in screens where time(o.file) < time(s.file) {
        guard let l = labels[o.file], ["target", "anywhere", "wait", "none", "stop"].contains(l.action), let ofp = fingerprint(o) else { continue }
        var d: Float = 0
        guard (try? fp.computeDistance(&d, to: ofp)) != nil else { continue }
        out.append(Memory(screen: o, label: l, distance: d))
    }
    return Array(out.sorted { $0.distance < $1.distance }.prefix(k))
}

/// Where the right tap was on a remembered screen, and the words on it if any (what a deployment would have
/// stored: the outcome and what was tapped, not anyone's notes).
func rememberedTap(_ m: Memory) -> (point: CGPoint, words: String?)? {
    let byId = (m.label.target ?? []).compactMap { id in m.screen.candidates.first { $0.id == id } }.first
    let box = byId.map { rect($0.box) } ?? m.label.boxes?.first.map(rect)
    guard let b = box else { return nil }
    let c = CGPoint(x: b.midX, y: b.midY)
    let words = byId?.text ?? m.screen.candidates.first { $0.id < 100 && rect($0.box).contains(c) }?.text
    return (c, words)
}

func memoryLine(_ m: Memory) -> String {
    let how = m.distance < sameScreen ? "almost the same screen" : "a similar screen"
    switch m.label.action {
    case "target", "anywhere":
        if let t = rememberedTap(m) {
            return "- On \(how), tapping \(t.words.map { "“\($0)”" } ?? "the spot at \(Int(t.point.x)), \(Int(t.point.y))") moved it on."
        }
        return "- On \(how), one tap anywhere moved it on."
    case "wait": return "- On \(how), it finished by itself (no tap needed)."
    default: return "- On \(how), the right move was to stop: no tap."
    }
}

// MARK: Learned classifiers (ML): what kind of screen is this, from its fingerprint vector

/// The fingerprint as numbers (Vision feature print: a fixed-length float vector).
func vector(_ s: Screen) -> [Double] {
    guard let fp = fingerprint(s) else { return [] }
    return fp.data.withUnsafeBytes { raw -> [Double] in
        if fp.elementType == .float { return raw.bindMemory(to: Float.self).map(Double.init) }
        return raw.bindMemory(to: Double.self).map { $0 }
    }
}
let classes = ["target", "anywhere", "wait", "none", "stop"]
/// Earlier labelled screens: the only ones a model predicting `s` may learn from (rolling evaluation).
func history(_ s: Screen) -> [(Screen, EvalLabel)] {
    screens.filter { time($0.file) < time(s.file) }.compactMap { o in labels[o.file].flatMap { classes.contains($0.action) ? (o, $0) : nil } }
}
var classified: [String: [String: String]] = [:] // strategy -> file -> predicted class

/// The class a learned model predicts, then what that means on screen: a tap class taps (where the nearest
/// earlier screen of that class was tapped, else today's stuck-tap spot); the rest don't tap.
func act(_ predicted: String, _ s: Screen, near: [Memory]) -> Decision {
    switch predicted {
    case "target":
        if let m = near.first(where: { $0.label.action == "target" }), let t = rememberedTap(m) { return .tap(t.point) }
        return decide("fixed", s).0
    case "anywhere": return .tap(CGPoint(x: s.size[0] / 2, y: s.size[1] / 2))
    default: return .wait
    }
}

func knn(_ s: Screen, k: Int = 3) -> String? {
    let near = remembered(s, k: k)
    guard !near.isEmpty else { return nil }
    var votes: [String: Double] = [:]
    for m in near { votes[m.label.action, default: 0] += 1 / Double(max(m.distance, 0.01)) }
    return votes.max { $0.value < $1.value }?.key
}

func logreg(_ s: Screen) -> String? {
    let past = history(s)
    guard Set(past.map(\.1.action)).count >= 2 else { return past.first?.1.action }
    let dims = vector(s).count
    var cols: [String: MLDataValueConvertible] = ["label": past.map(\.1.action)]
    let rows = past.map { vector($0.0) }
    for d in 0..<dims { cols["f\(d)"] = rows.map { $0.count > d ? $0[d] : 0 } }
    guard let table = try? MLDataTable(dictionary: cols),
          let model = try? MLLogisticRegressionClassifier(trainingData: table, targetColumn: "label",
                                                          parameters: .init(maxIterations: 50, l1Penalty: 0, l2Penalty: 0.1)) else { return nil }
    let me = vector(s)
    var one: [String: MLDataValueConvertible] = [:]
    for d in 0..<dims { one["f\(d)"] = [me.count > d ? me[d] : 0] }
    guard let t = try? MLDataTable(dictionary: one), let p = try? model.predictions(from: t) else { return nil }
    return p.count > 0 ? p[0].stringValue : nil
}

/// Runs async work from this synchronous tool.
final class Box<T>: @unchecked Sendable { var v: T?; init() {} }
func blocking<T>(_ work: @escaping () async -> T) -> T {
    let b = Box<T>(), sem = DispatchSemaphore(value: 0)
    Task.detached { b.v = await work(); sem.signal() }
    sem.wait()
    return b.v!
}

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
    case "memory":
        // Do what was right on an almost identical earlier screen; otherwise don't tap.
        if let m = remembered(s, k: 1).first, m.distance < sameScreen {
            switch m.label.action {
            case "target": d = rememberedTap(m).map { .tap($0.point) } ?? .wait
            case "anywhere": d = .tap(CGPoint(x: s.size[0] / 2, y: s.size[1] / 2))
            default: d = .wait
            }
            modelNotes[strategy + "/" + s.file] = ["remembered": m.screen.file, "distance": m.distance, "action": m.label.action]
        } else { d = .wait }
    case "repeat-stop":
        // No model: today's stuck tap, but if this macro's previous stuck screen looked the same, the tap didn't
        // help and the run is over: stop.
        let prev = screens.filter { $0.file.prefix(8) == s.file.prefix(8) && time($0.file) < time(s.file) }.max { time($0.file) < time($1.file) }
        var dist: Float = .infinity
        if let p = prev, let a = fingerprint(s), let b = fingerprint(p) { try? a.computeDistance(&dist, to: b) }
        if dist < sameScreen {
            d = .wait
            modelNotes[strategy + "/" + s.file] = ["stopped": true, "distance": dist]
        } else { d = decide("fixed", s).0 }
    case "knn", "logreg":
        let predicted = (strategy == "knn" ? knn(s) : logreg(s)) ?? "?"
        classified[strategy, default: [:]][s.file] = predicted
        d = predicted == "?" ? decide("fixed", s).0 : act(predicted, s, near: remembered(s, k: 5))
        modelNotes[strategy + "/" + s.file] = ["predicted": predicted]
    case "model-point", "model-choose", "model-memory":
        guard #available(macOS 27.0, *), SystemLanguageModel.default.isAvailable else { fatalError("Needs macOS 27 with Apple Intelligence on") }
        d = blocking { await askModel(strategy, s) }
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

setvbuf(stdout, nil, _IOLBF, 0) // print each line as it's done
// Fingerprints are made here, on the main thread: Vision called from the model's background work deadlocked.
if strategies.contains(where: { $0.contains("memory") || $0 == "repeat-stop" || $0 == "knn" || $0 == "logreg" }) { for s in screens { _ = fingerprint(s) } }

var results: [String: Any] = [:]
print(String(format: "%-12@ %7@ %8@ %7@  %@", "strategy" as NSString, "scored" as NSString, "correct" as NSString, "unsafe" as NSString, "by label (correct/total)" as NSString))
for strategy in strategies {
    var sc = Score()
    var perScreen: [[String: Any]] = []
    for s in screens {
        guard let l = labels[s.file], ["target", "anywhere", "wait", "none", "stop"].contains(l.action) else { continue }
        // EVAL_SET=fresh scores only screens captured while playing; practice = the original, tuned-on set.
        if let only = ProcessInfo.processInfo.environment["EVAL_SET"], only != (l.set ?? "practice") { continue }
        let (d, secs) = decide(strategy, s)
        let r = score(d, l, s)
        sc.scored += 1; sc.correct += r.correct ? 1 : 0; sc.unsafe += r.unsafe ? 1 : 0
        let a = sc.byAction[l.action] ?? (0, 0); sc.byAction[l.action] = (a.0 + (r.correct ? 1 : 0), a.1 + 1)
        sc.latencies.append(secs)
        var row: [String: Any] = ["file": s.file, "label": l.action, "correct": r.correct, "unsafe": r.unsafe]
        if case .tap(let p) = d { row["tap"] = [Int(p.x), Int(p.y)] }
        if let n = modelNotes[strategy + "/" + s.file] { row["model"] = n }
        row["seconds"] = (secs * 100).rounded() / 100
        perScreen.append(row)
    }
    let lat = sc.latencies.sorted()
    let by = sc.byAction.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.0)/\($0.value.1)" }.joined(separator: ", ")
    print(String(format: "%-12@ %7d %7.0f%% %7d  %@  (median %.2fs, p95 %.2fs, errors %d)", strategy as NSString, sc.scored,
                 Double(sc.correct) / Double(max(1, sc.scored)) * 100, sc.unsafe, by as NSString,
                 lat.isEmpty ? 0 : lat[lat.count / 2], lat.isEmpty ? 0 : lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))], modelErrors))
    modelErrors = 0
    // Classification accuracy, and what each class was mistaken for.
    if let pred = classified[strategy] {
        var right = 0, total = 0
        var confusion: [String: [String: Int]] = [:]
        for (f, p) in pred { guard let l = labels[f]?.action else { continue }
            total += 1; right += p == l ? 1 : 0; confusion[l, default: [:]][p, default: 0] += 1 }
        print(String(format: "    classified right: %d/%d. ", right, total) +
              confusion.sorted { $0.key < $1.key }.map { "\($0.key) -> " + $0.value.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") }.joined(separator: "; "))
    }
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
