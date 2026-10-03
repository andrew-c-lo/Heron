import SwiftUI

@main
struct MacroClickerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MacroClicker", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1000, height: 720)
        // The standard Mac toolbar (window buttons sit where they do in every other app); the tabs say where you are.
        .windowToolbarStyle(.unified(showsTitle: false))
        // Lets the window shrink to the simple strip and grow back.
        .windowResizability(.contentSize)

        Settings {
            SettingsRoot()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.menuBarIcon)
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let c = model.countdown {
            Text("Starting in \(c)…")
        } else if model.isRecording {
            Text("● Recording — \(model.recordedSteps) steps")
        } else if model.playingMacroID != nil {
            Text("▶ Playing — \(model.playStatus)")
        } else if model.isAutoClicking {
            Text("Auto clicking — \(model.autoClickCount) clicks")
        }

        Button(model.isAutoClicking ? "Stop Auto Clicker" : "Start Auto Clicker") { model.toggleAutoClick() }
            .shortcutHint(model, .toggleAutoClick)
        Button(model.isRecording ? "Stop Recording" : "Start Recording") { model.toggleRecording(fromUI: false) }
            .shortcutHint(model, .toggleRecording)
        Button(model.playingMacroID != nil ? "Stop Playback" : "Play “\(model.selectedMacro?.name ?? "—")”") {
            model.togglePlayback()
        }
        .disabled(model.selectedMacro == nil && model.playingMacroID == nil)
        .shortcutHint(model, .togglePlayback)

        if !model.macros.isEmpty {
            Menu("Play Macro") {
                ForEach(model.macros) { m in
                    Button(m.name) { model.selectedMacroID = m.id; model.play(m) }
                }
            }
        }
        if model.macros.contains(where: \.runsInBackground) {
            Button(model.backgroundRunning.isEmpty ? "Start Background Macros" : "Stop Background Macros") { model.toggleAllBackground() }
                .shortcutHint(model, .toggleWatchers)
        }
        Button("Stop Everything") { model.stopAll() }
            .shortcutHint(model, .stopAll)
        Divider()
        Button("Open MacroClicker…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { model.stopAll(); NSApp.terminate(nil) }
    }
}

private extension View {
    /// Menu items can't display Carbon hotkeys natively, so append the shortcut as help text.
    func shortcutHint(_ model: AppModel, _ action: HotkeyAction) -> some View {
        help(model.hotkeyDisplay(action))
    }
}

extension AppModel {
    func hotkeyDisplay(_ action: HotkeyAction) -> String {
        hotkeys[action]?.display ?? "not set"
    }
}
