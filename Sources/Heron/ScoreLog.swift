import Foundation

/// Picture match scores seen during runs, per step: when the picture met its strictness (it was there) and the
/// best score when it didn't (a near-miss, or something else on screen). Written into each run report, they're
/// real-capture data for calibrating strictness (Check Macro) and for learning thresholds, instead of pasted
/// copies. A fixed-size random sample per step (reservoir sampling), so long runs cost no more memory.
enum ScoreLog {
    static let keep = 300
    private static let lock = NSLock()
    private nonisolated(unsafe) static var met: [UUID: Reservoir] = [:]
    private nonisolated(unsafe) static var below: [UUID: Reservoir] = [:]

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
        lock.withLock { for s in steps { met[s] = nil; below[s] = nil } }
    }

    /// For the run report: the sampled scores (two decimals) and how many looks they were drawn from.
    static func report(_ step: UUID) -> [String: Any]? {
        lock.withLock {
            guard met[step] != nil || below[step] != nil else { return nil }
            func r(_ x: Reservoir?) -> [String: Any] {
                ["looks": x?.seen ?? 0, "sample": (x?.sample ?? []).map { ($0 * 100).rounded() / 100 }]
            }
            return ["met": r(met[step]), "below": r(below[step])]
        }
    }
}
