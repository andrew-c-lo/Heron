import SwiftUI

/// Screens where “Tap when stuck” had to step in. Each one can become a step: box a picture on it, or take the
/// suggested word to tap.
struct StuckScreensView: View {
    @EnvironmentObject var model: AppModel
    let macroID: UUID
    /// Adds a step to the macro (a picture or a word to click).
    let onAdd: (ImageStep) -> Void
    let onDone: () -> Void
    @StateObject private var ui = StuckUI()

    final class StuckUI: ObservableObject {
        @Published var picking: ImageSheetItem?
        @Published var suggestions: [URL: String] = [:]
        @Published var thinking: Set<URL> = []
    }

    private var screens: [URL] { model.stuckScreens[macroID] ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stuck Screens").font(.title3.weight(.semibold))
                Text("Each time nothing in the list showed up for a while, Heron tapped your stuck spot and kept the screen here. Turn one into a step so next time it knows what to do.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if screens.isEmpty {
                ContentUnavailableView("Nothing got stuck", systemImage: "checkmark.circle",
                                       description: Text("Turn on “Tap when stuck” in Playback to collect screens here."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(screens, id: \.self) { url in card(url) }
                    }
                    .padding(16)
                }
            }
            Divider()
            HStack {
                Text(Assistant.modelAvailable ? "Suggestions are made on this Mac by Apple Intelligence."
                                              : "Suggestions use common button words; Apple Intelligence isn't available on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear All") { model.clearStuck(macro: macroID) }
                    .disabled(screens.isEmpty)
                    .help("Move all \(screens.count) screens to the Trash. Handy when they were only slow loads.")
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 760, height: 600)
        .onAppear { model.loadStuck(for: macroID) }
        .sheet(item: $ui.picking) { item in
            RegionPickerSheet(image: item.image) { rect in
                if let c = PictureCrop.crop(rect, from: item.image) {
                    onAdd(ImageStep(png: c.png, width: c.width, height: c.height,
                                    originX: Double(rect.minX), originY: Double(rect.minY)))
                }
                ui.picking = nil
            } onCancel: { ui.picking = nil }
        }
    }

    private func card(_ url: URL) -> some View {
        let image = NSImage(contentsOf: url)
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(date(url)).font(.caption).foregroundStyle(.secondary)
            if let s = ui.suggestions[url] {
                HStack {
                    Text(s.isEmpty ? "No word to tap found." : "Tap “\(s)”?").font(.callout)
                    Spacer()
                    if !s.isEmpty {
                        Button("Add") {
                            var step = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
                            step.text = s
                            onAdd(step)
                        }
                    }
                }
            }
            HStack {
                Button("Add Picture Step…") { if let image { ui.picking = ImageSheetItem(image: image) } }
                Button(ui.thinking.contains(url) ? "Thinking…" : "Suggest") { suggest(url, image) }
                    .disabled(ui.thinking.contains(url))
                Spacer()
                Button(role: .destructive) { model.deleteStuck(url, macro: macroID) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this screen")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func suggest(_ url: URL, _ image: NSImage?) {
        guard let image, let px = ScreenReader.WindowPixels(image: image) else { return }
        ui.thinking.insert(url)
        Task { @MainActor in
            let lines = await Task.detached { TextFinder.read(px) }.value
            let answer = await Assistant.suggestTap(on: lines)
            ui.suggestions[url] = answer ?? ""
            ui.thinking.remove(url)
        }
    }

    private func date(_ url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let d = attrs?[.creationDate] as? Date ?? Date()
        return d.formatted(date: .abbreviated, time: .shortened)
    }
}
