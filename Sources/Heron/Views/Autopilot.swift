import SwiftUI

/// Experimental: give a goal in words, and the on-device model taps one on-screen word at a time toward it.
/// Slow (a few seconds per tap) and only as good as the words it can read; meant for exploring, not for runs.
struct AutopilotView: View {
    @EnvironmentObject var model: AppModel
    let target: TargetOptions
    let onDone: () -> Void
    @StateObject private var run = AutopilotRun()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Autopilot").font(.title3.weight(.semibold))
            Text("Describe a goal, and Heron taps one word on screen at a time toward it, using Apple Intelligence on this Mac. It's slow and can make mistakes: watch it, and press Stop if it goes wrong.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !Assistant.modelAvailable {
                Label("Needs Apple Intelligence, which isn't available on this Mac.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            TextField("", text: $run.goal, prompt: Text("Claim all rewards, then close the window"), axis: .vertical)
                .lineLimit(2...3)
                .disabled(run.running)
            HStack {
                Text("At most")
                TextField("", value: $run.maxTaps, format: .number).frame(width: 44).disabled(run.running)
                Text("taps")
                Spacer()
                if run.running {
                    Button("Stop") { run.stop() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Start") { run.start(model: model, target: target) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(run.goal.trimmingCharacters(in: .whitespaces).isEmpty || !Assistant.modelAvailable
                                  || target.app == nil)
                }
            }
            List(run.log.indices.reversed(), id: \.self) { i in Text(run.log[i]).font(.callout) }
                .frame(minHeight: 160)
            HStack {
                Text(target.app.map { "Taps in \($0.name)." } ?? "Choose a target app first.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { run.stop(); onDone() }
            }
        }
        .padding(16)
        .frame(width: 520, height: 480)
    }
}

@MainActor
final class AutopilotRun: ObservableObject {
    @Published var goal = ""
    @Published var maxTaps = 15
    @Published var running = false
    @Published var log: [String] = []
    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
        if running { log.append("Stopped.") }
        running = false
    }

    func start(model: AppModel, target: TargetOptions) {
        guard let app = target.app else { return }
        running = true
        log = ["Goal: \(goal)"]
        let goal = self.goal, maxTaps = self.maxTaps
        task = Task { @MainActor in
            var history: [String] = []
            for _ in 0..<max(1, maxTaps) {
                guard !Task.isCancelled else { break }
                guard let win = WindowFinder.find(app), let shot = await ScreenReader.captureWindowAsync(win) else {
                    log.append("Can't see \(app.name). Is it open, with Screen Recording allowed?")
                    break
                }
                let lines = await Task.detached { TextFinder.read(shot) }.value
                let labels = Array(Set(lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }))
                guard let pick = await Assistant.nextTap(goal: goal, labels: labels, history: history) else {
                    log.append("Done: nothing more to tap toward the goal.")
                    break
                }
                guard let line = lines.first(where: { $0.text.trimmingCharacters(in: .whitespaces) == pick }) else { break }
                if let error = model.tapOnce(at: CGPoint(x: line.rect.midX, y: line.rect.midY), target: target) {
                    log.append(error)
                    break
                }
                history.append(pick)
                log.append("Tapped “\(pick)”")
                try? await Task.sleep(for: .seconds(1.5))
            }
            if running && !Task.isCancelled && history.count >= maxTaps { log.append("Reached \(maxTaps) taps.") }
            running = false
        }
    }
}
