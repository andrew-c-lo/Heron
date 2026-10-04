import Foundation
import CoreGraphics

// MARK: - Mouse buttons

enum MouseButton: String, Codable, CaseIterable, Identifiable {
    case left, right, middle

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var cg: CGMouseButton {
        switch self {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    var downType: CGEventType {
        switch self {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    var upType: CGEventType {
        switch self {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    var dragType: CGEventType {
        switch self {
        case .left: .leftMouseDragged
        case .right: .rightMouseDragged
        case .middle: .otherMouseDragged
        }
    }
}

// MARK: - Macro steps

enum StepAction: Codable, Equatable {
    case move(x: Double, y: Double)
    case drag(button: MouseButton, x: Double, y: Double)
    case mouseDown(button: MouseButton, x: Double, y: Double, clickCount: Int, flags: UInt64)
    case mouseUp(button: MouseButton, x: Double, y: Double, clickCount: Int, flags: UInt64)
    /// Editor convenience: full click. nil coordinates = wherever the cursor is at playback time.
    case click(button: MouseButton, x: Double?, y: Double?, count: Int)
    /// Location is where the pointer was (needed to scroll a specific window); nil = wherever the cursor is.
    case scroll(dx: Double, dy: Double, x: Double? = nil, y: Double? = nil)
    case key(keyCode: UInt16, down: Bool, flags: UInt64)
    case flags(keyCode: UInt16, flags: UInt64)
    /// Does nothing; exists so a pure delay can be inserted.
    case wait
    /// Waits up to `timeout` seconds (negative = until it appears) for the pixel at x,y to be `hex`
    /// (within `tolerance` per channel). If it never matches, `otherwise` decides what happens.
    /// `immediate`: ignore recorded timing around the check, so the next action fires the moment the color appears.
    case waitForColor(x: Double, y: Double, hex: String, tolerance: Int, timeout: Double, otherwise: ColorFallback,
                      immediate: Bool? = nil)
    /// Picture step: look for a picture in the target window, then click it / wait for it / wait for it to go.
    case findImage(ImageStep)
    /// Counter: go back to an earlier step, `times` times, then carry on.
    case repeatFrom(step: UUID, times: Int)

    var isMouseMove: Bool {
        if case .move = self { return true }
        return false
    }

    /// Identifies motion events that may be coalesced together while recording.
    var motionKey: String? {
        switch self {
        case .move: "move"
        case .drag(let b, _, _): "drag-\(b.rawValue)"
        default: nil
        }
    }

    var point: CGPoint? {
        get {
            switch self {
            case .move(let x, let y), .drag(_, let x, let y),
                 .mouseDown(_, let x, let y, _, _), .mouseUp(_, let x, let y, _, _):
                return CGPoint(x: x, y: y)
            case .click(_, let x?, let y?, _), .scroll(_, _, let x?, let y?), .waitForColor(let x, let y, _, _, _, _, _):
                return CGPoint(x: x, y: y)
            case .findImage(let s):
                return CGPoint(x: s.originX + s.width / 2, y: s.originY + s.height / 2)
            default:
                return nil
            }
        }
        set {
            guard let p = newValue else { return }
            let x = Double(p.x), y = Double(p.y)
            switch self {
            case .move: self = .move(x: x, y: y)
            case .drag(let b, _, _): self = .drag(button: b, x: x, y: y)
            case .mouseDown(let b, _, _, let c, let f): self = .mouseDown(button: b, x: x, y: y, clickCount: c, flags: f)
            case .mouseUp(let b, _, _, let c, let f): self = .mouseUp(button: b, x: x, y: y, clickCount: c, flags: f)
            case .click(let b, _, _, let c): self = .click(button: b, x: x, y: y, count: c)
            case .scroll(let dx, let dy, _, _): self = .scroll(dx: dx, dy: dy, x: x, y: y)
            case .waitForColor(_, _, let h, let t, let s, let o, let i):
                self = .waitForColor(x: x, y: y, hex: h, tolerance: t, timeout: s, otherwise: o, immediate: i)
            case .findImage(var s):
                // Only a hint of where it was; the click goes wherever the picture is found.
                s.originX = x - s.width / 2
                s.originY = y - s.height / 2
                self = .findImage(s)
            default: break
            }
        }
    }

    var hasEditablePoint: Bool {
        switch self {
        case .move, .drag, .mouseDown, .mouseUp, .click, .scroll, .waitForColor: true
        default: false
        }
    }

    var icon: String {
        switch self {
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .drag: "hand.draw"
        case .mouseDown: "arrow.down.circle"
        case .mouseUp: "arrow.up.circle"
        case .click: "cursorarrow.click"
        case .scroll: "scroll"
        case .key: "keyboard"
        case .flags: "command"
        case .wait: "clock"
        case .waitForColor: "eyedropper"
        case .findImage(let s): s.mode.icon
        case .repeatFrom: "arrow.uturn.backward"
        }
    }

    var summary: String {
        switch self {
        case .move:
            return "Move"
        case .drag(let b, _, _):
            return "\(b.label) drag"
        case .mouseDown(let b, _, _, let c, let f):
            return "\(KeyNames.modifierSymbols(cgFlags: f))\(b.label) down" + (c > 1 ? " (×\(c))" : "")
        case .mouseUp(let b, _, _, let c, let f):
            return "\(KeyNames.modifierSymbols(cgFlags: f))\(b.label) up" + (c > 1 ? " (×\(c))" : "")
        case .click(let b, let x, _, let c):
            let times = c > 1 ? " ×\(c)" : ""
            return "\(b.label) click\(times)" + (x == nil ? " at cursor" : "")
        case .scroll(let dx, let dy, _, _):
            var parts: [String] = []
            if dy != 0 { parts.append("↕ \(Int(dy))") }
            if dx != 0 { parts.append("↔ \(Int(dx))") }
            return "Scroll " + parts.joined(separator: " ")
        case .key(let code, let down, let f):
            return "Key \(KeyNames.modifierSymbols(cgFlags: f))\(KeyNames.name(for: code)) \(down ? "down" : "up")"
        case .flags(_, let f):
            let s = KeyNames.modifierSymbols(cgFlags: f)
            return "Modifiers " + (s.isEmpty ? "released" : s)
        case .wait:
            return "Wait"
        case .findImage(let s):
            return s.mode.label
        case .repeatFrom(_, let n):
            return "Repeat from an earlier step, \(n)×"
        case .waitForColor(_, _, let hex, _, let timeout, _, _):
            return "Wait for \(hex)" + (timeout < 0 ? " (until it appears)" : timeout > 0 ? " (up to \(timeout.formatted())s)" : "")
        }
    }
}

extension StepAction {
    /// The editable settings of a `.waitForColor` step.
    var colorWait: ColorWait? {
        get {
            if case .waitForColor(_, _, let h, let t, let s, let o, let i) = self {
                return ColorWait(hex: h, tolerance: t, timeout: s, otherwise: o, immediate: i ?? false)
            }
            return nil
        }
        set {
            guard let c = newValue, case .waitForColor(let x, let y, _, _, _, _, _) = self else { return }
            self = .waitForColor(x: x, y: y, hex: c.hex, tolerance: c.tolerance, timeout: c.timeout,
                                 otherwise: c.otherwise, immediate: c.immediate)
        }
    }
}

enum ColorFallback: String, Codable, CaseIterable, Identifiable {
    case skipNext, nextLoop, stopMacro, continueAnyway
    /// Picture and text steps only: jump to another step (`ImageStep.goToStep`).
    case goToStep
    var id: String { rawValue }
    var label: String {
        switch self {
        case .skipNext: "Skip the next action"
        case .nextLoop: "Start the next loop"
        case .stopMacro: "Stop the macro"
        case .continueAnyway: "Continue anyway"
        case .goToStep: "Go to another step"
        }
    }
    var shortLabel: String {
        switch self {
        case .skipNext: "skip next"
        case .nextLoop: "next loop"
        case .stopMacro: "stop"
        case .continueAnyway: "continue"
        case .goToStep: "go to step"
        }
    }
}

struct ColorWait: Equatable {
    var hex: String
    var tolerance: Int
    /// Seconds; negative = keep checking until the color appears.
    var timeout: Double
    var otherwise: ColorFallback
    /// Ignore recorded timing: start checking right after the previous action and fire the next one as soon as it matches.
    var immediate: Bool

    var untilAppears: Bool {
        get { timeout < 0 }
        set { timeout = newValue ? -1 : 5 }
    }

    /// Defaults for a new check: wait however long it takes, then act right away.
    static func detect(_ hex: String) -> ColorWait {
        ColorWait(hex: hex, tolerance: 4, timeout: -1, otherwise: .skipNext, immediate: true)
    }
}

extension StepAction {
    static func waitForColor(at p: CGPoint, _ c: ColorWait) -> StepAction {
        .waitForColor(x: Double(p.x), y: Double(p.y), hex: c.hex, tolerance: c.tolerance, timeout: c.timeout,
                      otherwise: c.otherwise, immediate: c.immediate)
    }
}

/// A picture to look for in the target window, and what to do about it.
/// One more picture of the same thing (PNG at 2×, size in points).
struct PictureVariant: Codable, Equatable {
    var png: Data
    var width: Double
    var height: Double
}

struct ImageStep: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        /// `stop`: when it shows up, the macro has done its job and stops (e.g. a level cap reached).
        case click, appear, gone, stop
        var id: String { rawValue }
        var label: String {
            switch self {
            case .click: "Click the picture"
            case .appear: "Wait for the picture"
            case .gone: "Wait until the picture is gone"
            case .stop: "Stop when the picture appears"
            }
        }
        var menuLabel: String {
            switch self {
            case .click: "Click it"
            case .appear: "Just wait for it"
            case .gone: "Wait until it's gone"
            case .stop: "Stop the macro"
            }
        }
        var icon: String {
            switch self {
            case .click: "viewfinder"
            case .appear: "eye"
            case .gone: "eye.slash"
            case .stop: "stop.circle"
            }
        }
    }

    /// The picture (PNG, 2× pixels) and its size in points.
    var png: Data
    var width: Double
    var height: Double
    /// Where it was when picked (window points). Only used to draw it on the map.
    var originX: Double
    var originY: Double
    var mode: Mode = .click
    var strictness: Double = 0.8
    /// Seconds; negative = no time limit.
    var timeout: Double = -1
    var otherwise: ColorFallback = .stopMacro
    var button: MouseButton = .left
    var offsetX: Double = 0
    var offsetY: Double = 0
    /// Seconds it must be visible before clicking (for things that animate in).
    var settle: Double = 0
    /// Keep clicking every `repeatEvery` seconds until it disappears (for taps that don't register the first time).
    var repeatUntilGone = false
    var repeatEvery: Double = 0.5
    /// Smart recording: if it isn't found in time, click here instead (window points), where it was recorded.
    var fallbackX: Double?
    var fallbackY: Double?
    /// With `otherwise == .goToStep`: the step to continue from (branching).
    var goToStep: UUID?
    /// More pictures that count as the same thing (for example the same button in different states).
    var variants: [PictureVariant] = []
    /// With text set: the picture counts too (“Both”), whichever is found first.
    var alsoPicture = false
    /// Click a fixed spot without looking (the picture and words are kept, so switching back is one click).
    var spotOnly = false
    /// That spot (window points).
    var spotX: Double?
    var spotY: Double?
    /// Where in the picture to click, as fractions of its width and height (nil = the middle, spread over all of it).
    var clickArea: CGRect?
    /// Look for this text instead of the picture (nil = picture).
    var text: String?
    /// Only search inside this part of the window (window points; nil = whole window).
    var area: CGRect?

    var isText: Bool { !(text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    /// Whether the picture is looked for (Picture, or Both with a picture picked).
    var usesPicture: Bool { (text == nil || alsoPicture) && !png.isEmpty }

    /// The fixed spot to click: the one set, else where it was recorded, else the middle of the picture where it
    /// was picked.
    var spot: CGPoint? {
        if let x = spotX, let y = spotY { return CGPoint(x: x, y: y) }
        if let x = fallbackX, let y = fallbackY { return CGPoint(x: x, y: y) }
        if !png.isEmpty, width > 0 { return CGPoint(x: originX + width / 2, y: originY + height / 2) }
        return nil
    }

    /// Switches between clicking the spot and finding the picture or words (keeping both).
    mutating func setSpotOnly(_ on: Bool) {
        if on, spotX == nil, let p = spot { spotX = Double(p.x); spotY = Double(p.y) }
        spotOnly = on
    }

    init(png: Data, width: Double, height: Double, originX: Double, originY: Double) {
        self.png = png
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
    }

    /// Where to click on a found picture (window points) and the box click spread must stay in.
    func clickTarget(in found: CGRect) -> (point: CGPoint, bounds: CGRect) {
        var box = found
        if let a = clickArea {
            box = CGRect(x: found.minX + a.minX * found.width, y: found.minY + a.minY * found.height,
                         width: max(1, a.width * found.width), height: max(1, a.height * found.height))
        }
        box = box.offsetBy(dx: offsetX, dy: offsetY)
        return (CGPoint(x: box.midX, y: box.midY), box)
    }

    var untilAppears: Bool {
        get { timeout < 0 }
        set { timeout = newValue ? -1 : 10 }
    }
}

extension ImageStep {
    // Hand-written so steps saved by older versions (missing newer fields) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        png = try c.decode(Data.self, forKey: .png)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        originX = try c.decodeIfPresent(Double.self, forKey: .originX) ?? 0
        originY = try c.decodeIfPresent(Double.self, forKey: .originY) ?? 0
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .click
        strictness = try c.decodeIfPresent(Double.self, forKey: .strictness) ?? 0.8
        timeout = try c.decodeIfPresent(Double.self, forKey: .timeout) ?? -1
        otherwise = try c.decodeIfPresent(ColorFallback.self, forKey: .otherwise) ?? .stopMacro
        button = try c.decodeIfPresent(MouseButton.self, forKey: .button) ?? .left
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        settle = try c.decodeIfPresent(Double.self, forKey: .settle) ?? 0
        repeatUntilGone = try c.decodeIfPresent(Bool.self, forKey: .repeatUntilGone) ?? false
        repeatEvery = try c.decodeIfPresent(Double.self, forKey: .repeatEvery) ?? 0.5
        fallbackX = try c.decodeIfPresent(Double.self, forKey: .fallbackX)
        fallbackY = try c.decodeIfPresent(Double.self, forKey: .fallbackY)
        goToStep = try c.decodeIfPresent(UUID.self, forKey: .goToStep)
        variants = try c.decodeIfPresent([PictureVariant].self, forKey: .variants) ?? []
        alsoPicture = try c.decodeIfPresent(Bool.self, forKey: .alsoPicture) ?? false
        spotOnly = try c.decodeIfPresent(Bool.self, forKey: .spotOnly) ?? false
        spotX = try c.decodeIfPresent(Double.self, forKey: .spotX)
        spotY = try c.decodeIfPresent(Double.self, forKey: .spotY)
        clickArea = try c.decodeIfPresent(CGRect.self, forKey: .clickArea)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        area = try c.decodeIfPresent(CGRect.self, forKey: .area)
    }
}

struct MacroStep: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Seconds to wait (at 1× speed) before performing this step.
    var delay: Double
    var action: StepAction
    /// Switched-off steps stay in the macro but are skipped when it plays.
    var enabled = true

    init(id: UUID = UUID(), delay: Double, action: StepAction, enabled: Bool = true) {
        self.id = id
        self.delay = delay
        self.action = action
        self.enabled = enabled
    }
}

extension MacroStep {
    // Hand-written so steps saved before on/off switches existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        delay = try c.decode(Double.self, forKey: .delay)
        action = try c.decode(StepAction.self, forKey: .action)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

struct PlaybackOptions: Codable, Equatable {
    enum RepeatMode: String, Codable, CaseIterable, Identifiable {
        case once, times, untilStopped, duration
        var id: String { rawValue }
        var label: String {
            switch self {
            case .once: "Once"
            case .times: "Number of times"
            case .untilStopped: "Until stopped"
            case .duration: "For a duration"
            }
        }
    }

    enum StepOrder: String, Codable, CaseIterable, Identifiable {
        /// One step after another.
        case inOrder
        /// Watch every picture step at once and click whichever appears.
        case allAtOnce
        var id: String { rawValue }
        var label: String { self == .inOrder ? "In order" : "All at once" }
    }

    var speed: Double = 1
    var order: StepOrder = .inOrder
    /// All at once: stop after this many clicks (0 = no limit).
    var maxClicks: Int = 0
    /// All at once: when several pictures are on screen, the one higher in the list wins (instead of taking turns).
    var prioritized = false
    /// All at once: if nothing has been clicked for this many seconds, tap the idle spot (0 = off).
    var idleTapAfter: Double = 0
    var idleTapX: Double?
    var idleTapY: Double?
    var repeatMode: RepeatMode = .once
    /// Used by `.times`.
    var loops: Int = 2
    /// Used by `.duration`, in seconds. No new loop starts after this; the current one finishes.
    var repeatDuration: Double = 600
    /// Real seconds between loops (not affected by speed).
    /// Killswitch: whenever this picture or these words show up during a run, the macro has done its job and stops.
    var stopWhen: ImageStep?
    var loopDelay: Double = 0
    /// Up to this many extra random seconds added to each pause.
    var loopDelayRandom: Double = 0
    var skipMouseMoves = false

    /// nil = no fixed count.
    var loopCount: Int? {
        switch repeatMode {
        case .once: 1
        case .times: max(1, loops)
        case .untilStopped, .duration: nil
        }
    }
}

extension PlaybackOptions {
    // Hand-written so macros saved before repeat modes existed keep their meaning (loops 0 = forever).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        order = try c.decodeIfPresent(StepOrder.self, forKey: .order) ?? .inOrder
        let storedLoops = try c.decodeIfPresent(Int.self, forKey: .loops) ?? 2
        loops = max(1, storedLoops)
        repeatMode = try c.decodeIfPresent(RepeatMode.self, forKey: .repeatMode)
            ?? (storedLoops == 0 ? .untilStopped : storedLoops == 1 ? .once : .times)
        repeatDuration = try c.decodeIfPresent(Double.self, forKey: .repeatDuration) ?? 600
        loopDelay = try c.decodeIfPresent(Double.self, forKey: .loopDelay) ?? 0
        loopDelayRandom = try c.decodeIfPresent(Double.self, forKey: .loopDelayRandom) ?? 0
        skipMouseMoves = try c.decodeIfPresent(Bool.self, forKey: .skipMouseMoves) ?? false
        prioritized = try c.decodeIfPresent(Bool.self, forKey: .prioritized) ?? false
        idleTapAfter = try c.decodeIfPresent(Double.self, forKey: .idleTapAfter) ?? 0
        idleTapX = try c.decodeIfPresent(Double.self, forKey: .idleTapX)
        idleTapY = try c.decodeIfPresent(Double.self, forKey: .idleTapY)
        maxClicks = try c.decodeIfPresent(Int.self, forKey: .maxClicks) ?? 0
        stopWhen = try c.decodeIfPresent(ImageStep.self, forKey: .stopWhen)
    }
}

struct Macro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
    var steps: [MacroStep]
    var playback = PlaybackOptions()
    /// When target.app is set, step coordinates are relative to that app's window.
    var target = TargetOptions()
    /// Runs on its own, alongside whatever else is playing, with its own on/off switch
    /// (what used to be a "watcher").
    var runsInBackground = false
    /// Folder in the macro list (nil = not in a folder).
    var folder: String?

    var duration: Double { steps.reduce(0) { $0 + $1.delay } }
}

// MARK: - Auto clicker

struct ClickPoint: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: Double
    var y: Double
    /// "#RRGGBB" this point must show for a click to happen (when color checks are on).
    var color: String?
}

struct AutoClickSettings: Codable, Equatable {
    enum LocationMode: String, Codable, CaseIterable, Identifiable {
        case cursor, points
        var id: String { rawValue }
    }

    enum StopMode: String, Codable, CaseIterable, Identifiable {
        case never, afterClicks, afterSeconds
        var id: String { rawValue }
    }

    var intervalMs: Double = 100
    var jitterMs: Double = 0
    var button: MouseButton = .left
    var clicksPerEvent: Int = 1
    var holdMs: Double = 0
    var location: LocationMode = .cursor
    var points: [ClickPoint] = []
    var target = TargetOptions(delivery: .jumpReturn)
    var stopMode: StopMode = .never
    var stopClicks: Int = 100
    var stopSeconds: Double = 60
    var startDelay: Double = 0
    /// Only click when the color at the click point matches (per-point color, or `cursorColor` when following the cursor).
    var colorCheck = false
    var colorTolerance = 4
    var cursorColor: String?
}

// MARK: - Preferences

struct Preferences: Codable, Equatable {
    var recordMouseMoves = true
    var recordKeyboard = true
    /// Mouse motion events closer together than this are merged while recording.
    var moveCoalesceMs: Double = 15
    var recordCountdown: Int = 0
    var playSounds = true
    /// Only record input inside this app's window; coordinates become window-relative.
    var recordTarget: TargetApp?
    /// Every click lands at a random spot within `clickSpreadRadius` points of its target.
    var clickSpread = true
    var clickSpreadRadius: Double = 15
    /// A notification when something stops on its own while Heron is in the background.
    var notifyWhenStopped = true
    /// Recorded clicks on a short label become “Click “label”” steps (needs “Record only in” and Screen Recording).
    var smartRecording = true
    /// Every single click is sent as a double click (everywhere: auto clicker, macros, chains, watchers).
    var doubleClickEverywhere = false
    /// While a macro plays, your own clicks in its app are noticed and offered as steps.
    var suggestFromMyPresses = true
}

// MARK: - Formatting

func formatDuration(_ s: Double) -> String {
    if s < 60 { return String(format: "%.2fs", s) }
    let m = Int(s) / 60
    return String(format: "%dm %.1fs", m, s - Double(m * 60))
}
