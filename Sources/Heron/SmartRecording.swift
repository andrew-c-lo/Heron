import CoreGraphics
import Foundation

/// Smart recording: remembers *what* was clicked, not just where. While recording inside an app, the words under
/// each click are read (on this Mac); when recording stops, clicks on a short label become “Click “label””
/// steps that find the text wherever it is, falling back to the recorded spot.
final class ClickReader: @unchecked Sendable {
    struct Label: Equatable {
        let text: String
        /// Set when the same text appears more than once: only look near where it was clicked.
        let area: CGRect?
    }

    private let queue = DispatchQueue(label: "heron.click-reader", qos: .userInitiated)
    private let lock = NSLock()
    private var labels: [UUID: Label] = [:]
    private let resolver: TargetResolver

    init(target: TargetApp) {
        resolver = TargetResolver(app: target)
        // Start the window's live feed now, so the picture at the first click is already there.
        queue.async { [resolver] in
            if let win = resolver.window() { _ = FrameSource.shared.frame(for: win, after: 0, timeout: 0.5) }
        }
    }

    func notePress(_ id: UUID, at p: CGPoint) {
        queue.async { [self] in
            guard let win = resolver.window(),
                  let frame = FrameSource.shared.frame(for: win, after: 0, timeout: 0.05) else { return }
            if let label = Self.label(in: TextFinder.read(frame.pixels), at: p,
                                      window: CGSize(width: frame.pixels.width, height: frame.pixels.height)) {
                lock.withLock { labels[id] = label }
            }
        }
    }

    /// Waits for reads still in progress, then returns what was found.
    func finish() -> [UUID: Label] {
        queue.sync {}
        return lock.withLock { labels }
    }

    /// The short label under `p`, if there is one.
    static func label(in lines: [TextFinder.Line], at p: CGPoint, window: CGSize) -> Label? {
        let hits = lines.filter { $0.rect.insetBy(dx: -6, dy: -6).contains(p) }
        guard let line = hits.min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }) else { return nil }
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Labels are short. A click inside a sentence is usually placing the text cursor, so it stays a
        // plain click at its position.
        guard text.count <= 30, text.split(separator: " ").count <= 4 else { return nil }
        // Something a person would call a label: at least two characters, including a letter.
        guard text.count >= 2, text.contains(where: \.isLetter) else { return nil }
        let copies = lines.filter {
            $0.text.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.count
        let area = copies > 1
            ? CGRect(x: p.x - 200, y: p.y - 120, width: 400, height: 240)
                .intersection(CGRect(origin: .zero, size: window)).integral
            : nil
        return Label(text: text, area: area)
    }

    /// Replaces single left clicks on a label with “Click “label”” steps (5 s to appear, then the recorded spot).
    static func convert(_ steps: [MacroStep], labels: [UUID: Label]) -> (steps: [MacroStep], converted: Int) {
        guard !labels.isEmpty else { return (steps, 0) }
        var out: [MacroStep] = []
        var converted = 0
        for g in ActionGrouper.groups(for: steps) {
            guard case .click(.left, 1, let at?, let hold) = g.kind, hold < 0.5,
                  g.actionIndex < g.range.upperBound,
                  let label = labels[steps[g.actionIndex].id] else {
                out.append(contentsOf: steps[g.range])
                continue
            }
            // Keep the cursor travel before it (its timing), replace the press and release.
            out.append(contentsOf: steps[g.range.lowerBound..<g.actionIndex])
            var find = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
            find.text = label.text
            find.area = label.area
            find.timeout = 5
            find.otherwise = .continueAnyway
            find.fallbackX = Double(at.x)
            find.fallbackY = Double(at.y)
            out.append(MacroStep(delay: steps[g.actionIndex].delay, action: .findImage(find)))
            converted += 1
        }
        return (out, converted)
    }
}
