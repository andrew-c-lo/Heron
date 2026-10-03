import SwiftUI

/// Picker sheet state for a picture step's editor.
final class WatcherUIState: ObservableObject {
    @Published var picker: NSImage?
    @Published var testResult: String?
    @Published var testing = false
    /// The open screenshot is for choosing the search area (not the picture).
    @Published var pickingArea = false
}

/// "Look for: Picture | Text". Text mode is `text != nil`, so an empty box stays in text mode.
struct LookForPicker: View {
    @Binding var text: String?

    var body: some View {
        Picker("Look for", selection: Binding(get: { text != nil }, set: { text = $0 ? (text ?? "") : nil })) {
            Text("Picture").tag(false)
            Text("Text").tag(true)
        }
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
                Text(area.map { "\(Int($0.width)) × \(Int($0.height)) at (\(Int($0.minX)), \(Int($0.minY)))" } ?? "Whole window")
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
