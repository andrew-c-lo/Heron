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
            return .failure(RouteError(message: "Can't find a window for \(resolver.app.name). Is it open?"))
        }
        return .success(Route(mode: target.delivery, pid: w.pid, windowNumber: w.windowNumber, origin: w.frame.origin))
    }
}

/// Replays a macro on a background thread.
final class Player {
    private var token: CancelToken?

    var isRunning: Bool { token != nil }

    func play(_ macro: Macro,
              startDelay: Double = 0,
              progress: @escaping @MainActor (_ step: Int, _ loop: Int, _ pausing: Double?) -> Void,
              waiting: @escaping @MainActor (_ color: String?) -> Void = { _ in },
              finished: @escaping @MainActor (_ error: String?) -> Void) {
        stop()
        let token = CancelToken()
        self.token = token
        let opts = macro.playback
        let target = macro.target
        // Switched-off steps are skipped entirely (their waits too).
        let enabledSteps = macro.steps.filter(\.enabled)
        let steps = opts.skipMouseMoves ? Self.removingMoves(enabledSteps) : enabledSteps
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

        Thread.detachNewThread { [weak self] in
            let resolver = target.app.map { TargetResolver(app: $0) }
            let performer = Performer(route: .screen)
            performer.token = token
            performer.stillThreshold = target.jumpWhenStillMs / 1000
            let pauseable = target.pauseWhenInactive && target.app != nil && target.delivery != .background
            var error: String?
            var lastReport = 0.0
            var loop = 0
            let began = Timing.now()

            if opts.order == .allAtOnce {
                error = Self.runAllAtOnce(steps, opts: opts, target: target, resolver: resolver, performer: performer,
                                          pauseable: pauseable, token: token, progress: progress, waiting: waiting)
            } else {
                outer: while true {
                    if let n = opts.loopCount, loop >= n { break }
                    if opts.repeatMode == .duration, loop > 0, Timing.now() - began >= opts.repeatDuration { break }

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
                    var skipUntil = -1
                    for (i, step) in steps.enumerated() {
                        if i < skipUntil { continue }
                        t += delays[i] / speed
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
                        if case .findImage(let pic) = step.action {
                            guard let resolver else {
                                error = "Picture steps need a target app. Choose one with the Target button."
                                break outer
                            }
                            if pic.text != nil && !pic.isText {
                                error = "Step \(i + 1) has no text to look for. Type it in the step's settings."
                                break outer
                            }
                            let looking = pic.isText ? "“\(pic.text!.trimmingCharacters(in: .whitespaces))”" : "the picture"
                            Task { @MainActor in waiting(looking) }
                            let result = Self.runPictureStep(pic, performer: performer, resolver: resolver, token: token)
                            Task { @MainActor in waiting(nil) }
                            switch result {
                            case .cancelled: break outer
                            case .unreadable:
                                error = "Couldn't see \(resolver.app.name). Picture steps need Screen Recording permission."
                                break outer
                            case .matched: break
                            case .timedOut:
                                switch pic.otherwise {
                                case .continueAnyway: break
                                case .skipNext: skipUntil = nextActionEnd[i]
                                case .nextLoop: t = Timing.now(); loop += 1; continue outer
                                case .stopMacro:
                                    error = "Stopped: step \(i + 1)'s \(pic.text != nil ? "text" : "picture") didn't \(pic.mode == .gone ? "go away" : "appear") in time."
                                    break outer
                                }
                            }
                            t = Timing.now()
                        } else if case .waitForColor(let x, let y, let hex, let tol, let timeout, let otherwise, _) = step.action {
                            Task { @MainActor in waiting(hex) }
                            let result = Self.waitForColor(at: performer.route.absolute(x, y), hex: hex, tolerance: tol,
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
                                case .stopMacro:
                                    error = "Stopped: \(hex) didn't appear at (\(Int(x)), \(Int(y)))."
                                    break outer
                                }
                            }
                            t = Timing.now() // waiting shifts the rest of the schedule
                        } else {
                            t += performer.perform(step.action)
                        }

                        let now = Timing.now()
                        if now - lastReport > 0.05 || i == steps.count - 1 {
                            lastReport = now
                            let s = i + 1, l = loop + 1
                            Task { @MainActor in progress(s, l, nil) }
                        }
                    }
                    loop += 1
                }

            }

            performer.releaseAll()
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
                             pauseable: Bool, token: CancelToken,
                             progress: @escaping @MainActor (Int, Int, Double?) -> Void,
                             waiting: @escaping @MainActor (String?) -> Void) -> String? {
        guard let resolver else { return "Picture steps need a target app. Choose one with the Target button." }
        struct Item { let index: Int; let step: ImageStep; let lookup: Lookup }
        let items: [Item] = steps.enumerated().compactMap { i, s in
            guard case .findImage(let p) = s.action, p.mode == .click, let l = Lookup(step: p) else { return nil }
            return Item(index: i, step: p, lookup: l)
        }
        guard !items.isEmpty else { return "“All at once” needs at least one picture step set to click." }

        Task { @MainActor in waiting("any of the pictures") }
        defer { Task { @MainActor in waiting(nil) } }
        let began = Timing.now()
        var chooser = AllAtOnceChooser(rules: Dictionary(uniqueKeysWithValues: items.map {
            ($0.index, AllAtOnceChooser.Rule(settle: $0.step.settle, repeatUntilGone: $0.step.repeatUntilGone,
                                            repeatEvery: $0.step.repeatEvery))
        }))

        var frameNumber = 0
        var found: [Int: CGRect] = [:]
        while !token.isCancelled {
            if opts.repeatMode == .duration, Timing.now() - began >= opts.repeatDuration { break }
            let tick = Timing.now()
            guard let win = resolver.window() else { return "Can't find \(resolver.app.name)'s window." }
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
                let scene = TemplateMatcher.Scene(rgba: frame.pixels.rgba, width: frame.pixels.width, height: frame.pixels.height)
                found = [:]
                for it in items {
                    if let r = it.lookup.locate(in: frame.pixels, scene: scene) { found[it.index] = r }
                }
            }
            if let index = chooser.choose(found: Set(found.keys), now: tick),
               let rect = found[index], let item = items.first(where: { $0.index == index }) {
                let s = item.step
                // Use the chain's delivery setting (e.g. Jump & return) and the window's current position.
                switch RouteBuilder.route(for: target, resolver: resolver) {
                case .success(let r): performer.route = r
                case .failure(let e): return e.message
                }
                performer.route.origin = win.frame.origin
                let x = Double(rect.midX) + s.offsetX, y = Double(rect.midY) + s.offsetY
                performer.spreadBounds = rect.offsetBy(dx: s.offsetX, dy: s.offsetY)
                performer.perform(.mouseDown(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
                performer.perform(.mouseUp(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
                performer.spreadBounds = nil
                chooser.clicked(index, at: Timing.now())
                Task { @MainActor in progress(index + 1, 1, nil) }
            }
            _ = Timing.wait(until: tick + 1.0 / 30, token) // ~30 checks a second at most
        }
        return nil
    }

    /// Looks for the picture in the target window and acts on it.
    static func runPictureStep(_ s: ImageStep, performer: Performer, resolver: TargetResolver, token: CancelToken) -> ColorResult {
        guard let lookup = Lookup(step: s) else { return .unreadable }
        let deadline = s.timeout < 0 ? .infinity : Timing.now() + s.timeout

        enum Look { case found(CGRect, TargetWindow), missing, unreadable }
        var frameNumber = 0
        var cached: Look = .missing
        var lastLook = 0.0
        /// Checks the newest frame of the live feed, waiting briefly for one if nothing changed.
        func look() -> Look {
            // At most ~30 checks a second.
            let since = Timing.now() - lastLook
            if since < 1.0 / 30 { _ = Timing.wait(until: lastLook + 1.0 / 30, token) }
            lastLook = Timing.now()
            guard let win = resolver.window(),
                  let frame = FrameSource.shared.frame(for: win, after: frameNumber, timeout: 0.1) else { return .unreadable }
            if frame.number == frameNumber { return cached }
            frameNumber = frame.number
            if let r = lookup.locate(in: frame.pixels) {
                cached = .found(r, win)
            } else {
                cached = .missing
            }
            return cached
        }
        func click(_ r: CGRect, _ win: TargetWindow) {
            performer.route.origin = win.frame.origin // the window may have moved
            let x = Double(r.midX) + s.offsetX, y = Double(r.midY) + s.offsetY
            performer.spreadBounds = r.offsetBy(dx: s.offsetX, dy: s.offsetY)
            performer.perform(.mouseDown(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
            performer.perform(.mouseUp(button: s.button, x: x, y: y, clickCount: 1, flags: 0))
            performer.spreadBounds = nil
        }
        func pause(_ seconds: Double) -> Bool { Timing.wait(until: Timing.now() + seconds, token) }

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
        var spot: (rect: CGRect, win: TargetWindow)?
        while spot == nil {
            if token.isCancelled { return .cancelled }
            switch look() {
            case .unreadable: return .unreadable
            case .missing: seenAt = nil
            case .found(let r, let w):
                let since = seenAt ?? Timing.now()
                seenAt = since
                if Timing.now() - since >= s.settle { spot = (r, w); continue }
            }
            if Timing.now() >= deadline { return .timedOut }
        }
        if s.mode == .appear { return .matched }
        guard let found = spot else { return .timedOut }

        click(found.rect, found.win)
        if s.repeatUntilGone {
            for _ in 0..<200 {
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
struct AllAtOnceChooser {
    struct Rule { var settle: Double; var repeatUntilGone: Bool; var repeatEvery: Double }

    let rules: [Int: Rule]
    private var seenSince: [Int: Double] = [:]
    private var lastClick: [Int: Double] = [:]
    private var clickedThisAppearance = Set<Int>()

    init(rules: [Int: Rule]) { self.rules = rules }

    mutating func choose(found: Set<Int>, now: Double) -> Int? {
        var ready: [Int] = []
        for (index, rule) in rules {
            guard found.contains(index) else {
                seenSince[index] = nil
                clickedThisAppearance.remove(index)
                continue
            }
            let since = seenSince[index] ?? now
            seenSince[index] = since
            guard now - since + 0.01 >= rule.settle else { continue }
            if clickedThisAppearance.contains(index) {
                guard rule.repeatUntilGone, now - (lastClick[index] ?? 0) + 0.01 >= max(0.1, rule.repeatEvery) else { continue }
            }
            ready.append(index)
        }
        return ready.min { (lastClick[$0] ?? -1, $0) < (lastClick[$1] ?? -1, $1) }
    }

    mutating func clicked(_ index: Int, at time: Double) {
        lastClick[index] = time
        clickedThisAppearance.insert(index)
    }
}
