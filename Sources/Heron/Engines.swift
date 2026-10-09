import AppKit
import CoreGraphics

struct RouteError: Error { let message: String }

/// Builds the route for a target, or explains why it can't.
enum RouteBuilder {
    static func route(for target: TargetOptions, resolver: TargetResolver?) -> Result<Route, RouteError> {
        guard let resolver else {
            if target.delivery == .background {
                return .failure(RouteError(message: "Background clicking needs a target app."))
            }
            return .success(Route(mode: target.delivery))
        }
        guard let w = resolver.window() else {
            return .failure(RouteError(message: "The \(resolver.app.name) window went away, so the run stopped."))
        }
        var route = Route(mode: target.delivery, pid: w.pid, windowNumber: w.windowNumber, origin: w.frame.origin,
                          focusFlash: target.delivery == .background && FocusFlash.needed(for: resolver.app.bundleID))
        if target.delivery == .background, AndroidBridge.emulators.contains(resolver.app.bundleID) {
            // Its Android screen only takes taps over ADB.
            guard let screen = AndroidScreen.find(pid: w.pid, windowFrame: w.frame) else {
                return .failure(RouteError(message: "Couldn't reach Android in \(resolver.app.name). Turn on Android Debug Bridge in its Settings › Advanced, or switch Target to Jump & return."))
            }
            route.android = screen
        }
        return .success(route)
    }
}

/// Replays a macro on a background thread.
final class Player {
    /// Marks a finish message as success (a stop condition was reached), not a problem.
    static let donePrefix = "\u{2713} "
    static func done(_ what: String) -> String { donePrefix + "Done: \(what)." }
    static func isDone(_ message: String) -> Bool { message.hasPrefix(donePrefix) }
    private var token: CancelToken?

    var isRunning: Bool { token != nil }

    func play(_ macro: Macro,
              startDelay: Double = 0,
              progress: @escaping @MainActor (_ step: Int, _ loop: Int, _ pausing: Double?) -> Void,
              waiting: @escaping @MainActor (_ color: String?) -> Void = { _ in },
              clicked: @escaping @MainActor (_ step: UUID, _ found: CGRect?) -> Void = { _, _ in },
              stuck: @escaping @MainActor (_ screen: ScreenReader.WindowPixels) -> Void = { _ in },
              listAdvanced: @escaping @MainActor (_ step: UUID, _ next: Int) -> Void = { _, _ in },
              counted: @escaping @MainActor (_ times: Int) -> Void = { _ in },
              finished: @escaping @MainActor (_ error: String?) -> Void) {
        stop()
        let token = CancelToken()
        self.token = token
        let opts = macro.playback
        let target = macro.target
        // Switched-off steps are skipped entirely (their waits too).
        let enabledSteps = Self.playable(macro.steps)
        let steps = opts.skipMouseMoves ? Self.removingMoves(enabledSteps) : enabledSteps
        // Where each If's Otherwise and End are, to jump between them.
        let ifBlocks = IfBlocks(steps.map(\.action))
        let speed = max(opts.speed, 0.01)
        let groups = ActionGrouper.groups(for: steps)
        // Color checks that ignore timing: no recorded wait before the check, or before the action after it.
        let delays: [Double] = {
            var d = steps.map(\.delay)
            for (gi, g) in groups.enumerated() {
                guard case .colorWait(_, let c) = g.kind, c.immediate else { continue }
                for k in g.lead { d[k] = 0 }
                if gi + 1 < groups.count { for k in groups[gi + 1].lead { d[k] = 0 } }
            }
            return d
        }()
        // For "skip the next action": index just past the action that follows each step's action.
        let nextActionEnd: [Int] = {
            var map = [Int](repeating: steps.count, count: steps.count)
            for (gi, g) in groups.enumerated() {
                let end = gi + 1 < groups.count ? groups[gi + 1].range.upperBound : steps.count
                for k in g.range { map[k] = end }
            }
            return map
        }()

        // “Type from a list”: each item as key presses, worked out here (the keyboard layout is read on the main thread).
        // A key on the current layout where there is one; otherwise the character itself (é, 😀, 你).
        var listKeys: [UUID: [[ListKey]]] = [:]
        for st in steps {
            if case .typeList(let l) = st.action {
                listKeys[st.id] = l.entries.map { $0.map { ch in KeyText.key(for: ch).map { .key($0.code, shift: $0.shift) } ?? .text(String(ch)) } }
            }
        }
        let typingKeys = listKeys

        // The killswitch watches on its own, for the whole run.
        let watch = CancelToken()
        let tripped = Tripwire()
        if let kill = opts.stopWhen, let app = target.app, let lookup = Self.killswitchLookup(kill, opts, target) {
            let what = opts.stopAtNumber.map { "the number reached \($0)" }
                ?? (kill.isText && !kill.usesPicture ? "“\(kill.text!.trimmingCharacters(in: .whitespaces))” appeared" : "the stop picture appeared")
            Thread.detachNewThread {
                Self.watchKillswitch(lookup, atLeast: opts.stopAtNumber, resolver: TargetResolver(app: app), watch: watch) {
                    tripped.message = Self.done(what.prefix(1).uppercased() + what.dropFirst())
                    token.cancel()
                }
            }
        }
        // Stops › After a set time: the whole run, however it started.
        if opts.stopAfterMinutes > 0 {
            let limit = opts.stopAfterMinutes * 60, start = Timing.now()
            Thread.detachNewThread {
                while Timing.now() - start < limit {
                    guard Timing.wait(until: min(start + limit, Timing.now() + 1), watch) else { return }
                }
                tripped.message = Self.done("ran for \(formatSpan(limit))")
                token.cancel()
            }
        }
        // Nothing happening for too long: stop, as a problem.
        let idle = IdleClock()
        if opts.stopIfIdleMinutes > 0 {
            let limit = opts.stopIfIdleMinutes * 60, minutes = opts.stopIfIdleMinutes
            Thread.detachNewThread {
                while Timing.wait(until: Timing.now() + 1, watch) {
                    if Timing.now() - idle.last > limit {
                        tripped.message = "Stopped: nothing happened for \(minutes.formatted()) minute\(minutes == 1 ? "" : "s")."
                        token.cancel()
                        return
                    }
                }
            }
        }

        Thread.detachNewThread { [weak self] in
            defer { watch.cancel() }
            let resolver = target.app.map { TargetResolver(app: $0) }
            let performer = Performer(route: .screen)
            performer.token = token
            performer.stillThreshold = target.jumpWhenStillMs / 1000
            let pauseable = target.pauseWhenInactive && target.app != nil && target.delivery != .background
            var error: String?
            var lastReport = 0.0
            var loop = 0

            // Where each list is up to (carried across loops, and saved back after each item).
            var listNext: [UUID: Int] = [:]
            // “Stop after it happens N times” counts across loops; a step that times out doesn't count.
            var timesSoFar = 0
            // When the last round was counted: one within the cooldown is the same round (a double press).
            var lastRoundAt = -Double.infinity
            var stepMissed = false

            if opts.order == .allAtOnce {
                error = Self.runAllAtOnce(steps, opts: opts, target: target, resolver: resolver, performer: performer,
                                          pauseable: pauseable, token: token, idle: idle, progress: progress, waiting: waiting,
                                          clicked: clicked, stuck: stuck, counted: counted)
            } else {
                outer: while true {
                    if let n = opts.loopCount, loop >= n { break }

                    var pause = startDelay
                    if loop > 0 {
                        pause = opts.loopDelay + (opts.loopDelayRandom > 0 ? Double.random(in: 0...opts.loopDelayRandom) : 0)
                        if pause > 0 {
                            let l = loop + 1, p = pause
                            Task { @MainActor in progress(0, l, p) }
                        }
                    }
                    if pause > 0 {
                        guard Timing.wait(until: Timing.now() + pause, token) else { break }
                    }
                    var t = Timing.now()
                    let loopStarted = t
                    var skipUntil = -1
                    // Steps go by index so “Go to step” and “Repeat from” can jump; counters restart each loop.
                    var repeatsLeft: [UUID: Int] = [:]
                    var timesHappened = timesSoFar
                    var i = 0
                    while i < steps.count {
                        let step = steps[i]
                        var next = i + 1
                        defer { i = next }
                        stepMissed = false
                        if i < skipUntil { continue }
                        t += opts.varied(delays[i]) / speed
                        guard Timing.wait(until: t, token) else { break outer }

                        switch RouteBuilder.route(for: target, resolver: resolver) {
                        case .success(let r): performer.route = r
                        case .failure(let e): error = e.message; break outer
                        }
                        if pauseable {
                            // Hold here (and shift the schedule) until the target app is frontmost again.
                            while WindowFinder.frontmostPID() != performer.route.pid {
                                guard Timing.wait(until: Timing.now() + 0.1, token) else { break outer }
                                t += 0.1
                            }
                        }
                        if case .findImage(let pic) = step.action, pic.spotOnly, pic.mode == .click, let p0 = pic.spot {
                            // Set to its spot: click there without looking.
                            let win = resolver?.window()
                            if let win { performer.route.origin = win.frame.origin }
                            let p = WindowFit.between(pic.reference(fallback: target.windowSize), win?.frame.size,
                                                      emulator: target.isAndroidEmulator).point(p0)
                            performer.perform(.mouseDown(button: pic.button, x: Double(p.x), y: Double(p.y), clickCount: 1, flags: 0))
                            performer.perform(.mouseUp(button: pic.button, x: Double(p.x), y: Double(p.y), clickCount: 1, flags: 0))
                            let stepID = step.id
                            Task { @MainActor in clicked(stepID, nil) }
                            t = Timing.now()
                        } else if case .findImage(let pic) = step.action {
                            guard let resolver else {
                                error = "Picture steps need a target app. Choose one with the Target button."
                                break outer
                            }
                            if pic.text != nil && !pic.isText && !pic.usesPicture {
                                error = "Step \(i + 1) has no text to look for. Type it in the step's settings."
                                break outer
                            }
                            let words = pic.isText ? "“\(pic.text!.trimmingCharacters(in: .whitespaces))”" : nil
                            let looking = pic.usesPicture ? (words.map { "the picture or \($0)" } ?? "the picture") : words ?? "the text"
                            Task { @MainActor in waiting(looking) }
                            let stepID = step.id
                            let result = Self.runPictureStep(pic, performer: performer, resolver: resolver, token: token,
                                                             reference: target.windowSize, emulator: target.isAndroidEmulator,
                                                             waitForStill: opts.waitForStill,
                                                             onFound: { r in Task { @MainActor in clicked(stepID, r) } })
                            Task { @MainActor in waiting(nil) }
                            if pic.mode == .stop {
                                // A stop condition: seen means done; not seen means carry on.
                                switch result {
                                case .cancelled: break outer
                                case .unreadable:
                                    error = "Couldn't see \(resolver.app.name). Picture steps need Screen Recording permission."
                                    break outer
                                case .matched:
                                    Task { @MainActor in clicked(stepID, nil) }
                                    error = Self.done("\(looking) appeared")
                                    break outer
                                case .timedOut:
                                    t = Timing.now()
                                    stepMissed = true
                                    continue
                                }
                            }
                            switch result {
                            case .cancelled: break outer
                            case .unreadable:
                                error = "Couldn't see \(resolver.app.name). Picture steps need Screen Recording permission."
                                break outer
                            case .matched: break
                            case .timedOut:
                                stepMissed = true
                                switch pic.otherwise {
                                case .continueAnyway: break
                                case .skipNext: skipUntil = nextActionEnd[i]
                                case .nextLoop: t = Timing.now(); loop += 1; continue outer
                                case .goToStep:
                                    if let target = pic.goToStep, let j = steps.firstIndex(where: { $0.id == target }) { next = j }
                                case .stopMacro:
                                    error = "Stopped: step \(i + 1)'s \(pic.text != nil ? "text" : "picture") didn't \(pic.mode == .gone ? "go away" : "appear") in time."
                                    break outer
                                }
                            }
                            t = Timing.now()
                        } else if case .waitForColor(let x, let y, let hex, let tol, let timeout, let otherwise, _) = step.action {
                            Task { @MainActor in waiting(hex) }
                            let cp = target.fit(for: resolver?.window()?.frame.size).point(CGPoint(x: x, y: y))
                            let result = Self.waitForColor(at: performer.route.absolute(Double(cp.x), Double(cp.y)), hex: hex, tolerance: tol,
                                                           timeout: timeout, token: token)
                            Task { @MainActor in waiting(nil) }
                            switch result {
                            case .cancelled: break outer
                            case .unreadable:
                                error = "Couldn't read the screen. Color checks need Screen Recording permission (Settings tab)."
                                break outer
                            case .matched:
                                break
                            case .timedOut:
                                switch otherwise {
                                case .continueAnyway: break
                                case .skipNext: skipUntil = nextActionEnd[i]
                                case .nextLoop: t = Timing.now(); loop += 1; continue outer
                                case .goToStep: break // picture and text steps only
                                case .stopMacro:
                                    error = "Stopped: \(hex) didn't appear at (\(Int(x)), \(Int(y)))."
                                    break outer
                                }
                            }
                            t = Timing.now() // waiting shifts the rest of the schedule
                        } else if case .repeatFrom(let target, let times) = step.action {
                            let left = repeatsLeft[step.id] ?? times
                            if left > 0, let j = steps.firstIndex(where: { $0.id == target }), j < i {
                                repeatsLeft[step.id] = left - 1
                                next = j
                            } else {
                                repeatsLeft[step.id] = nil // ready for next time it's reached
                            }
                        } else if case .typeList(let l) = step.action {
                            let items = typingKeys[step.id] ?? []
                            var n = max(0, listNext[step.id] ?? l.next)
                            if n >= items.count {
                                guard l.whenDone == .startOver, !items.isEmpty else {
                                    error = Self.done(items.isEmpty ? "the list is empty" : "typed all \(items.count) items from the list")
                                    break outer
                                }
                                n = 0
                            }
                            for k in items[n] {
                                switch k {
                                case .key(let code, let shift):
                                    let flags: UInt64 = shift ? CGEventFlags.maskShift.rawValue : 0
                                    performer.perform(.key(keyCode: code, down: true, flags: flags))
                                    guard Timing.wait(until: Timing.now() + 0.03, token) else { break outer }
                                    performer.perform(.key(keyCode: code, down: false, flags: flags))
                                case .text(let ch):
                                    performer.text(ch, down: true)
                                    guard Timing.wait(until: Timing.now() + 0.03, token) else { break outer }
                                    performer.text(ch, down: false)
                                }
                                guard Timing.wait(until: Timing.now() + 0.03, token) else { break outer }
                            }
                            if l.pressReturn {
                                performer.perform(.key(keyCode: 36, down: true, flags: 0))
                                performer.perform(.key(keyCode: 36, down: false, flags: 0))
                            }
                            listNext[step.id] = n + 1
                            let id = step.id, after = n + 1
                            Task { @MainActor in listAdvanced(id, after) }
                            t = Timing.now()
                        } else if case .ifStart(let c) = step.action {
                            // If: carry on into its steps when it holds; otherwise jump past its Otherwise (or End).
                            if c.kind != .round { let what = c.lookingFor; Task { @MainActor in waiting(what) } }
                            let result = Self.check(c, round: loop + 1, resolver: resolver, target: target,
                                                    performer: performer, token: token)
                            if c.kind != .round { Task { @MainActor in waiting(nil) } }
                            switch result {
                            case .cancelled: break outer
                            case .needsTarget:
                                error = "Step \(i + 1) checks the screen, so it needs a target app. Choose one with the Target button."
                                break outer
                            case .unreadable:
                                error = "Couldn't see \(resolver?.app.name ?? "the window"). Checking the screen needs Screen Recording permission."
                                break outer
                            case .yes: break
                            case .no: next = (ifBlocks.otherwise[i] ?? ifBlocks.end[i]).map { $0 + 1 } ?? steps.count
                            }
                            let stepID = step.id, held = result == .yes
                            Task { @MainActor in if held { clicked(stepID, nil) } }
                            // Counts toward “stop after it happens N times” only when its check held.
                            if !held { stepMissed = true }
                            t = Timing.now()
                        } else if case .otherwise = step.action {
                            // Reached by finishing the If's own steps: skip the Otherwise steps.
                            next = ifBlocks.endAfterOtherwise[i].map { $0 + 1 } ?? steps.count
                        } else if step.action.isFlowMarker {
                            // End of an If, or a Run step whose macro couldn't be found: nothing to do.
                        } else {
                            t += performer.perform(Self.scaled(step.action, target.fit(for: resolver?.window()?.frame.size)))
                        }

                        // Counted toward “stop after it happens N times” (a step that timed out didn't happen).
                        if !stepMissed {
                            idle.touch()
                            if step.id == opts.stopAfterStep, Timing.now() - lastRoundAt >= opts.roundGap {
                                lastRoundAt = Timing.now()
                                timesHappened += 1
                                timesSoFar = timesHappened
                                let n = timesHappened
                                Task { @MainActor in counted(n) }
                                if let limit = opts.roundLimit, timesHappened >= limit {
                                    error = Self.done("\(limit) run\(limit == 1 ? "" : "s") (\(Self.stepName(step, i)))")
                                    break outer
                                }
                            }
                        }
                        stepMissed = false

                        let now = Timing.now()
                        if now - lastReport > 0.05 || i == steps.count - 1 {
                            lastReport = now
                            let s = i + 1, l = loop + 1
                            Task { @MainActor in progress(s, l, nil) }
                        }
                    }
                    loop += 1
                    // A loop that takes no time at all (say, steps with no waits) gets a breather, so repeating
                    // until stopped can't pin the processor.
                    if Timing.now() - loopStarted < 0.01 {
                        guard Timing.wait(until: loopStarted + 0.01, token) else { break }
                    }
                }

            }

            performer.releaseAll()
            if let m = tripped.message { error = m }
            Task { @MainActor [error] in
                if self?.token === token { self?.token = nil }
                finished(error)
            }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
    }

    /// How a step is named in messages: its words, or its number.
    static func stepName(_ step: MacroStep, _ index: Int) -> String {
        if case .findImage(let p) = step.action, p.isText, !p.usesPicture, let t = p.text {
            return "“\(t.trimmingCharacters(in: .whitespaces))”"
        }
        return "Step \(index + 1)"
    }

    /// The same spot, give or take a few points (a match that isn't moving).
    static func samePlace(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 4 && abs(a.minY - b.minY) <= 4
    }

    /// An action with its window position resized for a window `s` times the size it was recorded in.
    static func scaled(_ action: StepAction, _ s: Double) -> StepAction { scaled(action, WindowFit(s: s)) }

    static func scaled(_ action: StepAction, _ fit: WindowFit) -> StepAction {
        guard !fit.isSame, let p = action.point else { return action }
        if case .findImage = action { return action }
        var a = action
        a.point = fit.point(p)
        return a
    }

    /// Set once, from the killswitch thread.
    private final class Tripwire: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        var message: String? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Looks for the killswitch a few times a second (words about twice a second) until it shows up or the run ends.
    /// The killswitch as a lookup: its picture and words, or (for “a number reaches”) just its area.
    /// The steps that play: the switched-on ones. A switched-off If takes its whole block with it, and an If
    /// that's on keeps its Otherwise and End whatever their own switches say.
    static func playable(_ all: [MacroStep]) -> [MacroStep] {
        let b = IfBlocks(all.map(\.action))
        var keep = all.map(\.enabled)
        for (i, st) in all.enumerated() where st.enabled {
            if case .ifStart = st.action {
                if let o = b.otherwise[i] { keep[o] = true }
                if let e = b.end[i] { keep[e] = true }
            }
        }
        for (i, st) in all.enumerated() where !st.enabled {
            if case .ifStart = st.action {
                for k in i...(b.end[i] ?? all.count - 1) { keep[k] = false }
            }
        }
        return all.indices.filter { keep[$0] }.map { all[$0] }
    }

    enum CheckResult { case yes, no, unreadable, cancelled, needsTarget }

    /// An If's check: looks at the window for up to `lookFor` seconds (pictures, words, a number, a colour), or
    /// compares the round number.
    static func check(_ c: StepCondition, round: Int, resolver: TargetResolver?, target: TargetOptions,
                      performer: Performer, token: CancelToken) -> CheckResult {
        func flip(_ seen: Bool) -> CheckResult { seen != c.negate ? .yes : .no }
        switch c.kind {
        case .round:
            return c.roundMatches(round) ? .yes : .no
        case .picture, .words:
            guard let resolver else { return .needsTarget }
            guard c.isReady else { return flip(false) } // nothing chosen to look for: it isn't there
            var look = c.look
            look.mode = .stop // only looks, never clicks
            look.timeout = max(0, c.lookFor)
            look.spotOnly = false
            if c.kind == .picture { look.text = nil } else { look.png = Data() }
            switch runPictureStep(look, performer: performer, resolver: resolver, token: token,
                                  reference: target.windowSize, emulator: target.isAndroidEmulator, waitForStill: false) {
            case .cancelled: return .cancelled
            case .unreadable: return .unreadable
            case .matched: return flip(true)
            case .timedOut: return flip(false)
            }
        case .number:
            guard let resolver else { return .needsTarget }
            guard var lookup = Lookup(png: nil, width: 0, height: 0, text: "0", area: c.look.area, strictness: 0.8) else { return .no }
            lookup.reference = c.look.reference(fallback: target.windowSize)
            lookup.emulator = target.isAndroidEmulator
            let deadline = Timing.now() + max(0, c.lookFor)
            var frameNumber = 0, read = false
            while true {
                if token.isCancelled { return .cancelled }
                if let win = resolver.window(), let frame = FrameSource.shared.frame(for: win, after: frameNumber, timeout: 0.3) {
                    frameNumber = frame.number
                    read = true
                    if let v = lookup.largestNumber(in: frame.pixels), v >= c.atLeast { return .yes }
                }
                if Timing.now() >= deadline { return read ? .no : .unreadable }
                guard Timing.wait(until: Timing.now() + 0.25, token) else { return .cancelled }
            }
        case .color:
            guard let hex = c.colorHex else { return flip(false) }
            let cp = target.fit(for: resolver?.window()?.frame.size).point(CGPoint(x: c.colorX, y: c.colorY))
            switch waitForColor(at: performer.route.absolute(Double(cp.x), Double(cp.y)), hex: hex,
                                tolerance: c.tolerance, timeout: max(0, c.lookFor), token: token) {
            case .cancelled: return .cancelled
            case .unreadable: return .unreadable
            case .matched: return flip(true)
            case .timedOut: return flip(false)
            }
        }
    }

    static func killswitchLookup(_ kill: ImageStep, _ opts: PlaybackOptions, _ target: TargetOptions) -> Lookup? {
        guard opts.stopAtNumber != nil else {
            return Lookup(step: kill, reference: target.windowSize, emulator: target.isAndroidEmulator)
        }
        var l = Lookup(png: nil, width: 0, height: 0, text: "0", area: kill.area, strictness: kill.strictness)
        l?.reference = kill.reference(fallback: target.windowSize)
        l?.emulator = target.isAndroidEmulator
        return l
    }

    /// Something happened (a step ran or clicked): resets the “nothing happened for a while” timer.
    final class IdleClock: @unchecked Sendable {
        private let lock = NSLock()
        private var at = Timing.now()
        var last: Double { lock.withLock { at } }
        func touch() { lock.withLock { at = Timing.now() } }
    }

    static func watchKillswitch(_ lookup: Lookup, atLeast: Int? = nil, resolver: TargetResolver, watch: CancelToken,
                                found: () -> Void) {
        var lastText = -Double.infinity
        var frameNumber = 0
        while !watch.isCancelled {
            guard Timing.wait(until: Timing.now() + 0.25, watch) else { return }
            guard let win = resolver.window(),
                  let frame = FrameSource.shared.frame(for: win, after: frameNumber, timeout: 0.2) else { continue }
            let readText = lookup.hasText && Timing.now() - lastText >= 0.5
            if frame.number == frameNumber && !readText { continue }
            frameNumber = frame.number
            if readText { lastText = Timing.now() }
            if let n = atLeast {
                if readText, let v = lookup.largestNumber(in: frame.pixels), v >= n { found(); return }
            } else if lookup.locate(in: frame.pixels, readText: readText) != nil {
                found()
                return
            }
        }
    }

    enum ColorResult { case matched, timedOut, unreadable, cancelled }

    /// Polls the pixel until it matches or `timeout` passes (0 = check once).
    static func waitForColor(at p: CGPoint, hex: String, tolerance: Int, timeout: Double, token: CancelToken) -> ColorResult {
        guard let want = RGB(hex: hex) else { return .matched }
        let deadline = timeout < 0 ? .infinity : Timing.now() + timeout
        while true {
            if token.isCancelled { return .cancelled }
            guard let got = ScreenReader.color(at: p) else { return .unreadable }
            if got.matches(want, tolerance: tolerance) { return .matched }
            if Timing.now() >= deadline { return .timedOut }
            guard Timing.wait(until: Timing.now() + 0.05, token) else { return .cancelled }
        }
    }

    /// "All at once": watch every picture step together and click whichever appears. No order, no timeouts.
    /// Runs until stopped (or for the set duration).
    static func runAllAtOnce(_ steps: [MacroStep], opts: PlaybackOptions, target: TargetOptions, resolver: TargetResolver?,
                             performer: Performer,
                             pauseable: Bool, token: CancelToken, idle: IdleClock = IdleClock(),
                             progress: @escaping @MainActor (Int, Int, Double?) -> Void,
                             waiting: @escaping @MainActor (String?) -> Void,
                             clicked: @escaping @MainActor (UUID, CGRect?) -> Void = { _, _ in },
                             stuck: @escaping @MainActor (ScreenReader.WindowPixels) -> Void = { _ in },
                             counted: @escaping @MainActor (Int) -> Void = { _ in }) -> String? {
        guard let resolver else { return "Picture steps need a target app. Choose one with the Target button." }
        struct Item { let index: Int; let step: ImageStep; let lookup: Lookup }
        let items: [Item] = steps.enumerated().compactMap { i, s in
            guard case .findImage(let p) = s.action, p.mode == .click, !p.spotOnly,
                  let l = Lookup(step: p, reference: target.windowSize, emulator: target.isAndroidEmulator) else { return nil }
            return Item(index: i, step: p, lookup: l)
        }
        // Stop conditions: the chain ends as soon as one of these shows up.
        var stops: [Item] = steps.enumerated().compactMap { i, s in
            guard case .findImage(let p) = s.action, p.mode == .stop,
                  let l = Lookup(step: p, reference: target.windowSize, emulator: target.isAndroidEmulator) else { return nil }
            return Item(index: i, step: p, lookup: l)
        }
        // The killswitch too, checked on every frame before anything is clicked (so it wins over a step that would
        // click on the same screen).
        if let k = opts.stopWhen, let l = killswitchLookup(k, opts, target) { stops.insert(Item(index: -1, step: k, lookup: l), at: 0) }
        guard !items.isEmpty else { return "“All at once” needs at least one picture step set to click." }
        let hasText = items.contains { $0.lookup.hasText } || stops.contains { $0.lookup.hasText }
        var lines: [TextFinder.Line] = []
        var lastTextRead = -Double.infinity
        var textFound: [Int: CGRect?] = [:]

        // What it's watching for, in the live strip: “Claim”, the red picture, or any of 3 steps.
        let watching: String = {
            guard items.count == 1, let only = items.first?.step else { return "any of the \(items.count) steps" }
            if let t = only.text?.trimmingCharacters(in: .whitespaces), !t.isEmpty, !only.usesPicture { return "“\(t)”" }
            return "the " + ActionGroup.pictureNoun(only)
        }()
        Task { @MainActor in waiting(watching) }
        defer { Task { @MainActor in waiting(nil) } }
        let began = Timing.now()
        var chooser = AllAtOnceChooser(rules: Dictionary(uniqueKeysWithValues: items.map {
            ($0.index, AllAtOnceChooser.Rule(settle: $0.step.settle, repeatUntilGone: $0.step.repeatUntilGone,
                                            repeatEvery: $0.step.repeatEvery, settleMax: $0.step.settleMax))
        }), prioritized: opts.prioritized)
        var lastAction = began
        var latest: ScreenReader.WindowPixels?

        var frameNumber = 0
        var found: [Int: CGRect] = [:]
        var still: Set<Int> = []
        var timesHappened = 0
        var lastRoundAt = -Double.infinity
        var clicks = 0
        /// How each clicked step looked just before its click, until it's seen to change.
        var lookAtClick: [Int: [Double]] = [:]
        while !token.isCancelled {
            if opts.maxClicks > 0, clicks >= opts.maxClicks { break }
            let tick = Timing.now()
            guard let win = resolver.window() else { return "The \(resolver.app.name) window went away, so the run stopped." }
            if pauseable, WindowFinder.frontmostPID() != win.pid {
                _ = Timing.wait(until: tick + 0.2, token)
                continue
            }
            // Wait for the next frame of the live feed (arrives as soon as anything on screen changes).
            guard let frame = FrameSource.shared.frame(for: win, after: frameNumber, timeout: 0.1) else {
                return "Couldn't see \(resolver.app.name). Picture steps need Screen Recording permission."
            }
            if frame.number != frameNumber {
                frameNumber = frame.number
                latest = frame.pixels
                let scene = TemplateMatcher.Scene(rgba: frame.pixels.rgba, width: frame.pixels.width, height: frame.pixels.height)
                let size = CGSize(width: frame.pixels.width, height: frame.pixels.height)
                let before = found
                found = [:]
                // Pictures every frame; words from one shared read of the screen, a few times a second
                // (reading text takes far longer than matching a picture).
                let readText = hasText && tick - lastTextRead >= 0.2
                if readText { lines = TextFinder.read(frame.pixels); lastTextRead = tick }
                for it in stops {
                    if it.index < 0, let n = opts.stopAtNumber {
                        if let v = Lookup.largestNumber(in: lines, area: it.lookup.scaledArea(for: size)), v >= n {
                            return Self.done("The number reached \(n)")
                        }
                        continue
                    }
                    var seen = it.lookup.hasPicture && it.lookup.locatePicture(in: frame.pixels, scene: scene) != nil
                    if !seen, let text = it.lookup.text, !text.isEmpty {
                        seen = TextFinder.find(text, in: lines, area: it.lookup.textArea(for: size)) != nil
                    }
                    if seen {
                        let words = it.step.isText ? "“\(it.step.text!.trimmingCharacters(in: .whitespaces))”" : nil
                        let what = it.index < 0 ? (words ?? "The stop picture")
                            : it.step.usesPicture ? "Step \(it.index + 1)'s picture" : words ?? "Step \(it.index + 1)"
                        return Self.done("\(what) appeared")
                    }
                }
                for it in items {
                    // The picture first (fast); then, for text or “Both”, the words.
                    if it.lookup.hasPicture, let r = it.lookup.locatePicture(in: frame.pixels, scene: scene) {
                        found[it.index] = r
                    } else if let text = it.lookup.text, !text.isEmpty {
                        if readText { textFound[it.index] = TextFinder.find(text, in: lines, area: it.lookup.textArea(for: size)) }
                        if let r = textFound[it.index] ?? nil { found[it.index] = it.lookup.pictureFrame(forWords: r) }
                    }
                }
                for (k, before) in lookAtClick {
                    guard let r = found[k] else { lookAtClick[k] = nil; continue }
                    if AllAtOnceChooser.changed(before, AllAtOnceChooser.look(of: r, in: frame.pixels)) {
                        chooser.clickTookEffect(k)
                        lookAtClick[k] = nil
                    }
                }
                // Still: in the same place as in the previous frame (not sliding or animating in).
                still = Set(found.keys.filter { k in before[k].map { Self.samePlace($0, found[k]!) } ?? false })
            } else {
                // Nothing changed on screen since the last look: whatever was found is standing still.
                still = Set(found.keys)
            }
            // One of the steps is on screen (even if it isn't being clicked right now): not stuck.
            if !found.isEmpty { lastAction = tick }
            if let index = chooser.choose(found: found, clickable: opts.waitForStill ? still : nil, now: tick),
               let rect = found[index], let item = items.first(where: { $0.index == index }) {
                let s = item.step
                // Use the chain's delivery setting (e.g. Jump & return) and the window's current position.
                switch RouteBuilder.route(for: target, resolver: resolver) {
                case .success(let r): performer.route = r
                case .failure(let e): return e.message
                }
                performer.route.origin = win.frame.origin
                let target = s.clickSpot(in: rect)
                let x = Double(target.point.x), y = Double(target.point.y)
                performer.spreadBounds = target.bounds
                performer.spreadPicked = target.ownSpread
                performer.perform(.mouseDown(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
                performer.perform(.mouseUp(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
                performer.spreadBounds = nil
                performer.spreadPicked = false
                let firstThisTime = chooser.isFirstClick(index)
                if let px = latest, !s.repeatUntilGone { lookAtClick[index] = AllAtOnceChooser.look(of: rect, in: px) }
                chooser.clicked(index, at: Timing.now())
                idle.touch()
                clicks += 1
                lastAction = Timing.now()
                let id = steps[index].id
                // Reported before the stop check, so the click that reaches the goal is counted too.
                Task { @MainActor in progress(index + 1, 1, nil); clicked(id, rect) }
                // A round: the round step showing up again, past the cooldown (a double press is the same round).
                if firstThisTime, steps[index].id == opts.stopAfterStep, Timing.now() - lastRoundAt >= opts.roundGap {
                    lastRoundAt = Timing.now()
                    timesHappened += 1
                    let n = timesHappened
                    Task { @MainActor in counted(n) }
                    if let limit = opts.roundLimit, timesHappened >= limit {
                        return Self.done("\(limit) run\(limit == 1 ? "" : "s") (\(Self.stepName(steps[index], index)))")
                    }
                }
            } else if opts.idleTapAfter > 0, let ix = opts.idleTapX, let iy = opts.idleTapY,
                      Self.quietFor(since: lastAction) >= opts.idleTapAfter {
                // Nothing known on screen for a while (a “tap to continue” screen, or one never seen before):
                // tap the idle spot, and keep the screen so it can be looked at later.
                switch RouteBuilder.route(for: target, resolver: resolver) {
                case .success(let r): performer.route = r
                case .failure(let e): return e.message
                }
                performer.route.origin = win.frame.origin
                let tp = target.fit(for: win.frame.size).point(CGPoint(x: ix, y: iy))
                performer.perform(.mouseDown(button: .left, x: Double(tp.x), y: Double(tp.y), clickCount: 1, flags: 0))
                performer.perform(.mouseUp(button: .left, x: Double(tp.x), y: Double(tp.y), clickCount: 1, flags: 0))
                lastAction = Timing.now()
                if let screen = latest { Task { @MainActor in stuck(screen) } }
            }
            _ = Timing.wait(until: tick + 1.0 / 30, token) // ~30 checks a second at most
        }
        return nil
    }

    /// How long it's been quiet: no click from Heron since `lastAction`, and no click or key press of your own.
    /// Something you did yourself (tapping past a screen, typing) means it isn't stuck.
    static func quietFor(since lastAction: Double) -> Double {
        let mine = [CGEventType.leftMouseDown, .rightMouseDown, .keyDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
        return min(Timing.now() - lastAction, mine)
    }

    /// Looks for the picture in the target window and acts on it.
    static func runPictureStep(_ s: ImageStep, performer: Performer, resolver: TargetResolver, token: CancelToken,
                               reference: CGSize? = nil, emulator: Bool = false, waitForStill: Bool = true,
                               onFound: (CGRect) -> Void = { _ in }) -> ColorResult {
        guard let lookup = Lookup(step: s, reference: reference, emulator: emulator) else { return .unreadable }
        let deadline = s.timeout < 0 ? .infinity : Timing.now() + s.timeout

        enum Look { case found(CGRect, TargetWindow), missing, unreadable }
        var frameNumber = 0
        var cached: Look = .missing
        var lastLook = 0.0
        var lastTextRead = -Double.infinity
        /// Checks the newest frame of the live feed, waiting briefly for one if nothing changed.
        func look() -> Look {
            // At most ~30 checks a second.
            let interval = lookup.isText ? 0.15 : 1.0 / 30 // reading text is slow; pictures are cheap
            // “Both”: the picture every check, the words a few times a second.
            let readText = lookup.hasText && Timing.now() - lastTextRead >= 0.15
            let since = Timing.now() - lastLook
            if since < interval { _ = Timing.wait(until: lastLook + interval, token) }
            lastLook = Timing.now()
            guard let win = resolver.window(),
                  let frame = FrameSource.shared.frame(for: win, after: frameNumber, timeout: 0.1) else { return .unreadable }
            if frame.number == frameNumber && !(readText && lookup.hasPicture) { return cached }
            frameNumber = frame.number
            if readText { lastTextRead = Timing.now() }
            if let r = lookup.locate(in: frame.pixels, readText: readText) {
                cached = .found(r, win)
            } else if readText || !lookup.hasText {
                cached = .missing
            }
            // Otherwise the words weren't read this time (they're read a few times a second): keep the last answer.
            // Counting such frames as “missing” meant a step with words never saw them still, so never clicked.
            return cached
        }
        func click(_ r: CGRect, _ win: TargetWindow) {
            onFound(r)
            performer.route.origin = win.frame.origin // the window may have moved
            let target = s.clickSpot(in: r)
            let x = Double(target.point.x), y = Double(target.point.y)
            performer.spreadBounds = target.bounds
            performer.spreadPicked = target.ownSpread
            performer.perform(.mouseDown(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
            performer.perform(.mouseUp(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
            performer.spreadBounds = nil
            performer.spreadPicked = false
        }
        func pause(_ seconds: Double) -> Bool { Timing.wait(until: Timing.now() + seconds, token) }

        if s.mode == .stop {
            // Only looks: found means the macro is done.
            while true {
                if token.isCancelled { return .cancelled }
                switch look() {
                case .unreadable: return .unreadable
                case .found: return .matched
                case .missing: break
                }
                if Timing.now() >= deadline { return .timedOut }
            }
        }

        if s.mode == .gone {
            while true {
                if token.isCancelled { return .cancelled }
                switch look() {
                case .unreadable: return .unreadable
                case .missing: return .matched
                case .found: break
                }
                if Timing.now() >= deadline { return .timedOut }
            }
        }

        // Wait for it to appear (and stay for `settle` seconds).
        var seenAt: Double?
        var lastSeen: CGRect?
        var settleWant: Double?
        var spot: (rect: CGRect, win: TargetWindow)?
        while spot == nil {
            if token.isCancelled { return .cancelled }
            switch look() {
            case .unreadable: return .unreadable
            case .missing: seenAt = nil; lastSeen = nil; settleWant = nil
            case .found(let r, let w):
                // Wait until it stops moving: the same place on two checks in a row.
                if waitForStill, !(lastSeen.map { Self.samePlace($0, r) } ?? false) {
                    lastSeen = r
                    seenAt = nil
                    break
                }
                lastSeen = r
                let since = seenAt ?? Timing.now()
                seenAt = since
                let want = settleWant ?? s.pickSettle()
                settleWant = want
                if Timing.now() - since >= want { spot = (r, w); continue }
            }
            if Timing.now() >= deadline {
                // Smart recording: not found, so click where it was when it was recorded.
                if s.mode == .click, let fx0 = s.fallbackX, let fy0 = s.fallbackY {
                    let win = resolver.window()
                    if let win { performer.route.origin = win.frame.origin }
                    let fp = lookup.fit(for: win?.frame.size ?? .zero).point(CGPoint(x: fx0, y: fy0))
                    let fx = Double(fp.x), fy = Double(fp.y)
                    performer.perform(.mouseDown(button: s.button, x: fx, y: fy, clickCount: 1, flags: 0))
                    performer.perform(.mouseUp(button: s.button, x: fx, y: fy, clickCount: 1, flags: 0))
                    return .matched
                }
                return .timedOut
            }
        }
        if s.mode == .appear { return .matched }
        guard let found = spot else { return .timedOut }

        click(found.rect, found.win)
        if s.repeatUntilGone {
            // Up to the step's time limit (at least 3 s), so something that never goes away doesn't hold up the macro.
            let stopAt = s.timeout < 0 ? Double.infinity : Timing.now() + max(3, s.timeout)
            for _ in 0..<200 {
                guard Timing.now() < stopAt else { return .matched }
                guard pause(max(0.1, s.repeatEvery)) else { return .cancelled }
                switch look() {
                case .unreadable: return .unreadable
                case .missing: return .matched
                case .found(let r, let w): click(r, w)
                }
            }
        }
        return .matched
    }

    /// Drops plain mouse moves, folding their delays into the following step so timing is preserved.
    static func removingMoves(_ steps: [MacroStep]) -> [MacroStep] {
        var out: [MacroStep] = []
        var carried = 0.0
        for var s in steps {
            if s.action.isMouseMove { carried += s.delay; continue }
            s.delay += carried
            carried = 0
            out.append(s)
        }
        return out
    }
}

/// Clicks repeatedly on a background thread.
final class AutoClicker {
    private var token: CancelToken?

    var isRunning: Bool { token != nil }

    func start(_ s: AutoClickSettings,
               onClick: @escaping @MainActor (_ clicks: Int, _ skipped: Int) -> Void,
               finished: @escaping @MainActor (_ error: String?) -> Void) {
        stop()
        let token = CancelToken()
        self.token = token

        Thread.detachNewThread { [weak self] in
            let resolver = s.target.app.map { TargetResolver(app: $0) }
            let performer = Performer(route: .screen)
            performer.token = token
            performer.stillThreshold = s.target.jumpWhenStillMs / 1000
            var error: String?
            defer {
                performer.releaseAll()
                Task { @MainActor [error] in
                    if self?.token === token { self?.token = nil }
                    finished(error)
                }
            }
            if s.startDelay > 0 {
                guard Timing.wait(until: Timing.now() + s.startDelay, token) else { return }
            }

            let begin = Timing.now()
            var next = begin
            var count = 0
            var skipped = 0
            var pointIndex = 0
            var lastReport = 0.0
            let usePoints = s.location == .points && !s.points.isEmpty
            let pauseable = s.target.pauseWhenInactive && s.target.app != nil && s.target.delivery != .background

            while !token.isCancelled {
                if s.stopMode == .afterClicks, count >= s.stopClicks { break }
                if s.stopMode == .afterSeconds, Timing.now() - begin >= s.stopSeconds { break }

                switch RouteBuilder.route(for: s.target, resolver: resolver) {
                case .success(let r): performer.route = r
                case .failure(let e): error = e.message; return
                }
                if pauseable, WindowFinder.frontmostPID() != performer.route.pid {
                    guard Timing.wait(until: Timing.now() + 0.1, token) else { break }
                    next = Timing.now()
                    continue
                }

                let x: Double, y: Double, absolute: Bool
                var wanted: String?
                if usePoints {
                    let cp = s.points[pointIndex % s.points.count]
                    (x, y, absolute) = (cp.x, cp.y, false)
                    wanted = cp.color
                    pointIndex += 1
                } else {
                    let c = EventSynth.cursor
                    (x, y, absolute) = (Double(c.x), Double(c.y), true)
                    wanted = s.cursorColor
                }

                // Color check: only click when the pixel at the click point is the wanted color.
                var colorOK = true
                if s.colorCheck, let hex = wanted, let want = RGB(hex: hex) {
                    let p = absolute ? CGPoint(x: x, y: y) : performer.route.absolute(x, y)
                    guard let got = ScreenReader.color(at: p) else {
                        error = "Couldn't read the screen. Color checks need Screen Recording permission (Settings tab)."
                        return
                    }
                    colorOK = got.matches(want, tolerance: s.colorTolerance)
                }

                if colorOK {
                    for c in 1...max(1, s.clicksPerEvent) {
                        performer.perform(.mouseDown(button: s.button, x: x, y: y, clickCount: c, flags: 0), absolute: absolute)
                        if s.holdMs > 0 { Thread.sleep(forTimeInterval: s.holdMs / 1000) }
                        performer.perform(.mouseUp(button: s.button, x: x, y: y, clickCount: c, flags: 0), absolute: absolute)
                    }
                    count += 1
                } else {
                    skipped += 1
                }

                let now = Timing.now()
                if now - lastReport > 0.05 {
                    lastReport = now
                    let n = count, k = skipped
                    Task { @MainActor in onClick(n, k) }
                }

                let jitter = s.jitterMs > 0 ? Double.random(in: -s.jitterMs...s.jitterMs) : 0
                next += max(1, s.intervalMs + jitter) / 1000
                if next < now - 0.25 { next = now } // don't burst-click to catch up after a stall
                guard Timing.wait(until: next, token) else { break }
            }
            let n = count, k = skipped
            Task { @MainActor in onClick(n, k) }
        }
    }

    func stop() {
        token?.cancel()
        token = nil
    }
}

/// Decides which picture to click in "All at once" mode. No priority: whichever has waited longest since its
/// last click goes first, one click per scan (a click usually changes the screen). Each picture is clicked once
/// per appearance, or every `repeatEvery` seconds while showing if it should be clicked until gone.
/// One character of a “Type from a list” item: a key press, or the character itself when no key types it.
enum ListKey { case key(UInt16, shift: Bool), text(String) }

struct AllAtOnceChooser {
    struct Rule {
        var settle: Double; var repeatUntilGone: Bool; var repeatEvery: Double
        /// With a value above `settle`: a random wait between the two, picked each time it appears.
        var settleMax: Double? = nil
    }

    let rules: [Int: Rule]
    /// Higher in the list wins instead of taking turns.
    let prioritized: Bool
    private var seenSince: [Int: Double] = [:]
    private var lastClick: [Int: Double] = [:]
    private var clickedThisAppearance = Set<Int>()
    /// Clicked this appearance and the click visibly did something (the button dimmed, a popup covered it).
    private var tookEffect = Set<Int>()
    private var settleFor: [Int: Double] = [:]

    init(rules: [Int: Rule], prioritized: Bool = false) {
        self.rules = rules
        self.prioritized = prioritized
    }

    /// Without positions: each found step is one appearance until it's gone.
    mutating func choose(found: Set<Int>, now: Double) -> Int? {
        choose(found: Dictionary(uniqueKeysWithValues: found.map { ($0, CGRect.zero) }), now: now)
    }

    /// `found`: where each step is on screen now. `clickable`: the ones ready to click (e.g. standing still);
    /// nil = all found. An appearance lasts until the step has been gone for a moment or turns up somewhere
    /// else, so a frame where it flickers, or reacts to the click, doesn't count as it showing up again.
    mutating func choose(found: [Int: CGRect], clickable: Set<Int>? = nil, now: Double) -> Int? {
        var ready: [Int] = []
        for (index, rule) in rules {
            guard let rect = found[index] else {
                if let seen = lastSeen[index], now - seen < Self.goneAfter { continue }
                seenSince[index] = nil
                settleFor[index] = nil
                lastSeen[index] = nil
                lastRect[index] = nil
                clickedThisAppearance.remove(index)
                tookEffect.remove(index)
                continue
            }
            if let before = lastRect[index], Self.moved(before, rect) {
                // Somewhere else: a new appearance (e.g. the next button in a list).
                seenSince[index] = nil
                settleFor[index] = nil
                clickedThisAppearance.remove(index)
                tookEffect.remove(index)
            }
            lastSeen[index] = now
            lastRect[index] = rect
            let since = seenSince[index] ?? now
            seenSince[index] = since
            let settle = settleFor[index] ?? {
                guard let hi = rule.settleMax, hi > rule.settle else { return rule.settle }
                return Double.random(in: rule.settle...hi)
            }()
            settleFor[index] = settle
            guard clickable?.contains(index) ?? true else { continue }
            guard now - since + 0.01 >= settle else { continue }
            if clickedThisAppearance.contains(index) {
                let since = now - (lastClick[index] ?? 0) + 0.01
                // Clicked once per appearance; but still there, in the same place, a while after the click means the
                // click didn't take (it landed mid-transition, or the app was busy): click it again.
                if rule.repeatUntilGone {
                    guard since >= max(0.1, rule.repeatEvery) else { continue }
                } else {
                    guard !tookEffect.contains(index), since >= Self.retryAfter else { continue }
                }
            }
            ready.append(index)
        }
        if prioritized { return ready.min() }
        return ready.min { (lastClick[$0] ?? -1, $0) < (lastClick[$1] ?? -1, $1) }
    }

    /// A click that leaves its target on screen, unmoved, this long didn't take, and is tried again.
    static let retryAfter = 3.0

    /// Missing for less than this is a flicker, not gone.
    static let goneAfter = 0.4
    private var lastSeen: [Int: Double] = [:]
    private var lastRect: [Int: CGRect] = [:]

    /// Its middle moved by more than half its size.
    static func moved(_ a: CGRect, _ b: CGRect) -> Bool {
        guard a != .zero, b != .zero else { return false }
        return abs(a.midX - b.midX) > max(a.width, b.width) / 2 || abs(a.midY - b.midY) > max(a.height, b.height) / 2
    }

    /// Whether the next click is the first since it appeared (repeat taps on the same appearance aren't).
    func isFirstClick(_ index: Int) -> Bool { !clickedThisAppearance.contains(index) }

    /// The click on `index` changed how it looks (dimmed, covered): it worked, so it isn't tried again while it stays.
    mutating func clickTookEffect(_ index: Int) { tookEffect.insert(index) }

    /// What a spot looks like, coarsely: the average colour of a 6 × 4 grid over it (to tell whether it changed).
    static func look(of r: CGRect, in px: ScreenReader.WindowPixels) -> [Double] {
        let x0 = max(0, Int(r.minX)), y0 = max(0, Int(r.minY))
        let x1 = min(px.width, Int(r.maxX)), y1 = min(px.height, Int(r.maxY))
        guard x1 - x0 >= 6, y1 - y0 >= 4 else { return [] }
        var out: [Double] = []
        for gy in 0..<4 {
            for gx in 0..<6 {
                let cx0 = x0 + (x1 - x0) * gx / 6, cx1 = x0 + (x1 - x0) * (gx + 1) / 6
                let cy0 = y0 + (y1 - y0) * gy / 4, cy1 = y0 + (y1 - y0) * (gy + 1) / 4
                var sum = [0.0, 0, 0], n = 0.0
                for y in stride(from: cy0, to: cy1, by: 2) {
                    for x in stride(from: cx0, to: cx1, by: 2) {
                        let i = (y * px.width + x) * 4
                        sum[0] += Double(px.rgba[i]); sum[1] += Double(px.rgba[i + 1]); sum[2] += Double(px.rgba[i + 2]); n += 1
                    }
                }
                out += sum.map { $0 / max(n, 1) }
            }
        }
        return out
    }

    /// Whether two looks of the same spot differ clearly (more than a subtle shimmer).
    static func changed(_ a: [Double], _ b: [Double]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        return zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count) > 18
    }

    mutating func clicked(_ index: Int, at time: Double) {
        lastClick[index] = time
        clickedThisAppearance.insert(index)
    }
}
