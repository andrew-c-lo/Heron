import SwiftUI

/// Macro › Check Macro…: picture steps whose settings can't work as saved, each with its fix.
struct HealthSheet: View {
    @EnvironmentObject var model: AppModel
    let macroID: UUID
    let onStrictness: (UUID, Double) -> Void
    let onShowStep: (UUID) -> Void
    let onDone: () -> Void
    /// Results to show instead of running the check (rendering the window off-screen for QA).
    var preset: (issues: [HealthIssue], screens: Int)? = nil
    @StateObject private var state = CheckState()

    final class CheckState: ObservableObject {
        @Published var progress = 0.0
        @Published var issues: [HealthIssue]?
        @Published var screens = 0
        @Published var applied = Set<UUID>()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check Macro").font(.title3.weight(.semibold))
                Text("Tries each picture on screens saved from this macro, at a few window sizes, to see whether its settings can work.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            Group {
                if let issues = state.issues {
                    if issues.isEmpty { empty } else { list(issues) }
                } else {
                    VStack(spacing: 10) {
                        ProgressView(value: state.progress).frame(width: 220)
                        Text("Checking pictures…").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 240)
            Divider()
            HStack {
                if state.issues != nil {
                    Text(state.screens < 2 ? "Strictness wasn't checked: play the macro until it saves a few screens."
                                           : "Checked on \(state.screens) screens from this macro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 520, height: 460)
        .onAppear { if let p = preset { state.issues = p.issues; state.screens = p.screens } }
        .task {
            guard preset == nil else { return }
            let r = await model.checkMacro(macroID) { state.progress = $0 }
            state.screens = r.screens
            state.issues = r.issues
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(.green)
            Text("No problems found").font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func list(_ issues: [HealthIssue]) -> some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(issues) { issue in
                row(issue).padding(.horizontal, 20).padding(.vertical, 12)
                if issue.id != issues.last?.id { Divider().padding(.leading, 48) }
            }
        }
        // Off-screen rendering (QA) can't draw scroll views.
        if preset != nil { rows.frame(maxHeight: .infinity, alignment: .top).clipped() } else { ScrollView { rows } }
    }

    private func row(_ issue: HealthIssue) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(issue.kind)).foregroundStyle(color(issue.kind)).frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title).fontWeight(.medium)
                    Text(issue.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                switch issue.fix {
                case .strictness(let v):
                    if state.applied.contains(issue.id) {
                        Label("Set", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(.secondary).font(.callout)
                    } else {
                        Button("Use \(Int((v * 100).rounded()))%") { onStrictness(issue.step, v); state.applied.insert(issue.id) }
                            .help("Sets this step's strictness")
                    }
                case .showStep:
                    Button("Show Step \(issue.number)") { onShowStep(issue.step) }
                }
            }
    }

    private func icon(_ k: HealthIssue.Kind) -> String {
        switch k {
        case .tooStrict: "eye.slash"
        case .tooLoose: "exclamationmark.triangle"
        case .unreliableSize, .otherShape: "aspectratio"
        case .otherApp: "macwindow.on.rectangle"
        case .areaMissesPicture: "viewfinder"
        }
    }

    private func color(_ k: HealthIssue.Kind) -> Color { k == .tooLoose ? .orange : .accentColor }
}
