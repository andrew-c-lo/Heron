import Foundation
import CoreGraphics

/// Picture match scores seen during runs, per step: when the picture met its strictness (it was there) and the
/// best score when it didn't (a near-miss, or something else on screen). Written into each run report, they're
/// real-capture data for calibrating strictness (Check Macro) and for learning thresholds, instead of pasted
/// copies. A fixed-size random sample per step (reservoir sampling), so long runs cost no more memory.
enum ScoreLog {
    static let keep = 300
    private static let lock = NSLock()
    private nonisolated(unsafe) static var met: [UUID: Reservoir] = [:]
    private nonisolated(unsafe) static var below: [UUID: Reservoir] = [:]
    /// Where each step was found (window coordinates, with the window's size): data for suggesting search areas
    /// that ignore the odd stray match, instead of the union of everything.
    private nonisolated(unsafe) static var places: [UUID: (sample: [[Int]], seen: Int)] = [:]

    static func found(_ step: UUID, at r: CGRect, window: CGSize) {
        let row = [Int(r.midX), Int(r.midY), Int(r.width), Int(r.height), Int(window.width), Int(window.height)]
        lock.withLock {
            var p = places[step] ?? ([], 0)
            p.seen += 1
            if p.sample.count < keep { p.sample.append(row) } else {
                let j = Int.random(in: 0..<p.seen)
                if j < keep { p.sample[j] = row }
            }
            places[step] = p
        }
    }

    struct Reservoir {
        var sample: [Double] = []
        var seen = 0
        mutating func add(_ v: Double) {
            seen += 1
            if sample.count < ScoreLog.keep { sample.append(v) } else {
                let j = Int.random(in: 0..<seen)
                if j < ScoreLog.keep { sample[j] = v }
            }
        }
    }

    static func record(_ step: UUID, score: Double, met isMet: Bool) {
        lock.withLock {
            if isMet { met[step, default: Reservoir()].add(score) } else { below[step, default: Reservoir()].add(score) }
        }
    }

    static func reset(_ steps: [UUID]) {
        lock.withLock { for s in steps { met[s] = nil; below[s] = nil; places[s] = nil } }
    }

    /// For the run report: the sampled scores (two decimals) and how many looks they were drawn from.
    static func report(_ step: UUID) -> [String: Any]? {
        lock.withLock {
            guard met[step] != nil || below[step] != nil || places[step] != nil else { return nil }
            func r(_ x: Reservoir?) -> [String: Any] {
                ["looks": x?.seen ?? 0, "sample": (x?.sample ?? []).map { ($0 * 100).rounded() / 100 }]
            }
            var out: [String: Any] = ["met": r(met[step]), "below": r(below[step])]
            if let p = places[step] { out["places"] = ["seen": p.seen, "sample": p.sample, "columns": "midX, midY, w, h, windowW, windowH"] }
            return out
        }
    }
}
