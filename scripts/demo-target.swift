// A small practice app for the README demo: "Claim" buttons light up on random cards, and Heron claims them.
// Built by scripts/record-demo.sh as .demo/Rewards.app (bundle id com.example.rewards, the demo data's target).
import AppKit

/// Clicks count even while the app is in the background (Heron's background clicks).
final class ClaimButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Card: NSView {
    let title = NSTextField(labelWithString: "")
    let state = NSTextField(labelWithString: "")
    let button = ClaimButton(title: "Claim", target: nil, action: nil)
    var onClaim: (() -> Void)?

    init(day: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        title.stringValue = "Day \(day)"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        state.font = .systemFont(ofSize: 13)
        state.textColor = .secondaryLabelColor
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.bezelColor = .systemBlue
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.target = self
        button.action = #selector(claim)
        for v in [title, state, button] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            state.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            state.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        set(.waiting)
    }
    required init?(coder: NSCoder) { fatalError() }

    enum State { case waiting, ready, claimed }
    private(set) var current = State.waiting

    func set(_ s: State) {
        current = s
        button.isHidden = s != .ready
        switch s {
        case .waiting: state.stringValue = "Not yet"; layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
        case .ready: state.stringValue = "+50 coins"; layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.16).cgColor
        case .claimed: state.stringValue = "Claimed ✓"; layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.16).cgColor
        }
    }

    @objc func claim() { guard current == .ready else { return }; set(.claimed); onClaim?() }
}

final class Controller: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var cards: [Card] = []
    let coins = NSTextField(labelWithString: "")
    var total = 120

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Rewards"
        window.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        window.contentView = root

        let heading = NSTextField(labelWithString: "Daily rewards")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        coins.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        coins.textColor = .secondaryLabelColor
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        for row in 0..<3 {
            let pair = (0..<2).map { col -> Card in
                let c = Card(day: row * 2 + col + 1)
                c.onClaim = { [weak self] in self?.claimed() }
                c.translatesAutoresizingMaskIntoConstraints = false
                c.widthAnchor.constraint(equalToConstant: 170).isActive = true
                c.heightAnchor.constraint(equalToConstant: 100).isActive = true
                cards.append(c)
                return c
            }
            grid.addRow(with: pair)
        }
        for v in [heading, coins, grid] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            coins.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            coins.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            grid.topAnchor.constraint(equalTo: coins.bottomAnchor, constant: 18),
        ])
        updateCoins()
        // DEMO_WINDOW_ORIGIN=x,y places the window (screen points, from the top left).
        if let o = ProcessInfo.processInfo.environment["DEMO_WINDOW_ORIGIN"]?.split(separator: ",").compactMap({ Double($0) }),
           o.count == 2, let screen = NSScreen.main {
            window.setFrameTopLeftPoint(NSPoint(x: o[0], y: screen.frame.maxY - o[1]))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.next() }
    }

    func updateCoins() { coins.stringValue = "Coins: \(total)" }

    /// Lights up one waiting card at random, until all are claimed.
    func next() {
        let waiting = cards.filter { $0.current == .waiting }
        guard let c = waiting.randomElement() else {
            coins.stringValue = "Coins: \(total) · All claimed"
            return
        }
        c.set(.ready)
    }

    func claimed() {
        total += 50
        updateCoins()
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 0.6...1.2)) { self.next() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
