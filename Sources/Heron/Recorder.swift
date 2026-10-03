import CoreGraphics
import Foundation

/// Records global mouse & keyboard input via a listen-only event tap on the main run loop.
final class Recorder {
    struct Options {
        var recordMouseMoves = true
        var recordKeyboard = true
        var coalesceInterval: Double = 0.015
        /// Return true for key events that should not be recorded (e.g. our own hotkeys).
        var ignoreKey: (UInt16, CGEventFlags) -> Bool = { _, _ in false }
        /// Only record input aimed at this app; coordinates become relative to its window.
        var target: TargetApp?
        /// Called for each new press (step id, window position), so smart recording can read what's under it.
        var onPress: ((UUID, CGPoint) -> Void)?
    }

    private(set) var steps: [MacroStep] = []
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastTime: Double?
    private var keysDown = Set<UInt16>()
    private var buttonsDown = Set<MouseButton>()
    private var resolver: TargetResolver?
    private var options = Options()
    var onChange: ((Int) -> Void)?

    var isRecording: Bool { tap != nil }

    func start(options: Options) -> Bool {
        stop()
        self.options = options
        steps = []
        lastTime = nil
        keysDown = []
        buttonsDown = []
        resolver = options.target.map { TargetResolver(app: $0) }

        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Stops recording and returns cleaned-up steps.
    @discardableResult
    func stop(trimTrailingClick: Bool = false) -> [MacroStep] {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        return cleaned(trimTrailingClick: trimTrailingClick)
    }

    private func cleaned(trimTrailingClick: Bool) -> [MacroStep] {
        var s = steps
        // Modifier presses/releases from the start/stop hotkey.
        while let first = s.first, case .flags = first.action { s.removeFirst() }
        while let last = s.last, case .flags = last.action { s.removeLast() }

        // The click on the "Stop" button itself. When recording only inside one app, clicks on Heron's own
        // window are never recorded, so the last click is a real one and stays.
        if trimTrailingClick, resolver == nil, let i = s.lastIndex(where: { if case .mouseDown = $0.action { true } else { false } }) {
            let tailIsClickOnly = s[i...].allSatisfy {
                switch $0.action {
                case .mouseDown, .mouseUp, .move, .drag: true
                default: false
                }
            }
            if tailIsClickOnly { s.removeSubrange(i...) }
        }
        // Trailing mouse motion is pointless.
        while let last = s.last, last.action.motionKey != nil { s.removeLast() }

        if !s.isEmpty { s[0].delay = 0 }
        return s
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if EventSynth.isOurs(event) { return }

        var p = event.location
        if let resolver {
            guard let win = resolver.window() else { return }
            let isKey = type == .keyDown || type == .keyUp || type == .flagsChanged
            if isKey {
                guard WindowFinder.frontmostPID() == win.pid else { return }
            } else {
                // Ignore pointer input outside the target window, except to finish a press/drag started inside it.
                let continuing = !buttonsDown.isEmpty && type != .mouseMoved && type != .scrollWheel
                guard win.frame.contains(p) || continuing else { return }
            }
            p = CGPoint(x: p.x - win.frame.minX, y: p.y - win.frame.minY)
        }
        let x = Double(p.x.rounded()), y = Double(p.y.rounded())
        let clicks = Int(event.getIntegerValueField(.mouseEventClickState))
        let flags = event.flags.rawValue
        let action: StepAction

        switch type {
        case .mouseMoved:
            guard options.recordMouseMoves else { return }
            action = .move(x: x, y: y)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let b: MouseButton = type == .leftMouseDragged ? .left : type == .rightMouseDragged ? .right : .middle
            guard buttonsDown.contains(b) else { return }
            action = .drag(button: b, x: x, y: y)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown,
             .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let b: MouseButton = switch type {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            default: .middle
            }
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            if down {
                buttonsDown.insert(b)
                action = .mouseDown(button: b, x: x, y: y, clickCount: clicks, flags: flags)
            } else {
                guard buttonsDown.remove(b) != nil else { return } // press began before recording / outside target
                action = .mouseUp(button: b, x: x, y: y, clickCount: clicks, flags: flags)
            }
        case .scrollWheel:
            let dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            guard dx != 0 || dy != 0 else { return }
            action = .scroll(dx: dx, dy: dy, x: x, y: y)
        case .keyDown, .keyUp:
            guard options.recordKeyboard else { return }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if options.ignoreKey(code, event.flags) { return }
            if type == .keyDown {
                keysDown.insert(code)
            } else {
                // Drop key-ups whose key-down happened before recording began.
                guard keysDown.remove(code) != nil else { return }
            }
            action = .key(keyCode: code, down: type == .keyDown, flags: flags)
        case .flagsChanged:
            guard options.recordKeyboard else { return }
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            action = .flags(keyCode: code, flags: flags)
        default:
            return
        }

        let now = Timing.now()
        if let key = action.motionKey, let last = steps.last, last.action.motionKey == key,
           let lastTime, now - lastTime < options.coalesceInterval {
            // Merge rapid motion into the previous step (keeps total timing intact).
            steps[steps.count - 1].action = action
            return
        }
        let delay = lastTime.map { now - $0 } ?? 0
        lastTime = now
        let step = MacroStep(delay: delay, action: action)
        steps.append(step)
        onChange?(steps.count)
        if case .mouseDown(_, let x, let y, let c, _) = action, c <= 1, resolver != nil {
            options.onPress?(step.id, CGPoint(x: x, y: y))
        }
    }
}
