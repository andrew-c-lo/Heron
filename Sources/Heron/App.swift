import SwiftUI

@main
struct HeronApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor private var delegate: HeronDelegate

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
            MacroCommands()
            HelpCommands()
        }

        Window("Heron Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 760, height: 480)

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
            // While something runs: rounds, time left, or time so far.
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
        liveHotkey(action)?.display ?? "not set"
    }
}


/// Keeps Heron running while the main window steps aside for the macro mini card (otherwise putting the only
/// window away would quit the app). Closing the window outside mini mode behaves as before.
final class HeronDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { YouActivity.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !MainActor.assumeIsolated { MiniPanel.shared.isShowing }
    }
}
