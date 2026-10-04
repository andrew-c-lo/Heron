import AppKit
import CoreGraphics
import Foundation

/// Something you pressed yourself in the target app while a macro was playing: a hint that the macro is missing
/// a step for it.
struct PressSuggestion: Identifiable {
    let id = UUID()
    var label: ClickReader.Label
    /// Where it was last pressed (window points).
    var point: CGPoint
    var count = 1
    var lastSeen = Date()

    var title: String {
        if let t = label.text { return "“\(t)”" }
        return "This spot"
    }

    /// The same thing pressed again: the same words, or a picture within a few points of the earlier one.
    func matches(_ other: PressSuggestion) -> Bool {
        if let a = label.text, let b = other.label.text {
            return a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard label.picture != nil, other.label.picture != nil else { return false }
        return hypot(point.x - other.point.x, point.y - other.point.y) <= 24
    }

    /// A step that finds it and clicks it (the recorded spot when it can't be found).
    func step(inOrder: Bool) -> ImageStep {
        var s: ImageStep
        if let text = label.text {
            if let png = label.picture {
                s = ImageStep(png: png, width: label.size.width, height: label.size.height,
                              originX: Double(point.x - label.size.width / 2), originY: Double(point.y - label.size.height / 2))
                s.strictness = 0.85
                s.alsoPicture = true
            } else {
                s = ImageStep(png: Data(), width: 0, height: 0, originX: 0, originY: 0)
            }
            s.text = text
        } else {
            s = ImageStep(png: label.picture ?? Data(), width: label.size.width, height: label.size.height,
                          originX: Double(point.x - label.size.width / 2), originY: Double(point.y - label.size.height / 2))
            s.strictness = 0.85
        }
        s.area = label.area
        if inOrder {
            // In order, a missing one shouldn't hold up the rest.
            s.timeout = 3
            s.otherwise = .continueAnyway
        }
        return s
    }

    /// Merges presses into a list, counting repeats; most pressed first.
    static func merge(_ list: [PressSuggestion], _ new: [PressSuggestion]) -> [PressSuggestion] {
        var out = list
        for n in new {
            if let i = out.firstIndex(where: { $0.matches(n) }) {
                out[i].count += n.count
                out[i].point = n.point
                out[i].lastSeen = max(out[i].lastSeen, n.lastSeen)
            } else {
                out.append(n)
            }
        }
        return out.sorted { $0.count > $1.count }
    }
}

/// While a macro plays, notices your own clicks in its target window (Heron's own clicks are tagged and
/// skipped) and remembers what was under them, the same way smart recording does.
final class PressWatcher: @unchecked Sendable {
    private let resolver: TargetResolver
    /// The macro's own picture and text steps: presses on something they already find aren't suggested.
    private let lookups: [Lookup]
    private let queue = DispatchQueue(label: "heron.press-watcher", qos: .utility)
    private let lock = NSLock()
    private var presses: [PressSuggestion] = []
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Finished before the listener was ready: it shuts itself down instead of starting.
    private var finished = false
    /// Every press of yours that was noticed, before looking at it (for tests).
    var onPress: ((CGPoint) -> Void)?

    init(app: TargetApp, steps: [MacroStep]) {
        resolver = TargetResolver(app: app)
        lookups = steps.compactMap { s in
            guard s.enabled, case .findImage(let p) = s.action else { return nil }
            return Lookup(step: p)
        }
    }

    /// Starts listening, on its own thread (creating the listener waits on a system permission check, which can
    /// be slow; nothing waits for it). Without Input Monitoring it simply notices nothing.
    @discardableResult
    func start() -> Bool {
        Thread.detachNewThread { [self] in
            let mask = CGEventMask(1) << CGEventMask(CGEventType.leftMouseDown.rawValue)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: { _, type, event, refcon in
                                            if let refcon {
                                                Unmanaged<PressWatcher>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
                                            }
                                            return Unmanaged.passUnretained(event)
                                        }, userInfo: refcon)
            guard let tap else { return }
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            let stopped = lock.withLock { () -> Bool in
                if self.finished { return true }
                self.tap = tap; self.runLoop = CFRunLoopGetCurrent()
                return false
            }
            if stopped { CFMachPortInvalidate(tap); return }
            CFRunLoopRun()
        }
        return true
    }

    /// Stops listening and returns what you pressed, once pending reads are done.
    func finish() -> [PressSuggestion] {
        let (tap, loop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in self.finished = true; return (self.tap, self.runLoop) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let loop { CFRunLoopStop(loop) }
        lock.withLock { self.tap = nil; self.runLoop = nil }
        queue.sync {}
        return lock.withLock { presses }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ self.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .leftMouseDown, !EventSynth.isOurs(event) else { return }
        let p = event.location
        onPress?(p)
        queue.async { [self] in note(p) }
    }

    private func note(_ screenPoint: CGPoint) {
        guard let win = resolver.window(), win.frame.contains(screenPoint),
              let frame = FrameSource.shared.frame(for: win, after: 0, timeout: 0.3) else { return }
        let local = CGPoint(x: screenPoint.x - win.frame.minX, y: screenPoint.y - win.frame.minY)
        guard let suggestion = Self.suggestion(in: frame.pixels, at: local, lookups: lookups) else { return }
        lock.withLock { presses = PressSuggestion.merge(presses, [suggestion]) }
    }

    /// What's under a press, unless one of the macro's own steps already finds it there.
    static func suggestion(in px: ScreenReader.WindowPixels, at p: CGPoint, lookups: [Lookup]) -> PressSuggestion? {
        let scene = TemplateMatcher.Scene(rgba: px.rgba, width: px.width, height: px.height)
        if lookups.contains(where: { l in
            l.hasPicture && (l.locatePicture(in: px, scene: scene)?.insetBy(dx: -8, dy: -8).contains(p) ?? false)
        }) { return nil }
        let lines = TextFinder.read(px)
        let size = CGSize(width: px.width, height: px.height)
        if var label = ClickReader.label(in: lines, at: p, window: size) {
            if let pic = ClickReader.picture(in: px, at: p) { label.picture = pic.picture; label.size = pic.size }
            let covered = lookups.contains { l in
                guard let t = l.text, l.hasText else { return false }
                return TextFinder.find(t, in: lines, area: l.area)?.insetBy(dx: -8, dy: -8).contains(p) ?? false
            }
            return covered ? nil : PressSuggestion(label: label, point: p)
        }
        return ClickReader.picture(in: px, at: p).map { PressSuggestion(label: $0, point: p) }
    }
}
