import SwiftUI

struct HotkeysSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases) { HotkeyField(action: $0) }
            } footer: {
                Text("Hotkeys work from any app. Click a shortcut to change it, or press Esc to cancel. Standard Mac shortcuts like ⌘Q can't be used.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults") { model.resetHotkeys() }
            }
        }
        .formStyle(.grouped)
    }
}

struct RecordingSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("What to record") {
                Toggle(isOn: $model.prefs.recordMouseMoves) {
                    Text("Mouse movement")
                    Text("Turn off to keep only clicks, swipes, scrolls and keys.")
                }
                Toggle(isOn: $model.prefs.recordKeyboard) {
                    Text("Keyboard")
                    Text("Typing and shortcuts. Your own MacroClicker hotkeys are never recorded.")
                }
                LabeledContent {
                    TargetAppMenu(selection: model.prefs.recordTarget, noneLabel: "Any app (whole screen)") {
                        model.prefs.recordTarget = $0
                    }
                } label: {
                    Text("Record only in")
                    Text(model.prefs.recordTarget.map {
                        "Only clicks inside the \($0.name) window, and keys while it's in front. New recordings target it automatically."
                    } ?? "Choose an app to ignore everything outside its window.")
                }
            }
            Section("Fine-tuning") {
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("", value: $model.prefs.moveCoalesceMs, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                        Text("ms").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Merge mouse motion")
                    Text("Movement closer together than this becomes one step, keeping recordings small.")
                }
                LabeledContent {
                    HStack(spacing: 4) {
                        TextField("", value: $model.prefs.recordCountdown, format: .number)
                            .multilineTextAlignment(.trailing).frame(width: 60)
                        Stepper("", value: $model.prefs.recordCountdown, in: 0...30).labelsHidden()
                        Text("s").foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Countdown")
                    Text("Seconds to get ready after pressing Record.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionsSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                PermissionRow(icon: "hand.tap", title: "Accessibility", detail: "Required to click, move the mouse and type.",
                              granted: model.hasAccessibility) { Permissions.requestAccessibility() }
                PermissionRow(icon: "keyboard", title: "Input Monitoring", detail: "Required to record your mouse and keyboard.",
                              granted: model.hasInputMonitoring) { Permissions.requestInputMonitoring() }
                PermissionRow(icon: "eyedropper", title: "Screen Recording",
                              detail: "Optional. Only for color checks and screenshots in the Visual view. MacroClicker reads single pixels and saves nothing except those screenshots.",
                              granted: model.hasScreenRecording) { ScreenReader.requestPermission() }
            } footer: {
                Text("If a permission stops working after an update, remove MacroClicker from that list in System Settings and add it again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Clicking") {
                Toggle(isOn: $model.prefs.clickSpread) {
                    Text("Randomize click position")
                    Text("Each click lands at a random spot within this distance of its target instead of the exact same point every time. Applies everywhere: auto clicker points, macros, watchers and picture steps. Clicks on a found picture stay inside it.")
                }
                if model.prefs.clickSpread {
                    LabeledContent {
                        HStack(spacing: 4) {
                            TextField("", value: $model.prefs.clickSpreadRadius, format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 60)
                            Text("points").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("Spread")
                        Text("How far from the target a click may land. Clicks at your own cursor position are never moved.")
                    }
                }
            }
            Section {
                Toggle(isOn: $model.prefs.playSounds) {
                    Text("Sounds")
                    Text("A soft sound when clicking, recording or playback starts and stops.")
                }
            }
            Section {
                LabeledContent {
                    Button("Show in Finder") { model.revealMacroFolder() }
                } label: {
                    Text("Macro files")
                    Text("Each macro is a readable .json file you can back up or share.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let granted: Bool
    let request: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        } label: {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: icon).foregroundStyle(.tint)
            }
        }
    }
}

struct HotkeyField: View {
    let action: HotkeyAction
    @EnvironmentObject var model: AppModel
    @StateObject private var state = RecorderState()

    private final class RecorderState: ObservableObject {
        @Published var recording = false
        var monitor: Any?
    }

    private var recording: Bool { state.recording }

    var body: some View {
        LabeledContent(action.title) {
            HStack {
                Button(recording ? "Type shortcut…" : (model.hotkeys[action]?.display ?? "None")) {
                    recording ? stop() : start()
                }
                .frame(minWidth: 110)
                if let hk = model.hotkeys[action], hk.isReserved {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("\(hk.display) is a standard Mac shortcut, so it's switched off. Pick a different combination.")
                }
                Button {
                    model.setHotkey(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Disable this hotkey")
                .disabled(model.hotkeys[action] == nil)
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        state.recording = true
        model.suspendHotkeys() // so the combination being typed doesn't fire an action
        state.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            if e.keyCode == 53, mods.isEmpty { stop(); return nil } // Esc cancels
            if mods.isEmpty && !KeyNames.functionKeyCodes.contains(e.keyCode) {
                NSSound.beep() // require a modifier unless it's an F-key
                return nil
            }
            let hk = Hotkey(keyCode: UInt32(e.keyCode), modifiers: CarbonMods.from(mods))
            if hk.isReserved {
                NSSound.beep()
                model.flash("\(hk.display) is a standard Mac shortcut. Pick a different combination (⌃⌥ + a letter works well).")
                return nil
            }
            model.setHotkey(hk, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = state.monitor { NSEvent.removeMonitor(m) }
        state.monitor = nil
        state.recording = false
        model.resumeHotkeys()
    }
}
