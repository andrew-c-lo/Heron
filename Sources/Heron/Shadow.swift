import AppKit
import Vision
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Shadow mode: on each stuck screen, what two advisers *would* have done, written beside the screen
/// (`<screen>.shadow.json` in Evals/unstuck/), never acted on. What actually happened next is written by
/// `RescueCapture`; comparing the two (bench/unstuck: `run.sh collect`, then the `shadow-*` strategies) measures
/// the advisers on real use, with no risk:
/// - **knn**: a learned classifier. The 3 most similar earlier stuck screens with a known outcome (your rescue
///   tap, a step firing by itself, or you stopping the run) vote, closer ones counting more.
/// - **model**: Apple's on-device model (macOS 27 with Apple Intelligence) looks at the screen and the macro's
///   own steps and answers tap / wait / stop, naming what to tap.
enum ShadowAdvisor {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var prints: [String: VNFeaturePrintObservation] = [:]
    private nonisolated(unsafe) static var modelBusy = false

    static func advise(_ screen: ScreenReader.WindowPixels, macro: Macro, base: URL) {
        Task.detached(priority: .utility) {
            let started = Date()
            var out: [String: Any] = ["macro": macro.id.uuidString]
            guard let fp = StuckGuard.fingerprint(screen) else { return }
            out["knn"] = knn(fp, excluding: base.lastPathComponent)
            if let m = await askModel(screen, macro: macro) { out["model"] = m }
            if let kind = await screenKind(screen) { out["screen"] = kind }
            out["seconds"] = (Date().timeIntervalSince(started) * 100).rounded() / 100
            if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
                try? d.write(to: base.appendingPathExtension("shadow.json"))
            }
        }
    }

    // MARK: Learned classifier (nearest neighbours over labelled stuck screens)

    /// What each recorded outcome means as a decision.
    static func decision(forOutcome o: String) -> String? {
        switch o { case "rescue": "tap"; case "resolved": "wait"; case "stopped": "stop"; default: nil }
    }

    private static func knn(_ fp: VNFeaturePrintObservation, excluding me: String, k: Int = 3) -> [String: Any] {
        let dir = RescueCapture.folder
        let labelled = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".json") && !$0.lastPathComponent.hasSuffix(".shadow.json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(400)
        var near: [(d: Float, decision: String, tap: [Int]?)] = []
        for url in labelled {
            let name = url.deletingPathExtension().lastPathComponent
            guard name != me, let data = try? Data(contentsOf: url),
                  let label = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let o = label["outcome"] as? String, let dec = decision(forOutcome: o),
                  let other = print(for: url.deletingPathExtension().appendingPathExtension("png")) else { continue }
            var d: Float = .infinity
            try? fp.computeDistance(&d, to: other)
            near.append((d, dec, label["tap"] as? [Int]))
        }
        near.sort { $0.d < $1.d }
        let top = near.prefix(k)
        guard !top.isEmpty else { return ["decision": "none known", "examples": 0] }
        var votes: [String: Float] = [:]
        for n in top { votes[n.decision, default: 0] += 1 / max(n.d, 0.01) }
        let best = votes.max { $0.value < $1.value }!.key
        var out: [String: Any] = ["decision": best, "examples": near.count, "nearest": (top.first!.d * 100).rounded() / 100]
        if best == "tap", let t = top.first(where: { $0.decision == "tap" })?.tap { out["tap"] = t }
        return out
    }

    /// Your own tap on a screen like this one: the nearest earlier stuck screen of the same macro with a known
    /// outcome, when that was a rescue (you tapped past it) and it's the same screen (StuckGuard.sameScreen).
    /// Measured online in bench/tapspot/learned.swift: on the first 24 outcomes, 2 right, 1 elsewhere, and no tap
    /// on any screen that moved on by itself. Window points, scaled to the window's size now.
    static func learnedTap(_ fp: VNFeaturePrintObservation, macro: UUID, window: CGSize) -> CGPoint? {
        let prefix = String(macro.uuidString.prefix(8))
        let labelled = ((try? FileManager.default.contentsOfDirectory(at: RescueCapture.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".shadow.json") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(400)
        var best: (d: Float, label: [String: Any])?
        for url in labelled {
            guard let data = try? Data(contentsOf: url),
                  let label = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let o = label["outcome"] as? String, decision(forOutcome: o) != nil,
                  let other = print(for: url.deletingPathExtension().appendingPathExtension("png")) else { continue }
            var d: Float = .infinity
            try? fp.computeDistance(&d, to: other)
            if d < (best?.d ?? .infinity) { best = (d, label) }
        }
        guard let best, best.d < StuckGuard.sameScreen, best.label["outcome"] as? String == "rescue",
              let tap = best.label["tap"] as? [Double], tap.count == 2 else { return nil }
        let was = (best.label["window"] as? [Double]).map { CGSize(width: $0[0], height: $0[1]) } ?? window
        return CGPoint(x: tap[0] * window.width / max(1, was.width), y: tap[1] * window.height / max(1, was.height))
    }

    /// A saved screen's fingerprint, made once.
    private static func print(for png: URL) -> VNFeaturePrintObservation? {
        let key = png.lastPathComponent
        if let p = lock.withLock({ prints[key] }) { return p }
        let req = VNGenerateImageFeaturePrintRequest()
        guard (try? VNImageRequestHandler(url: png).perform([req])) != nil, let p = req.results?.first else { return nil }
        lock.withLock { prints[key] = p }
        return p
    }

    // MARK: On-device model

    /// Text on the screen and the macro's own pictures where they roughly match: the things that could be tapped.
    static func candidates(_ screen: ScreenReader.WindowPixels, macro: Macro) -> [(id: Int, text: String, box: CGRect)] {
        var out: [(Int, String, CGRect)] = []
        for (i, l) in TextFinder.read(screen).enumerated()
            where l.text.count <= 24 && l.rect.minY > Double(screen.height) * 0.09 {
            out.append((i + 1, l.text, l.rect))
        }
        let scene = TemplateMatcher.Scene(rgba: screen.rgba, width: screen.width, height: screen.height)
        var n = 101
        for (i, s) in macro.steps.enumerated() where s.enabled {
            guard case .findImage(var p) = s.action, !p.png.isEmpty else { continue }
            let words = (p.pictureWords ?? p.text ?? "").trimmingCharacters(in: .whitespaces)
            p.text = nil
            guard let l = Lookup(step: p, reference: macro.target.windowSize, emulator: macro.target.isAndroidEmulator),
                  let m = l.matchPicture(in: screen, scene: scene), m.score >= 0.55 else { continue }
            out.append((n, (words.isEmpty ? "\(p.pictureColor ?? "") picture" : "picture “\(words)”") + " (step \(i + 1))", m.rect))
            n += 1
        }
        return out
    }

    /// The macro's goal, from what its own steps tap.
    static func goal(_ macro: Macro) -> String {
        var words: [String] = []
        for s in macro.steps {
            guard case .findImage(let p) = s.action else { continue }
            let w = (p.text ?? p.pictureWords ?? "").trimmingCharacters(in: .whitespaces)
            if w.count >= 2, w.count <= 20, w.rangeOfCharacter(from: .letters) != nil, !words.contains(w) { words.append(w) }
        }
        return "Keep the automation “\(macro.name)” going." + (words.isEmpty ? "" : " Its own steps tap things like: " + words.joined(separator: ", ") + ".")
    }

    private static func askModel(_ screen: ScreenReader.WindowPixels, macro: Macro) async -> [String: Any]? {
        #if canImport(FoundationModels)
        guard #available(macOS 27, *), Assistant.modelAvailable, let image = screen.cgImage else { return nil }
        guard lock.withLock({ () -> Bool in if modelBusy { return false }; modelBusy = true; return true }) else { return nil }
        defer { lock.withLock { modelBusy = false } }
        let cands = candidates(screen, macro: macro)
        let instructions = """
            You help an automation tool get past a screen in an app when its normal steps found nothing to do. \
            You see one screenshot and the goal of the automation. Decide one of: tap (one tap is needed to move on), \
            wait (an animation, transition or loading screen that finishes by itself), stop (the goal is already reached, \
            or the only taps available would spend money or otherwise be unsafe). Never choose something that buys or spends.
            """
        let question = "Goal: \(goal(macro))\nWhat should happen on this screen?\nThings on the screen that could be tapped (number: what it is):\n"
            + cands.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
        do {
            let props = [
                DynamicGenerationSchema.Property(name: "reason", description: "A few words on what the screen is", schema: DynamicGenerationSchema(type: String.self)),
                DynamicGenerationSchema.Property(name: "decision", schema: DynamicGenerationSchema(name: "Decision", anyOf: ["tap", "wait", "stop"])),
                DynamicGenerationSchema.Property(name: "label", description: "With tap: the words on the thing to tap, as they appear", schema: DynamicGenerationSchema(type: String.self), isOptional: true),
            ]
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", properties: props), dependencies: [])
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let started = Date()
            let r = try await session.respond(to: Prompt { Attachment(image); question }, schema: schema,
                                              options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 200))
            let c = r.content
            let decision = (try? c.value(String.self, forProperty: "decision")) ?? "wait"
            var out: [String: Any] = ["decision": decision, "reason": (try? c.value(String.self, forProperty: "reason")) ?? "",
                                      "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100]
            if decision == "tap", let said = try? c.value(String.self, forProperty: "label") {
                out["label"] = said
                // Only something it named and that can be found counts as a tap.
                if let hit = match(said, in: cands) { out["tap"] = [Int(hit.box.midX), Int(hit.box.midY)]; out["matched"] = hit.text }
                else { out["decision"] = "wait"; out["unmatched"] = true }
            }
            return out
        } catch {
            return ["error": "\(error)"]
        }
        #else
        return nil
        #endif
    }

    /// Kinds of screen the on-device model is asked to tell apart (any app): what a stuck screen is says more
    /// about what to do than where to tap.
    static let screenKinds = ["store", "results", "loading", "battle", "menu", "map", "dialog", "other"]

    /// The on-device model's label for a screen, nil where the model isn't available. Measured in
    /// bench/screenkind against the labelled stuck screens before anything relies on it.
    static func screenKind(_ screen: ScreenReader.WindowPixels) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 27, *), Assistant.modelAvailable, let image = screen.cgImage else { return nil }
        let instructions = """
            You label app screenshots by the kind of screen. store: buying things, prices, packs, currency offers. \
            results: rewards or a summary after something finished. loading: a loading screen, transition, or blank. \
            battle: fighting, attacks, effects, a fight in progress. menu: lists, settings, navigation, choosing a \
            level or item. map: a board or world map to move around. dialog: a popup or message asking to confirm or \
            dismiss, or story dialogue. other: none of these.
            """
        do {
            let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Kind", properties: [
                DynamicGenerationSchema.Property(name: "kind", schema: DynamicGenerationSchema(name: "ScreenKind", anyOf: screenKinds)),
            ]), dependencies: [])
            let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
            let r = try await session.respond(to: Prompt { Attachment(image); "What kind of screen is this?" }, schema: schema,
                                              options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 40))
            return try? r.content.value(String.self, forProperty: "kind")
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    /// The candidate whose words are the ones named: exact first, a whole word next, inside longer text for 4+ letters.
    static func match(_ said: String, in cands: [(id: Int, text: String, box: CGRect)]) -> (id: Int, text: String, box: CGRect)? {
        func key(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        let k = key(said)
        guard k.count >= 2 else { return nil }
        if let c = cands.first(where: { key($0.text) == k }) { return c }
        if let c = cands.first(where: { $0.text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { key(String($0)) }.contains(k) }) { return c }
        return k.count >= 4 ? cands.first { key($0.text).contains(k) } : nil
    }
}
