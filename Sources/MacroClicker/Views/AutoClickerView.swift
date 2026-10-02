import SwiftUI

struct AutoClickerView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = $model.autoClick
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        // The live count is this page's one large element; everything else stays quiet.
                        Text(model.isAutoClicking ? "\(model.autoClickCount) clicks" : "Stopped")
                            .font(.system(size: 28, weight: .light).monospacedDigit())
                            .contentTransition(.numericText())
                        if model.autoClick.colorCheck && model.autoClickSkipped > 0 {
                            Text("\(model.autoClickSkipped) skipped (color didn't match)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Hotkey: \(model.hotkeyDisplay(.toggleAutoClick))   ·   Panic stop: \(model.hotkeyDisplay(.stopAll))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Timing") {
                NumberField(title: "Interval", value: s.intervalMs, unit: "ms")
                LabeledContent("Rate") {
                    Text(String(format: "%.1f clicks/sec", 1000 / max(1, model.autoClick.intervalMs)))
                        .foregroundStyle(.secondary)
                }
                NumberField(title: "Random jitter (±)", value: s.jitterMs, unit: "ms")
                NumberField(title: "Hold each click for", value: s.holdMs, unit: "ms")
                NumberField(title: "Delay before starting", value: s.startDelay, unit: "s")
            }

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
            }

            Section("Target & delivery") {
                TargetControls(target: s.target,
                               onSelectApp: { model.setAutoClickTarget($0) },
                               showsTest: true,
                               onTest: { model.testClick(targetInFront: $0) })
            }

            Section("Location") {
                Picker("Click at", selection: s.location) {
                    Text("Follow cursor").tag(AutoClickSettings.LocationMode.cursor)
                    Text("Fixed point(s)").tag(AutoClickSettings.LocationMode.points)
                }
                .pickerStyle(.segmented)

                if model.autoClick.location == .points {
                    if model.autoClick.points.isEmpty {
                        Text("No points yet. Points are clicked in order, cycling.")
                            .foregroundStyle(.secondary)
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
                        Button(model.countdown != nil ? "Move your mouse… \(model.countdown!)" : "Add point (3s countdown)") {
                            model.capturePointAfterDelay()
                        }
                        .disabled(model.countdown != nil)
                        Text(model.hotkeys[.capturePoint].map { "or hover anywhere and press \($0.display)" }
                             ?? "or set an “add point” hotkey in Settings")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if !model.autoClick.points.isEmpty {
                            Button("Clear all", role: .destructive) { model.autoClick.points.removeAll() }
                        }
                    }
                }
            }

            Section {
                Toggle("Only click when the color matches", isOn: s.colorCheck)
                if model.autoClick.colorCheck {
                    if model.autoClick.location == .points {
                        Text("Each point above gets its own color. New points remember the color under them; use the eyedropper or a hex code to change it. Points without a color always click.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Color under the cursor") {
                            HStack {
                                ColorSwatch(hex: model.autoClick.cursorColor) { model.autoClick.cursorColor = $0 }
                                HexField(hex: Binding(get: { model.autoClick.cursorColor ?? "" },
                                                      set: { model.autoClick.cursorColor = $0 }))
                            }
                        }
                    }
                    IntField(title: "Tolerance (0 = exact)", value: s.colorTolerance, range: 0...255)
                    Text("How far each of red, green and blue may differ. Windows that show streamed video flicker slightly in color. A small tolerance like 4–10 is more reliable than an exact match.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.hasScreenRecording {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("Color checks need Screen Recording permission.").font(.caption)
                            Spacer()
                            Button("Grant…") { ScreenReader.requestPermission() }
                        }
                    }
                }
            } header: {
                Text("Color check")
            }

            Section("Stop") {
                Picker("Stop", selection: s.stopMode) {
                    Text("Never (until stopped)").tag(AutoClickSettings.StopMode.never)
                    Text("After a number of clicks").tag(AutoClickSettings.StopMode.afterClicks)
                    Text("After a duration").tag(AutoClickSettings.StopMode.afterSeconds)
                }
                switch model.autoClick.stopMode {
                case .afterClicks: IntField(title: "Clicks", value: s.stopClicks, unit: "clicks", range: 1...10_000_000)
                case .afterSeconds: NumberField(title: "Duration", value: s.stopSeconds, unit: "s")
                case .never: EmptyView()
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleAutoClick()
                } label: {
                    Label(model.isAutoClicking ? "Stop" : "Start",
                          systemImage: model.isAutoClicking ? "stop.fill" : "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .disabled(false)
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
