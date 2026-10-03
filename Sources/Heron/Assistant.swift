import AppKit
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device help (Apple Intelligence where available; nothing leaves the Mac). Every answer is limited to
/// words actually read from the screen, so it can't invent a button.
enum Assistant {
    /// Whether the on-device model can be used on this Mac.
    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Words that usually move past a screen, most likely first. Used when the model isn't available.
    static let continueWords = ["Tap to continue", "OK", "Close", "Skip", "Next", "Continue", "Confirm", "Yes",
                                "Done", "Got it", "Retry", "Start", "Claim", "Collect", "Accept"]

    /// The label on this screen most likely to move past it, or nil.
    static func suggestTap(on lines: [TextFinder.Line]) async -> String? {
        let labels = Array(Set(lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 30 })).sorted()
        guard !labels.isEmpty else { return nil }
        if let answer = await askModel(labels: labels) { return answer }
        // No model: the first common “continue” word on screen.
        for w in continueWords {
            if let hit = labels.first(where: { $0.compare(w, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                return hit
            }
        }
        return nil
    }

    private static func askModel(labels: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), modelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You help automate an app by choosing what to tap. You get the text visible on one screen. \
            Pick the single label that is a button or prompt which moves past this screen, such as OK, Close, \
            Skip, Next, Continue or Tap to continue. Never pick headings, titles, numbers or descriptions. \
            Reply with exactly one label from the list, or NONE.
            """)
        let list = labels.map { "- \($0)" }.joined(separator: "\n")
        guard let reply = try? await session.respond(to: "Visible text:\n\(list)") else { return nil }
        let answer = reply.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”.")))
        return labels.first { $0.compare(answer, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        #else
        return nil
        #endif
    }

    /// Steps described in plain words, built only from Heron's own step kinds and (for clicks) words on screen.
    /// Returns nil when the on-device model isn't available.
    static func buildSteps(from description: String, screenLabels: [String]) async -> [PlannedStep]? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), modelAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You turn a description of a task into steps for an automation app. Use only these lines, one per step:
            CLICK <label>      tap the on-screen text <label>
            WAIT <seconds>     pause
            TYPE <text>        type text
            PRESS <key>        press Return, Tab, Space or Esc
            Prefer labels from the list of text on screen when they fit. Reply with the steps only, no numbering, \
            no explanations.
            """)
        let screen = screenLabels.isEmpty ? "(unknown)" : screenLabels.prefix(60).joined(separator: ", ")
        guard let reply = try? await session.respond(to: "Text on screen: \(screen)\nTask: \(description)") else { return [] }
        return PlannedStep.parse(reply.content)
        #else
        return nil
        #endif
    }

    /// Picks the next tap toward a goal from the words on screen (for Autopilot). nil = goal reached or no idea.
    static func nextTap(goal: String, labels: [String], history: [String]) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), modelAvailable, !labels.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: """
            You operate an app by tapping on-screen text to reach a goal. You get the goal, the text visible \
            now and what you already tapped. Reply with exactly one label from the visible text to tap next, \
            or DONE if the goal is reached, or NONE if nothing on screen helps.
            """)
        let prompt = """
            Goal: \(goal)
            Visible text: \(labels.prefix(80).joined(separator: " | "))
            Already tapped: \(history.suffix(8).joined(separator: ", "))
            """
        guard let reply = try? await session.respond(to: prompt) else { return nil }
        let answer = reply.content.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”.")))
        return labels.first { $0.compare(answer, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        #else
        return nil
        #endif
    }
}

/// One step planned from a description (“Describe it…”).
enum PlannedStep: Equatable {
    case click(String)
    case wait(Double)
    case type(String)
    case press(String)

    static func parse(_ text: String) -> [PlannedStep] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            // Tolerate “1. CLICK OK” or “- CLICK OK”.
            while let f = line.first, f.isNumber || f == "." || f == "-" || f == ")" || f == " " { line.removeFirst() }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let arg = parts[1].trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\"“”")))
            switch parts[0].uppercased() {
            case "CLICK", "TAP": return arg.isEmpty ? nil : .click(arg)
            case "WAIT": return Double(arg.replacingOccurrences(of: "s", with: "")).map { .wait(min(max($0, 0), 60)) }
            case "TYPE": return arg.isEmpty ? nil : .type(arg)
            case "PRESS": return ["return", "tab", "space", "esc", "escape"].contains(arg.lowercased()) ? .press(arg) : nil
            default: return nil
            }
        }
    }
}

extension ScreenReader.WindowPixels {
    /// Pixels of a saved picture (for reading text from stuck screens).
    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(rgba: data, width: w, height: h)
    }
}
