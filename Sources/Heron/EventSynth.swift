import AppKit
import CoreGraphics

/// Where and how synthetic events are delivered.
struct Route {
    var mode: DeliveryMode = .normal
    /// Target process (0 = none). Keyboard events always go here when set.
    var pid: pid_t = 0
    var windowNumber: Int = 0
    /// Added to stored coordinates (the target window's top-left corner).
    var origin: CGPoint = .zero

    static let screen = Route()

    func absolute(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + x, y: origin.y + y)
    }
}

/// Posts synthetic input events. Every event is tagged so the recorder can ignore our own output.
enum EventSynth {
    static let marker: Int64 = 0x4D43_4C4B // "MCLK"

    /// Every posted event carries the marker (high 32 bits) plus a sequence number (low 32 bits), so the
    /// recorder can ignore our own events and `EventEcho` can confirm when one has actually been handled.
    static func isOurs(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.eventSourceUserData) >> 32 == marker
    }

    private static let postLock = NSLock()
    private static var sequence: UInt32 = 0

    /// Private state so the user's physically held modifiers (e.g. from a hotkey) don't leak into clicks.
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        // By default macOS suppresses real hardware input for 0.25s after each synthetic event,
        // which would make the mouse unusable during fast autoclicking.
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    static var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Private CoreGraphics call that sets the click's position *within the window*. The window server
    /// normally fills this in when it routes real input; events posted straight to an app skip that step,
    /// so without it the app can misread where the click happened.
    private typealias SetWindowLocationFn = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocationFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil } // RTLD_DEFAULT
        return unsafeBitCast(sym, to: SetWindowLocationFn.self)
    }()

    /// Posts the event; returns its sequence number. Numbering and posting happen together so that
    /// sequence order is the order events reach the system.
    /// Tests only: when set, events are handed here instead of being posted.
    nonisolated(unsafe) static var testSink: ((CGEvent) -> Void)?

    @discardableResult
    private static func post(_ e: CGEvent, _ route: Route, keyboard: Bool = false) -> UInt32 {
        postLock.lock()
        defer { postLock.unlock() }
        sequence &+= 1
        e.setIntegerValueField(.eventSourceUserData, value: marker << 32 | Int64(sequence))
        if let testSink { testSink(e); return sequence } // tests: record instead of clicking for real
        if route.pid != 0 && (keyboard || route.mode == .background) {
            if !keyboard && route.windowNumber != 0 {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(route.windowNumber))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(route.windowNumber))
                let loc = e.location
                setWindowLocation?(e, CGPoint(x: loc.x - route.origin.x, y: loc.y - route.origin.y))
            }
            e.postToPid(route.pid)
        } else {
            e.post(tap: .cghidEventTap)
        }
        return sequence
    }

    @discardableResult
    static func mouse(_ type: CGEventType, at p: CGPoint, button: MouseButton, clickCount: Int = 1,
                      flags: UInt64 = 0, route: Route = .screen) -> UInt32? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button.cg) else { return nil }
        e.flags = CGEventFlags(rawValue: flags)
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, clickCount)))
        }
        if button == .middle {
            e.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        return post(e, route)
    }

    @discardableResult
    static func scroll(dx: Double, dy: Double, at p: CGPoint?, route: Route = .screen) -> UInt32? {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        if let p { e.location = p }
        return post(e, route)
    }

    static func key(_ code: UInt16, down: Bool, flags: UInt64, route: Route = .screen) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = CGEventFlags(rawValue: flags)
        post(e, route, keyboard: true)
    }

    static func flagsChanged(_ code: UInt16, flags: UInt64, route: Route = .screen) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = CGEventFlags(rawValue: flags)
        post(e, route, keyboard: true)
    }
}

/// Performs macro steps through a route, handling jump-and-return and tracking
/// what is held down so it can always be released.
/// Global click spread: every click lands at a random spot within `radius` of its target, instead of the
/// exact same point each time. Set from Settings › General.
enum ClickSpread {
    private static let lock = NSLock()
    private static var current: Double = 0

    /// Spread radius in points (0 = off).
    static var radius: Double { lock.withLock { current } }

    static func configure(enabled: Bool, radius: Double) {
        lock.withLock { current = enabled ? max(0, radius) : 0 }
    }

    /// A random offset spread evenly over a circle of radius `r`.
    static func randomOffset(_ r: Double) -> CGVector {
        guard r > 0 else { return .zero }
        let d = r * Double.random(in: 0...1).squareRoot(), a = Double.random(in: 0..<(2 * .pi))
        return CGVector(dx: d * cos(a), dy: d * sin(a))
    }

    /// Keeps a point inside `rect` (2 points in from its edges), e.g. so a spread click stays on the button.
    static func clamp(_ p: CGPoint, to rect: CGRect?) -> CGPoint {
        guard let rect else { return p }
        let r = rect.insetBy(dx: min(2, rect.width / 2), dy: min(2, rect.height / 2))
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
}

/// Global double-click: every single click is sent as a double click (drags and long presses stay as they are).
/// Set from Settings › General.
enum DoubleClickEverywhere {
    private static let lock = NSLock()
    private static var on = false
    static var enabled: Bool { lock.withLock { on } }
    static func configure(enabled: Bool) { lock.withLock { on = enabled } }
    /// Presses held at least this long are long presses, not clicks.
    static let longPress = 0.5
}

final class Performer {
    var route: Route
    /// Double-click everywhere bookkeeping: the current press (button, when, whether it dragged), and a
    /// button whose recorded 2nd press is skipped because its first click was already doubled.
    private var press: (button: MouseButton, start: Double, dragged: Bool)?
    private var skipRecordedPress: MouseButton?
    private var skippingRelease: MouseButton?
    /// Spread for the current press, reused for its drags and release and for the next press of a double-click.
    private var pressOffset = CGVector.zero
    /// When set (window coordinates), spread clicks stay inside it, e.g. the picture that was found.
    var spreadBounds: CGRect?
    /// The click spot was already picked at random (a click box): don't add the global spread.
    var spreadPicked = false
    private var heldButtons = Set<MouseButton>()
    private var heldKeys = Set<UInt16>()
    private var touchedModifiers = false
    private var jumpOrigin: CGPoint?
    /// Sequence number of the last pointer event posted during the current jump.
    private var lastPointerSeq: UInt32?
    /// Only one jump-and-return at a time across the whole app (background macros, chains, macros, auto clicker),
    /// so "home" is always where the user left the cursor, never another jump's click spot.
    private static let jumpLock = NSLock()
    private var holdsJumpLock = false
    /// Jump & return: wait until the physical mouse has been still this long before jumping (0 = don't wait).
    var stillThreshold: Double = 0
    var token: CancelToken?

    init(route: Route) { self.route = route }

    /// Blocks until the user's real mouse is idle and no physical button is held. Returns seconds waited.
    private func waitForStillMouse() -> Double {
        guard stillThreshold > 0 else { return 0 }
        let start = Timing.now()
        let motion: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        while token?.isCancelled != true {
            let idle = motion.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
            let held = CGEventSource.buttonState(.hidSystemState, button: .left)
                || CGEventSource.buttonState(.hidSystemState, button: .right)
            if idle >= stillThreshold && !held { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return Timing.now() - start
    }

    /// Applies the click spread to an (absolute) click point. `absolute` = a click at the user's own cursor
    /// position, which is never moved (it would make the cursor wander further with every click).
    func spreadPoint(_ p: CGPoint, newPress: Bool, absolute: Bool) -> CGPoint {
        guard !absolute else { return p }
        if newPress { pressOffset = spreadPicked ? .zero : ClickSpread.randomOffset(ClickSpread.radius) }
        let moved = CGPoint(x: p.x + pressOffset.dx, y: p.y + pressOffset.dy)
        let bounds = spreadBounds.map { b in
            CGRect(origin: route.absolute(Double(b.minX), Double(b.minY)), size: b.size)
        }
        return ClickSpread.clamp(moved, to: bounds)
    }

    private func isPointer(_ a: StepAction) -> Bool {
        switch a {
        case .mouseDown, .mouseUp, .drag, .click: true
        case .scroll(_, _, let x, _): x != nil
        default: false
        }
    }

    /// `absolute`: coordinates are already screen coordinates (don't add the window origin).
    /// Returns how many seconds were spent waiting for the user's mouse to go still (so callers can shift their schedule).
    @discardableResult
    func perform(_ action: StepAction, absolute: Bool = false) -> Double {
        let jump = route.mode == .jumpReturn
        let background = route.mode == .background
        var waited = 0.0
        var landed: CGPoint? // where this step put the real cursor (jump & return bookkeeping)
        let pos: (Double, Double) -> CGPoint = { [route] x, y in
            absolute ? CGPoint(x: x, y: y) : route.absolute(x, y)
        }

        // Plain moves are pointless when we put the cursor back anyway.
        if jump, action.isMouseMove, heldButtons.isEmpty { return 0 }
        if jump, isPointer(action), jumpOrigin == nil {
            if !absolute { waited = waitForStillMouse() }
            Self.jumpLock.lock()
            holdsJumpLock = true
            jumpOrigin = EventSynth.cursor
            lastPointerSeq = nil
        }
        var seq: UInt32?

        switch action {
        case .move(let x, let y):
            EventSynth.mouse(.mouseMoved, at: pos(x, y), button: .left, route: route)
        case .drag(let b, let x, let y):
            press?.dragged = true
            let at = spreadPoint(pos(x, y), newPress: false, absolute: absolute)
            landed = at
            seq = EventSynth.mouse(b.dragType, at: at, button: b, route: route)
        case .mouseDown(let b, _, _, let c, _) where c >= 2 && skipRecordedPress == b:
            // Recorded double-click whose first click was already sent as a double: skip this press and its release.
            skipRecordedPress = nil
            skippingRelease = b
            return waited
        case .mouseUp(let b, _, _, _, _) where skippingRelease == b:
            skippingRelease = nil
            return waited
        case .mouseDown(let b, let x, let y, let c, let f):
            press = c <= 1 ? (b, Timing.now(), false) : nil
            if c <= 1 { skipRecordedPress = nil }
            // A new spot for each new press; the 2nd/3rd press of a double/triple click keeps the first one's.
            let at = spreadPoint(pos(x, y), newPress: c <= 1, absolute: absolute)
            // Some apps only accept a press where the pointer is already hovering.
            if background { EventSynth.mouse(.mouseMoved, at: at, button: .left, route: route) }
            landed = at
            seq = EventSynth.mouse(b.downType, at: at, button: b, clickCount: c, flags: f, route: route)
            heldButtons.insert(b)
        case .mouseUp(let b, let x, let y, let c, let f):
            let at = spreadPoint(pos(x, y), newPress: false, absolute: absolute)
            landed = at
            seq = EventSynth.mouse(b.upType, at: at, button: b, clickCount: c, flags: f, route: route)
            heldButtons.remove(b)
            if c <= 1, let p = press, p.button == b, !p.dragged, Timing.now() - p.start < DoubleClickEverywhere.longPress,
               DoubleClickEverywhere.enabled {
                usleep(30_000) // a short, human-like gap between the two clicks
                EventSynth.mouse(b.downType, at: at, button: b, clickCount: 2, flags: f, route: route)
                seq = EventSynth.mouse(b.upType, at: at, button: b, clickCount: 2, flags: f, route: route)
                skipRecordedPress = b
            }
            press = nil
        case .click(let b, let x, let y, let count):
            let p = (x != nil && y != nil) ? spreadPoint(pos(x!, y!), newPress: true, absolute: absolute) : EventSynth.cursor
            landed = p
            if background { EventSynth.mouse(.mouseMoved, at: p, button: .left, route: route) }
            let presses = count <= 1 && DoubleClickEverywhere.enabled ? 2 : max(1, count)
            for i in 1...presses {
                EventSynth.mouse(b.downType, at: p, button: b, clickCount: i, route: route)
                seq = EventSynth.mouse(b.upType, at: p, button: b, clickCount: i, route: route)
            }
        case .scroll(let dx, let dy, let x, let y):
            let p = (x != nil && y != nil) ? pos(x!, y!) : nil
            landed = p
            // Scroll goes to whatever is under the real cursor, so put it there first.
            if let p, route.mode != .background {
                EventSynth.mouse(.mouseMoved, at: p, button: .left, route: route)
            }
            seq = EventSynth.scroll(dx: dx, dy: dy, at: p, route: route)
        case .key(let code, let down, let f):
            EventSynth.key(code, down: down, flags: f, route: route)
            if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
        case .flags(let code, let f):
            EventSynth.flagsChanged(code, flags: f, route: route)
            touchedModifiers = true
        case .wait, .waitForColor, .findImage, .repeatFrom, .typeList: // control flow, handled by the player
            break
        }

        if let seq, jumpOrigin != nil { lastPointerSeq = seq }
        if jump, heldButtons.isEmpty, let o = jumpOrigin, isPointer(action) {
            returnCursor(to: o, from: landed)
            jumpOrigin = nil
        }
        return waited
    }

    private func releaseJumpLock() {
        if holdsJumpLock {
            holdsJumpLock = false
            Self.jumpLock.unlock()
        }
    }

    /// Puts the real cursor back after a jump.
    ///
    /// Posted events are handled by macOS a moment after we post them, and the clicked app may itself move or
    /// capture the pointer. So: wait until macOS confirms it handled our last event (`EventEcho`), move the
    /// cursor home, then keep watching briefly and put it back if anything other than the user's own hand
    /// moved it. Only a real mouse movement after the click counts as the user taking over.
    private func returnCursor(to origin: CGPoint, from clickPoint: CGPoint?) {
        defer { releaseJumpLock() }
        guard let p = clickPoint else { EventSynth.warp(to: origin); return }
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 2 && abs(a.y - b.y) <= 2 }
        if near(origin, p) { return }
        var entry = JumpLog.Entry(origin: origin, click: p)
        let started = Timing.now()

        var confirmed = false
        if let seq = lastPointerSeq { confirmed = EventEcho.shared.waitUntilHandled(seq, timeout: 0.3) }
        entry.confirmed = confirmed
        entry.confirmMs = (Timing.now() - started) * 1000
        if !confirmed {
            // No confirmation: at least wait until the cursor has reached the click spot.
            let deadline = Timing.now() + 0.15
            while Timing.now() < deadline, !near(EventSynth.cursor, p) { Thread.sleep(forTimeInterval: 0.002) }
        }

        let clickDone = Timing.now()
        EventSynth.warp(to: origin)
        // Watch until the cursor has stayed home for a moment (longer if delivery wasn't confirmed).
        let settle = confirmed ? 0.04 : 0.1
        let giveUp = clickDone + 0.35
        var homeSince = Timing.now()
        while Timing.now() < giveUp {
            Thread.sleep(forTimeInterval: 0.004)
            let c = EventSynth.cursor
            if near(c, origin) {
                if Timing.now() - homeSince >= settle { break }
                continue
            }
            // A physical mouse movement since the click means the user took over: leave the cursor alone.
            let sinceMove = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
            if sinceMove < Timing.now() - clickDone - 0.002 {
                entry.userTookOver = true
                break
            }
            entry.displaced.append(c)
            EventSynth.warp(to: origin)
            homeSince = Timing.now()
        }
        entry.final = EventSynth.cursor
        entry.totalMs = (Timing.now() - started) * 1000
        JumpLog.shared.add(entry)
    }

    /// Never leave buttons or keys stuck down.
    func releaseAll() {
        let p = EventSynth.cursor
        for b in heldButtons { EventSynth.mouse(b.upType, at: p, button: b, route: route) }
        for k in heldKeys { EventSynth.key(k, down: false, flags: 0, route: route) }
        if touchedModifiers { EventSynth.flagsChanged(56, flags: 0, route: route) }
        heldButtons = []
        heldKeys = []
        touchedModifiers = false
        if let o = jumpOrigin { EventSynth.warp(to: o); jumpOrigin = nil }
        releaseJumpLock()
    }
}

// MARK: - Cancellation & timing for worker threads

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum Timing {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Sleeps until `target` (systemUptime seconds). Returns false if cancelled first.
    static func wait(until target: Double, _ token: CancelToken) -> Bool {
        while true {
            if token.isCancelled { return false }
            let remaining = target - now()
            if remaining <= 0 { return true }
            Thread.sleep(forTimeInterval: min(remaining, 0.02))
        }
    }
}

/// Listens (read-only) for our own posted mouse events coming back through the system, so we know when
/// macOS has really handled one. Used to time jump-and-return precisely.
final class EventEcho: @unchecked Sendable {
    static let shared = EventEcho()

    private let lock = NSLock()
    private var handled: UInt32 = 0
    private var started = false
    private var available = false
    private var tap: CFMachPort?

    /// True once event `seq` (or a later one) has been seen; false on timeout or if listening isn't possible.
    func waitUntilHandled(_ seq: UInt32, timeout: Double) -> Bool {
        startIfNeeded()
        guard lock.withLock({ available }) else { return false }
        let deadline = Timing.now() + timeout
        while Timing.now() < deadline {
            if lock.withLock({ handled }) >= seq { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return false
    }

    private func startIfNeeded() {
        let first: Bool = lock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard first else { return }
        let ready = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown,
                                        .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                        .mouseMoved, .scrollWheel]
            let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
                                            if let refcon {
                                                Unmanaged<EventEcho>.fromOpaque(refcon).takeUnretainedValue().note(type, event)
                                            }
                                            return Unmanaged.passUnretained(event)
                                        }, userInfo: refcon)
            if let tap {
                self.tap = tap
                let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                self.lock.withLock { self.available = true }
            }
            ready.signal()
            if tap != nil { CFRunLoopRun() }
        }
        _ = ready.wait(timeout: .now() + 1)
    }

    private func note(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard EventSynth.isOurs(event) else { return }
        let seq = UInt32(truncatingIfNeeded: event.getIntegerValueField(.eventSourceUserData))
        lock.withLock { if seq > handled { handled = seq } }
    }
}

/// Keeps a short record of recent jump-and-returns in a text file, for troubleshooting a cursor that
/// doesn't come back: ~/Library/Application Support/Heron/jump-log.txt
final class JumpLog: @unchecked Sendable {
    static let shared = JumpLog()

    struct Entry {
        let time = Date()
        let origin: CGPoint
        let click: CGPoint
        var confirmed = false
        var confirmMs = 0.0
        var displaced: [CGPoint] = []
        var userTookOver = false
        var final: CGPoint = .zero
        var totalMs = 0.0

        var line: String {
            func pt(_ p: CGPoint) -> String { "(\(Int(p.x)),\(Int(p.y)))" }
            let back = abs(final.x - origin.x) <= 2 && abs(final.y - origin.y) <= 2
            let df = ISO8601DateFormatter()
            df.formatOptions = [.withTime, .withColonSeparatorInTime, .withFractionalSeconds]
            return "\(df.string(from: time)) home \(pt(origin)) click \(pt(click)) "
                + (confirmed ? "confirmed in \(Int(confirmMs))ms" : "NOT confirmed (\(Int(confirmMs))ms)")
                + (displaced.isEmpty ? "" : ", pulled away \(displaced.count)x first to \(pt(displaced[0]))")
                + (userTookOver ? ", user moved the mouse" : "")
                + " → ended \(pt(final)) \(back ? "OK" : userTookOver ? "(user)" : "NOT HOME")"
                + " [\(Int(totalMs))ms, front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")]"
        }
    }

    private let lock = NSLock()
    private var lines: [String] = []
    private let url: URL = {
        AppFolder.url.appendingPathComponent("jump-log.txt")
    }()

    func add(_ e: Entry) {
        let text: String = lock.withLock {
            lines.append(e.line)
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            return lines.joined(separator: "\n") + "\n"
        }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
