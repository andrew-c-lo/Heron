import SwiftUI

/// Menu listing running apps, plus "whole screen".
struct TargetAppMenu: View {
    let selection: TargetApp?
    var noneLabel = "None (whole screen)"
    let onSelect: (TargetApp?) -> Void

    var body: some View {
        Menu {
            Button(noneLabel) { onSelect(nil) }
            Divider()
            ForEach(TargetApp.running(), id: \.bundleID) { app in
                Button(app.name) { onSelect(app) }
            }
        } label: {
            Text(selection?.name ?? noneLabel)
        }
        .fixedSize()
    }
}

/// Target app + delivery controls. Changing the app goes through `onSelectApp` so coordinates get converted.
struct TargetControls: View {
    @Binding var target: TargetOptions
    let onSelectApp: (TargetApp?) -> Void
    var showsTest: Bool = false
    var onTest: (_ targetInFront: Bool) -> Void = { _ in }

    var body: some View {
        LabeledContent("Target app") {
            HStack {
                if let app = target.app, ProcessInfo.processInfo.environment["HERON_SCREENSHOTS"] == nil {
                    Circle()
                        .fill(WindowFinder.find(app) != nil ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                        .help(WindowFinder.find(app) != nil ? "Window found" : "\(app.name) isn't open")
                }
                TargetAppMenu(selection: target.app, onSelect: onSelectApp)
            }
        }
        if let app = target.app {
            Text("Positions are relative to the \(app.name) window, so you can move the window.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Delivery", selection: $target.delivery) {
            ForEach(DeliveryMode.choices) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        HStack {
            Text(target.delivery.explanation)
                .font(.caption).foregroundStyle(target.delivery == .background && target.app == nil ? .red : .secondary)
            Spacer()
            if showsTest {
                if target.delivery == .background, let app = target.app {
                    Menu("Test") {
                        Button("Test with \(app.name) in the background") { onTest(false) }
                        Button("Test with \(app.name) in front (cursor kept off it)") { onTest(true) }
                    }
                    .fixedSize()
                    .help("Sends one click to point 1. Don't touch the mouse during the test.")
                } else {
                    Button("Test") { onTest(false) }
                        .help("Sends one click to point 1.")
                }
            }
        }
        if target.delivery == .jumpReturn {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField("", value: $target.jumpWhenStillMs, format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                    Text("ms").foregroundStyle(.secondary)
                }
            } label: {
                Text("Wait for your mouse to be still")
                Text("0 doesn't wait: fastest when you're away from the Mac.")
            }
            .help("Before each jump, wait until you haven't moved the mouse (or held a button) for this long, so it never fights your hand. 0 = don't wait.")
        }
        if target.delivery == .background && target.app == nil {
            Text("Choose a target app to use background delivery.")
                .font(.caption).foregroundStyle(.red)
        }
        if target.app != nil && target.delivery != .background {
            Toggle("Bring app to front before starting", isOn: $target.activateFirst)
            Toggle("Pause while another app is in front", isOn: $target.pauseWhenInactive)
        }
    }
}
