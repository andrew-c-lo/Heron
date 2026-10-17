import AppKit

/// Labelled examples for the unstuck eval, collected while macros run: each time Heron gets stuck, the screen is
/// kept, and what happened next is written beside it:
/// - your own click inside the window within 30 s (a "rescue": what a person did on that screen), or
/// - one of the macro's steps firing within 10 s with no help from you ("resolved by itself": it was only waiting), or
/// - neither ("unresolved").
/// Everything stays on this Mac, in Heron's folder under Evals/unstuck/.
@MainActor
final class RescueCapture {
    static let rescueWindow = 30.0
    static let resolvedWindow = 10.0
    /// Kept at most (oldest go first), so the folder can't grow without limit.
    nonisolated static let keep = 2000

    private struct Pending {
        let macro: UUID
        let base: URL
        let window: CGRect
        let at: Date
        let stuckTap: CGPoint?
        var done = false
    }
    private var pending: Pending?

    nonisolated static var folder: URL { AppFolder.url.appendingPathComponent("Evals/unstuck", isDirectory: true) }

    /// A stuck screen was just saved. `window`: the window's frame on screen (null when that isn't known,
    /// e.g. reading from Android, where your clicks can't be placed on the picture).
    func stuck(_ screen: ScreenReader.WindowPixels, macro: UUID, window: CGRect, tap: CGPoint?) {
        finish(outcome: ["outcome": "unresolved"])
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = f.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let base = Self.folder.appendingPathComponent("\(macro.uuidString.prefix(8))-\(stamp)")
        pending = Pending(macro: macro, base: base, window: window, at: Date(), stuckTap: tap)
        DispatchQueue.global(qos: .utility).async {
            guard let cg = screen.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
            try? png.write(to: base.appendingPathExtension("png"))
            Self.prune()
        }
        // Nothing within the rescue window: write it down as unresolved.
        let started = pending!.at
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rescueWindow + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pending?.at == started else { return }
                self.finish(outcome: ["outcome": "unresolved"])
            }
        }
    }

    /// One of your own left clicks (screen points, top-left origin).
    func click(at p: CGPoint) {
        guard let w = pending, !w.done, !w.window.isNull, Date().timeIntervalSince(w.at) <= Self.rescueWindow,
              w.window.contains(p) else { return }
        finish(outcome: ["outcome": "rescue", "tap": [Int(p.x - w.window.minX), Int(p.y - w.window.minY)]])
    }

    /// A step of a running macro fired.
    func stepFired(macro: UUID, step: Int) {
        guard let w = pending, !w.done, w.macro == macro else { return }
        let after = Date().timeIntervalSince(w.at)
        if after <= Self.resolvedWindow { finish(outcome: ["outcome": "resolved", "step": step]) }
    }

    private func finish(outcome: [String: Any]) {
        guard var w = pending, !w.done else { return }
        w.done = true
        pending = w
        var label = outcome
        label["macro"] = w.macro.uuidString
        label["after"] = (Date().timeIntervalSince(w.at) * 10).rounded() / 10
        label["window"] = w.window.isNull ? NSNull() : [Int(w.window.width), Int(w.window.height)]
        if let t = w.stuckTap { label["stuckTap"] = [Int(t.x), Int(t.y)] }
        let url = w.base.appendingPathExtension("json")
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONSerialization.data(withJSONObject: label, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url) }
        }
    }

    nonisolated private static func prune() {
        let all = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in all.dropLast(keep) {
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.removeItem(at: old.deletingPathExtension().appendingPathExtension("json"))
        }
    }
}
