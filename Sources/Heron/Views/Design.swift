import SwiftUI

/// One motion language for the whole app (Apple's "snap" curve for UI changes, a spring-like curve for
/// reveals), with durations on a 100 ms scale. Honors System Settings › Accessibility › Reduce motion.
enum Motion {
    /// UI state changes: selection, hover, buttons appearing.
    static let snap = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.2)
    /// Larger reveals: messages sliding in, panels.
    static let reveal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.4)

    static func snap(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : snap }
    static func reveal(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : reveal }
}

/// Tracks the pointer hovering a view (for controls that appear only on hover).
final class HoverState: ObservableObject {
    @Published var hovering = false
}
