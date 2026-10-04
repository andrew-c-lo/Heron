import SwiftUI

/// Picker sheet state for a picture step's editor.
final class WatcherUIState: ObservableObject {
    @Published var picker: NSImage?
    @Published var testResult: String?
    @Published var testing = false
    /// The open screenshot is for choosing the search area (not the picture).
    @Published var pickingArea = false
    /// The open screenshot is for adding another picture of the same thing.
    @Published var pickingVariant = false
}

/// "Look for: Picture | Text". Text mode is `text != nil`, so an empty box stays in text mode.
struct LookForPicker: View {
    @Binding var text: String?
    /// Offers “Both” (picture or words, whichever is found) when given. The two values are set together
    /// (separate writes through a step binding would undo each other).
    var alsoPicture: Bool? = nil
    /// Offers “Spot” (click fixed coordinates without looking) when given.
    var spotOnly: Bool? = nil
    /// Sets the words, “Both” and “Spot” together.
    var set: ((_ text: String?, _ both: Bool, _ spot: Bool) -> Void)? = nil

    private enum Choice { case picture, text, both, spot }

    /// What each choice means, for the switch's tooltip (shown before choosing).
    private var choiceHelp: String {
        var lines = ["Picture: finds a picture you box, wherever it appears.", "Text: finds words, read on this Mac."]
        if alsoPicture != nil { lines.append("Both: either the picture or the words.") }
        if spotOnly != nil { lines.append("Spot: clicks fixed coordinates without looking.") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Picker("Look for", selection: Binding<Choice>(
            get: { spotOnly == true ? .spot : text == nil ? .picture : (alsoPicture == true ? .both : .text) },
            set: { c in
                if c == .spot { set?(text, alsoPicture ?? false, true); return }
                let t = c == .picture ? nil : (text ?? "")
                if let set { set(t, c == .both, false) } else { text = t }
            })) {
            Text("Picture").tag(Choice.picture)
                .help("Picture: finds a picture you box, wherever it appears in the window")
            Text("Text").tag(Choice.text)
                .help("Text: finds words, read on this Mac, wherever they appear")
            if alsoPicture != nil {
                Text("Both").tag(Choice.both)
                    .help("Both: found when either the picture or the words show up")
            }
            if spotOnly != nil {
                Text("Spot").tag(Choice.spot)
                    .help("Spot: clicks fixed coordinates without looking; the picture and words are kept")
            }
        }
        .help(choiceHelp)
        .pickerStyle(.segmented)
        .labelsHidden() // the section is already titled "Look for"
    }
}

/// The text to look for, read on-device with Live Text–style recognition.
struct LookForTextField: View {
    @Binding var text: String?

    var body: some View {
        LabeledContent {
            TextField("Text", text: Binding(get: { text ?? "" }, set: { text = $0 }), prompt: Text("Claim"))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 220)
        } label: {
            Text("Text")
            Text("Found anywhere it appears, ignoring capitals. Read on this Mac; nothing is uploaded.")
        }
    }
}

/// Limit the search to part of the window: faster, and avoids matches elsewhere.
struct SearchAreaRow: View {
    @Binding var area: CGRect?
    let onChoose: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(area.map { "\(Int($0.width)) × \(Int($0.height))" } ?? "Whole window")
                    .help(area.map { "Starts at \(Int($0.minX)), \(Int($0.minY)) in the window" } ?? "")
                    .monospacedDigit().foregroundStyle(.secondary)
                Button(area == nil ? "Choose…" : "Change…", action: onChoose)
                if area != nil {
                    Button("Clear") { area = nil }
                }
            }
        } label: {
            Text("Search area")
            Text("Only look inside part of the window.")
        }
    }
}
