import SwiftUI

/// What you pressed yourself while the macro played, offered as steps.
struct PressSuggestionsView: View {
    @EnvironmentObject var model: AppModel
    let macroID: UUID
    let inOrder: Bool
    let onAdd: (ImageStep) -> Void
    let onDone: () -> Void

    private var items: [PressSuggestion] { model.pressSuggestions[macroID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("You Pressed").font(.title3.weight(.semibold))
                Text("While the macro played, you pressed these yourself. Add one as a step and Heron will find and press it next time.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if items.isEmpty {
                ContentUnavailableView("Nothing to add", systemImage: "hand.tap",
                                       description: Text("Presses you make in the macro's app while it plays show up here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in row(item) }
            }
            Divider()
            HStack {
                Text("Things a step already finds aren't listed. Heron's own clicks are ignored.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { model.clearPressSuggestions(macro: macroID) }
                    .disabled(items.isEmpty)
                    .help("Dismiss all of these")
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 440)
    }

    private func row(_ item: PressSuggestion) -> some View {
        HStack(spacing: 12) {
            Group {
                if let png = item.label.picture, let image = NSImage(data: png) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "text.viewfinder").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label.text.map { "Tap “\($0)”" } ?? "Tap this picture").font(.body.weight(.medium))
                Text("You pressed it \(item.count)× · last at \(Int(item.point.x)), \(Int(item.point.y))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Step") {
                onAdd(item.step(inOrder: inOrder))
                model.dismissPressSuggestion(item.id, macro: macroID)
            }
            Button { model.dismissPressSuggestion(item.id, macro: macroID) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Not needed")
        }
        .padding(.vertical, 4)
    }
}
