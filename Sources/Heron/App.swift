import SwiftUI

@main
struct HeronApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Heron", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1000, height: 720)
        // The standard Mac toolbar (window buttons sit where they do in every other app); the tabs say where you are.
        .windowToolbarStyle(.unified(showsTitle: false))
        // Lets the window shrink to the simple strip and grow back.
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Heron Help") {
                    if let url = URL(string: "https://github.com/andrew-c-lo/Heron#everything-it-does") { NSWorkspace.shared.open(url) }
                }
            }
        }

        Settings {
            SettingsRoot()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            // The heron while idle; a symbol for what's happening otherwise (recording, playing…).
            if model.menuBarIcon == "cursorarrow.click", let heron = MenuBarIcon.image {
                Image(nsImage: heron)
            } else {
                Image(systemName: model.menuBarIcon)
            }
            // Round progress while a macro with a round goal runs (“3/5”).
            if let p = model.menuBarProgress {
                Text(p).monospacedDigit()
            }
        }
    }
}

enum MenuBarIcon {
    static let image: NSImage? = {
        guard let img = Bundle.main.image(forResource: "MenuBarIcon") else { return nil }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true // follows the menu bar's light/dark tint
        return img
    }()
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let c = model.countdown {
            Text("Starting in \(c)…")
        } else if model.isRecording {
            Text("● Recording — \(model.recordedSteps) steps")
        } else if model.isAutoClicking {
            Text("Auto clicking — \(model.autoClickCount) clicks")
        }

        // What each running macro is doing, with a way to stop it.
        let lines = model.liveLines()
        if !lines.isEmpty {
            ForEach(lines, id: \.id) { l in
                Text("\(l.name): \(l.line)")
                Button("Stop “\(l.name)”") {
                    if model.isRunningInBackground(l.id) { model.stopBackground(l.id) } else { model.stopPlayback() }
                }
            }
            Divider()
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
        Button("Open Heron…") {
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
