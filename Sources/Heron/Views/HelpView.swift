import SwiftUI

/// Help → Heron Help: how the pieces fit, inside the app (works offline).
struct HelpView: View {
    struct Topic: Identifiable, Hashable {
        let id: String
        let icon: String
        let body: [String]
    }

    static let topics: [Topic] = [
        Topic(id: "Macros and steps", icon: "list.bullet", body: [
            "A macro is a list of steps that play from top to bottom: clicks, key presses, typing, waits, and steps that look at the screen.",
            "Record what you do, add steps with Add or Find Picture, or start from a template. Drag steps to reorder them, or use ⌥⌘↑ and ⌥⌘↓.",
            "Select a step to edit it in the panel beside the list, and double-click a picture step to pick its picture again. Click the pencil next to a step's title to give it a name.",
        ]),
        Topic(id: "Pictures and words", icon: "viewfinder", body: [
            "Picture steps find something on screen before clicking it, so they keep working when things move or load slowly.",
            "Look for a Picture, some Text, or Both (either one counts). Spot clicks a fixed point without looking.",
            "Draw a box to choose where clicks land: each click goes to a different place inside it. Limit the search area to make finding faster and avoid look-alikes.",
            "A picture with no words is named by its colour, like “Tap the red picture”. Rename it to anything you like.",
        ]),
        Topic(id: "Target", icon: "scope", body: [
            "Target is the app the macro works in. Positions are kept relative to its window, so moving or resizing the window doesn't break the macro.",
            "Jump and return clicks and puts the pointer back where it was. In the background clicks without moving your pointer, for apps that allow it.",
        ]),
        Topic(id: "Playback", icon: "repeat", body: [
            "In order plays steps one after another. All at once watches every picture step together and clicks whichever appears, which suits screens that change unpredictably.",
            "Repeat it once, a set number of times, or until it stops. Vary the timing to make waits less regular.",
            "Keep running in the background gives the macro its own switch in the list, so it runs alongside everything else.",
        ]),
        Topic(id: "Stops", icon: "stop.circle", body: [
            "Stops are every way a run ends on its own: when something appears (a picture, words, or a number reaching a value), after a step happens a number of times, after a set time, or if nothing happens for a while.",
            "After a set time applies to every run, whether you started it or its schedule did.",
            "You can always stop with ⌘. or from the menu bar.",
        ]),
        Topic(id: "Schedule", icon: "calendar.badge.clock", body: [
            "Start a macro at set times, every so often, or when its app opens. Each run ends the way Stops says.",
            "Heron can't click while the Mac is locked. Keep the screen on, in Schedule or Settings, stops the screen saver from getting in the way.",
        ]),
        Topic(id: "Keyboard shortcuts", icon: "keyboard", body: [
            "⌘1 Target  ·  ⌘2 Playback  ·  ⌘3 Stops  ·  ⌘4 Schedule",
            "⌘. stops a run.  ⌥⌘↑ / ⌥⌘↓ move the selected steps; add ⇧ to move them to the top or bottom.",
        ]),
        Topic(id: "Privacy", icon: "lock", body: [
            "Everything happens on this Mac. Pictures, text reading and suggestions never leave it.",
            "Heron needs Accessibility (to click and type) and Screen Recording (to see pictures). It asks the first time each is needed.",
        ]),
    ]

    @StateObject private var state = Selection()
    final class Selection: ObservableObject { @Published var topic: Topic? = HelpView.topics.first }

    var body: some View {
        NavigationSplitView {
            List(Self.topics, selection: $state.topic) { t in
                Label(t.id, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            if let t = state.topic {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(t.id, systemImage: t.icon).font(.title2.weight(.semibold))
                        ForEach(t.body, id: \.self) { p in
                            Text(p).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 400)
    }
}

/// Help menu: opens the help window.
struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Heron Help") { openWindow(id: "help") }
                .keyboardShortcut("?", modifiers: .command)
        }
    }
}
