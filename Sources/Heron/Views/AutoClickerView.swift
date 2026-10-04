import SwiftUI

struct AutoClickerView: View {
    @EnvironmentObject var model: AppModel

    static func clicksPerSecond(_ intervalMs: Double) -> Double {
        ((1000 / max(1, intervalMs)) * 10).rounded() / 10
    }

    var body: some View {
        HStack(spacing: 0) {
            readout
                .frame(width: 300)
            Divider()
            settings
                .frame(maxWidth: 760)
        }
        // On wide windows the two halves stay side by side instead of drifting apart.
        .frame(maxWidth: 1060)
        .frame(maxWidth: .infinity)
    }

    // MARK: Speed (the page's one large element)

    private var readout: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Speed").foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Self.clicksPerSecond(model.autoClick.intervalMs).formatted(.number.precision(.fractionLength(0...1))))
                    .font(.system(size: 80, weight: .ultraLight).monospacedDigit())
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(model.autoClick.intervalMs <= 1000 ? "clicks a second" : "click a second")
                    .font(.title3).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { min(100, max(1, 1000 / max(1, model.autoClick.intervalMs))) },
                                  set: { model.autoClick.intervalMs = (1000 / $0).rounded() }),
                   in: 1...100)
            HStack { Text("1"); Spacer(); Text("100") }
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Or one click every").foregroundStyle(.secondary)
                TextField("", value: $model.autoClick.intervalMs, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                Stepper("", value: $model.autoClick.intervalMs, in: 1...3_600_000, step: 10).labelsHidden()
                Text("ms").foregroundStyle(.secondary)
            }
            .font(.callout)
            Spacer()
            if !model.isAutoClicking, model.autoClickCount > 0 {
                Text("Last run clicked \(model.autoClickCount) time\(model.autoClickCount == 1 ? "" : "s").")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    // MARK: Settings

    private var settings: some View {
        let s = $model.autoClick
        return Form {
            Section("Click") {
                Picker("Button", selection: s.button) {
                    ForEach(MouseButton.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Type", selection: s.clicksPerEvent) {
                    Text("Single").tag(1)
                    Text("Double").tag(2)
                    Text("Triple").tag(3)
                }
                .pickerStyle(.segmented)
                Picker(selection: s.location) {
                    Text("Wherever the pointer is").tag(AutoClickSettings.LocationMode.cursor)
                    Text("Spots I pick").tag(AutoClickSettings.LocationMode.points)
                } label: {
                    Text("Where")
                    if model.autoClick.location == .points { Text("Clicked in order, then around again.") }
                }
                if model.autoClick.location == .points { pointsList }
            }

            Section("Stop") {
                Picker("When", selection: s.stopMode) {
                    Text("I press the hotkey").tag(AutoClickSettings.StopMode.never)
                    Text("After a number of clicks").tag(AutoClickSettings.StopMode.afterClicks)
                    Text("After some time").tag(AutoClickSettings.StopMode.afterSeconds)
                }
                switch model.autoClick.stopMode {
                case .afterClicks: IntField(title: "Clicks", value: s.stopClicks, unit: "clicks", range: 1...10_000_000)
                case .afterSeconds: NumberField(title: "Time", value: s.stopSeconds, unit: "s")
                case .never: EmptyView()
                }
            }

            Section("Extras") {
                Toggle(isOn: Binding(get: { model.autoClick.jitterMs > 0 },
                                     set: { model.autoClick.jitterMs = $0 ? 15 : 0 })) {
                    Text("Vary the timing")
                    Text("Each click comes a little early or late, so the rhythm isn't exact.")
                }
                if model.autoClick.jitterMs > 0 {
                    NumberField(title: "By up to", value: s.jitterMs, unit: "ms")
                }
                Toggle(isOn: $model.prefs.clickSpread) {
                    Text("Randomize click position")
                    Text("Within \(Int(model.prefs.clickSpreadRadius)) points of the target. Applies to macros too.")
                }
                NumberField(title: "Hold each click for", value: s.holdMs, unit: "ms")
                NumberField(title: "Wait before starting", value: s.startDelay, unit: "s")
            }

            colorSection

            Section("Target") {
                TargetControls(target: s.target,
                               onSelectApp: { model.setAutoClickTarget($0) },
                               showsTest: true,
                               onTest: { model.testClick(targetInFront: $0) })
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var pointsList: some View {
        if model.autoClick.points.isEmpty {
            Text("No spots yet.").foregroundStyle(.secondary)
        }
        ForEach(Array(model.autoClick.points.enumerated()), id: \.element.id) { i, p in
            HStack {
                Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                Text("x").foregroundStyle(.secondary)
                TextField("", value: pointBinding(p.id, \.x), format: .number).frame(width: 70)
                Text("y").foregroundStyle(.secondary)
                TextField("", value: pointBinding(p.id, \.y), format: .number).frame(width: 70)
                if model.autoClick.colorCheck {
                    ColorSwatch(hex: p.color) { hex in setPointColor(p.id, hex) }
                    HexField(hex: Binding(get: { p.color ?? "" }, set: { setPointColor(p.id, $0) }))
                    Button { samplePoint(p) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .help("Use the color that's at this point right now")
                }
                Spacer()
                Button { movePoint(i, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0)
                Button { movePoint(i, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == model.autoClick.points.count - 1)
                Button(role: .destructive) {
                    model.autoClick.points.removeAll { $0.id == p.id }
                } label: { Image(systemName: "trash") }
            }
            .buttonStyle(.borderless)
        }
        HStack {
            Button(model.countdown != nil ? "Move your mouse… \(model.countdown!)" : "Add Spot (3 s countdown)") {
                model.capturePointAfterDelay()
            }
            .disabled(model.countdown != nil)
            Text(model.hotkeys[.capturePoint].map { "or hover anywhere and press \($0.display)" }
                 ?? "or set an “add point” hotkey in Settings")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !model.autoClick.points.isEmpty {
                Button("Clear All", role: .destructive) { model.autoClick.points.removeAll() }
            }
        }
    }

    private var colorSection: some View {
        let s = $model.autoClick
        return Section {
            Toggle(isOn: s.colorCheck) {
                Text("Only click when the color matches")
                Text("Skips a click when the spot isn't the color you expect.")
            }
            if model.autoClick.colorCheck {
                if model.autoClick.location == .points {
                    Text("Each spot gets its own color. New spots remember the color under them; use the eyedropper or a hex code to change it. Spots without a color always click.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Color under the pointer") {
                        HStack {
                            ColorSwatch(hex: model.autoClick.cursorColor) { model.autoClick.cursorColor = $0 }
                            HexField(hex: Binding(get: { model.autoClick.cursorColor ?? "" },
                                                  set: { model.autoClick.cursorColor = $0 }))
                        }
                    }
                }
                IntField(title: "Tolerance (0 = exact)", value: s.colorTolerance, range: 0...255)
                if !model.hasScreenRecording {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                        Text("Color checks need Screen Recording permission.").font(.caption)
                        Spacer()
                        Button("Allow…") { ScreenReader.requestPermission() }
                    }
                }
            }
        }
    }

    private func pointBinding(_ id: UUID, _ kp: WritableKeyPath<ClickPoint, Double>) -> Binding<Double> {
        Binding(
            get: { model.autoClick.points.first { $0.id == id }?[keyPath: kp] ?? 0 },
            set: { v in
                if let i = model.autoClick.points.firstIndex(where: { $0.id == id }) {
                    model.autoClick.points[i][keyPath: kp] = v
                }
            }
        )
    }

    private func setPointColor(_ id: UUID, _ hex: String) {
        if let i = model.autoClick.points.firstIndex(where: { $0.id == id }) {
            model.autoClick.points[i].color = hex
        }
    }

    private func samplePoint(_ p: ClickPoint) {
        model.sampleColor(atRelative: CGPoint(x: p.x, y: p.y), in: model.autoClick.target.app) { hex in
            if let hex { setPointColor(p.id, hex) }
        }
    }

    private func movePoint(_ i: Int, by d: Int) {
        let j = i + d
        guard model.autoClick.points.indices.contains(j) else { return }
        model.autoClick.points.swapAt(i, j)
    }
}
