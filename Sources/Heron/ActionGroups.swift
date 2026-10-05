import AppKit
import Carbon.HIToolbox

/// A human-level action ("Tap", "Swipe up", "Type “hi”") made of one or more raw steps.
struct ActionGroup: Identifiable {
    enum Kind {
        case click(button: MouseButton, count: Int, at: CGPoint?, hold: Double)
        case typeList(TypeList)
        case drag(button: MouseButton, from: CGPoint, to: CGPoint)
        case scroll(dx: Double, dy: Double, at: CGPoint?)
        case keys(String)
        case wait
        case colorWait(at: CGPoint, ColorWait)
        case image(ImageStep)
        case repeatFrom(target: UUID, times: Int)
        case ifStart(StepCondition)
        case otherwise
        case endIf
        case runMacro(UUID)
        case move(to: CGPoint)
        case other(String, icon: String)

        var isOtherwise: Bool { if case .otherwise = self { true } else { false } }
        var isIf: Bool { if case .ifStart = self { true } else { false } }
    }

    /// Macro names by id, for “Run “…”” titles (kept up to date by the app).
    nonisolated(unsafe) static var macroNames: [UUID: String] = [:]

    /// If, Otherwise and End: rows that shape the list rather than doing something.
    var isBlockMarker: Bool {
        switch kind {
        case .ifStart, .otherwise, .endIf: true
        default: false
        }
    }

    /// Id of the first raw step.
    let id: UUID
    /// Indices into `macro.steps`.
    let range: Range<Int>
    /// Steps whose delays make up the wait before the action: cursor travel plus the first real step.
    let lead: ClosedRange<Int>
    /// Seconds before the action happens (at 1× speed).
    let wait: Double
    /// Seconds from the start of the macro until the action happens.
    let start: Double
    let kind: Kind
    /// Off = skipped when the macro plays.
    var enabled = true
    /// The name given to its step, if any.
    var name: String? = nil

    /// Index of the first non-travel step.
    var actionIndex: Int { lead.upperBound }

    // MARK: Presentation (touch = target is a phone, so say "tap"/"swipe")

    /// “picture”, “"OK" picture” when words were read from inside it, or “red picture” when it has none.
    static func pictureNoun(_ s: ImageStep) -> String { s.pictureNoun }

    /// The step's name if it has one, otherwise what it does.
    func title(touch: Bool) -> String {
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return n }
        return actionTitle(touch: touch)
    }

    /// What the step does (“Tap the picture until it's gone”), whatever it's called.
    func actionTitle(touch: Bool) -> String {
        switch kind {
        case .click(let b, let count, let at, let hold):
            var s: String
            if b == .left && count == 1 && hold >= 0.5 {
                s = (touch ? "Long press" : "Click and hold") + String(format: " (%.1fs)", hold)
            } else {
                let base = b == .left ? (touch ? "tap" : "click") : "\(b.label.lowercased())-click"
                let prefix = count == 2 ? "double-" : count >= 3 ? "triple-" : ""
                s = prefix + base
                s = s.prefix(1).uppercased() + s.dropFirst()
            }
            if at == nil { s += " at the cursor" }
            return s
        case .drag(_, let from, let to):
            return (touch ? "Swipe " : "Drag ") + Self.direction(from, to)
        case .scroll(let dx, let dy, _):
            if abs(dy) >= abs(dx) { return "Scroll \(dy > 0 ? "up" : "down") \(Int(abs(dy)))px" }
            return "Scroll \(dx > 0 ? "left" : "right") \(Int(abs(dx)))px"
        case .keys(let s): return s
        case .wait: return "Pause"
        case .colorWait(_, let c):
            return "Wait for \(c.hex)"
        case .image(let s) where s.spotOnly && s.mode == .click && s.spot != nil:
            let p = s.spot!
            return (touch ? "Tap" : "Click") + " the spot \(Int(p.x)), \(Int(p.y))"
        case .image(let s):
            if s.text != nil {
                let words = s.isText ? "“\(s.text!.trimmingCharacters(in: .whitespaces))”" : "some words"
                let t = s.usesPicture ? "the \(Self.pictureNoun(s)) or " + words : words
                switch s.mode {
                case .click: return (touch ? "Tap " : "Click ") + t + (s.repeatUntilGone ? " until it's gone" : "")
                case .appear: return "Wait for " + t
                case .gone: return "Wait until " + t + " is gone"
                case .stop: return "Stop when " + t + " appears"
                }
            }
            switch s.mode {
            case .click: return (touch ? "Tap" : "Click") + " the \(Self.pictureNoun(s))" + (s.repeatUntilGone ? " until it's gone" : "")
            case .appear: return "Wait for the \(Self.pictureNoun(s))"
            case .gone: return "Wait until the \(Self.pictureNoun(s)) is gone"
            case .stop: return "Stop when the \(Self.pictureNoun(s)) appears"
            }
        case .typeList(let l):
            let n = l.entries.count
            return n == 0 ? "Type from a list" : "Type the next of \(n) item\(n == 1 ? "" : "s")" + (l.pressReturn ? ", then Return" : "")
        case .move: return "Move the mouse"
        case .repeatFrom(_, let n): return "Repeat from an earlier step, \(n)×"
        case .ifStart(let c): return "If " + c.summary
        case .otherwise: return "Otherwise"
        case .endIf: return "End of if"
        case .runMacro(let id):
            return Self.macroNames[id].map { "Run “\($0)”" } ?? "Run a macro that was deleted"
        case .other(let s, _): return s
        }
    }

    var detail: String? {
        switch kind {
        case .drag(_, let from, let to): "\(Self.fmt(from)) → \(Self.fmt(to))"
        case .scroll(_, _, let at?): "at \(Self.fmt(at))"
        case .typeList(let l):
            l.entries.isEmpty ? "add items in its settings"
                : l.next >= l.entries.count ? "all \(l.entries.count) typed" + (l.whenDone == .startOver ? "; starts over next" : "")
                : "next: item \(l.next + 1) of \(l.entries.count)"
        case .image(let s) where s.spotOnly && s.mode == .click:
            s.spot == nil ? "set to a spot: pick where to click" : "fixed spot, no looking · picture and words kept"
        case .image(let s) where s.mode == .stop:
            (s.untilAppears ? "keeps looking until it does" : "looks for \(s.timeout.formatted())s, then carries on")
                + (!s.usesPicture ? "" : " · \(Int((s.strictness * 100).rounded()))% match")
                + (s.area == nil ? "" : " · in an area")
        case .image(let s):
            (s.untilAppears ? (s.mode == .gone ? "no time limit" : "whenever it appears")
                            : "up to \(s.timeout.formatted())s, else "
                                + (s.fallbackX != nil ? "clicks where it was recorded" : s.otherwise.label.lowercased()))
                + (!s.usesPicture ? "" : " · \(Int((s.strictness * 100).rounded()))% match")
                + (s.area == nil ? "" : " · in an area")
        case .colorWait(let at, let c):
            "at \(Self.fmt(at))"
                + (c.untilAppears ? ", until it appears" : c.timeout > 0 ? ", up to \(c.timeout.formatted())s" : ", check once")
                + (c.immediate ? ", ignores timing" : "")
                + (c.untilAppears || c.otherwise == .continueAnyway ? "" : ". If not: \(c.otherwise.label.lowercased())")
        case .move(let to): "to \(Self.fmt(to))"
        case .ifStart(let c):
            !c.isReady ? "pick what to check in its settings"
                : c.kind == .round ? nil
                : c.lookFor > 0 ? "looks for up to \(c.lookFor.formatted())s" : "one look"
        case .runMacro: "its steps run here once, in this macro's app"
        default: nil
        }
    }

    func icon(touch: Bool) -> String {
        switch kind {
        case .click(let b, let count, _, let hold):
            if b == .left && count == 1 && hold >= 0.5 { return "hand.point.up.left" }
            if count >= 2 { return "cursorarrow.click.2" }
            return touch && b == .left ? "hand.tap" : "cursorarrow.click"
        case .drag(_, let from, let to): return "arrow." + Self.direction(from, to)
        case .scroll: return "scroll"
        case .keys: return "keyboard"
        case .wait: return "clock"
        case .colorWait: return "eyedropper"
        case .image(let s):
            if s.spotOnly && s.mode == .click { return "cursorarrow.click" }
            return s.isText && s.mode == .click ? "text.viewfinder" : s.mode.icon
        case .typeList: return "list.bullet.rectangle"
        case .repeatFrom: return "arrow.uturn.backward"
        case .ifStart: return "arrow.triangle.branch"
        case .otherwise: return "arrow.turn.down.right"
        case .endIf: return "arrow.turn.left.down"
        case .runMacro: return "play.rectangle"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .other(_, let icon): return icon
        }
    }

    /// Position that can be edited directly in the simple view (single-spot clicks only).
    var editablePoint: CGPoint? {
        switch kind {
        case .click(_, _, let at?, _), .colorWait(let at, _): return at
        default: return nil
        }
    }

    private static func direction(_ a: CGPoint, _ b: CGPoint) -> String {
        let dx = b.x - a.x, dy = b.y - a.y
        if abs(dy) >= abs(dx) { return dy < 0 ? "up" : "down" }
        return dx < 0 ? "left" : "right"
    }

    private static func fmt(_ p: CGPoint) -> String { "(\(Int(p.x)), \(Int(p.y)))" }
}

enum ActionGrouper {
    /// Steps as people count them: an If counts once; its Otherwise and End rows don't.
    static func stepCount(_ steps: [MacroStep]) -> Int {
        groups(for: steps).filter { !$0.isBlockMarker || $0.kind.isIf }.count
    }

    private static let clickTolerance: CGFloat = 8
    private static let scrollGap = 0.6
    private static let keyGap = 1.0

    static func groups(for steps: [MacroStep]) -> [ActionGroup] {
        var out: [ActionGroup] = []
        var clock = 0.0
        var i = 0
        let n = steps.count

        while i < n {
            let start = i
            var first = i
            while first < n, steps[first].action.isMouseMove { first += 1 }

            if first == n { // only cursor travel left
                let wait = steps[start..<n].reduce(0) { $0 + $1.delay }
                out.append(ActionGroup(id: steps[start].id, range: start..<n, lead: start...(n - 1), wait: wait,
                                       start: clock + wait, kind: .move(to: steps[n - 1].action.point ?? .zero)))
                break
            }

            let wait = steps[start...first].reduce(0) { $0 + $1.delay }
            var end = first + 1
            let kind: ActionGroup.Kind

            switch steps[first].action {
            case .mouseDown(let b, let x, let y, let c, _):
                let down = CGPoint(x: x, y: y)
                let press = scanPress(steps, from: first, button: b)
                end = press.end
                if press.wander <= clickTolerance && dist(press.up, down) <= clickTolerance {
                    var count = c, hold = press.hold
                    // Fold the follow-up presses of a double/triple click into one action
                    // (allowing for small cursor jiggle between presses).
                    while true {
                        var probe = end, gap = 0.0
                        while probe < n, steps[probe].action.isMouseMove { gap += steps[probe].delay; probe += 1 }
                        guard probe < n, case .mouseDown(let b2, let x2, let y2, let c2, _) = steps[probe].action,
                              b2 == b, c2 > count, gap + steps[probe].delay < 0.6,
                              dist(CGPoint(x: x2, y: y2), down) <= clickTolerance else { break }
                        let next = scanPress(steps, from: probe, button: b)
                        guard next.wander <= clickTolerance else { break }
                        count = c2
                        hold = 0
                        end = next.end
                    }
                    kind = .click(button: b, count: count, at: down, hold: hold)
                } else {
                    kind = .drag(button: b, from: down, to: press.up)
                }
            case .click(let b, let x, let y, let count):
                let at = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
                kind = .click(button: b, count: count, at: at, hold: 0)
            case .scroll(var dx, var dy, let x, let y):
                while end < n, case .scroll(let dx2, let dy2, _, _) = steps[end].action, steps[end].delay < scrollGap {
                    dx += dx2; dy += dy2; end += 1
                }
                kind = .scroll(dx: dx, dy: dy, at: (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil)
            case .key, .flags:
                // Keystrokes close together read as one action ("Type “hello”").
                while end < n, steps[end].delay < keyGap, isKeyboard(steps[end].action) { end += 1 }
                kind = .keys(describeKeys(steps[first..<end]))
            case .wait:
                kind = .wait
            case .waitForColor(let x, let y, _, _, _, _, _):
                kind = .colorWait(at: CGPoint(x: x, y: y), steps[first].action.colorWait!)
            case .findImage(let s):
                kind = .image(s)
            case .repeatFrom(let target, let times):
                kind = .repeatFrom(target: target, times: times)
            case .ifStart(let c):
                kind = .ifStart(c)
            case .otherwise:
                kind = .otherwise
            case .endIf:
                kind = .endIf
            case .runMacro(let id):
                kind = .runMacro(id)
            case .typeList(let l):
                kind = .typeList(l)
            case .mouseUp(let b, _, _, _, _):
                kind = .other("Release the \(b.label.lowercased()) button", icon: "arrow.up.circle")
            case .drag(let b, _, _):
                while end < n, case .drag = steps[end].action { end += 1 }
                kind = .other("\(b.label) drag (press wasn't recorded)", icon: "hand.draw")
            case .move:
                kind = .other("Move", icon: "arrow.up.and.down.and.arrow.left.and.right")
            }

            out.append(ActionGroup(id: steps[start].id, range: start..<end, lead: start...first, wait: wait,
                                   start: clock + wait, kind: kind, enabled: steps[first].enabled, name: steps[first].name))
            clock += steps[start..<end].reduce(0) { $0 + $1.delay }
            i = end
        }
        return out
    }

    /// Follows a press to its release: where it ended, how far it wandered, how long it was held.
    private static func scanPress(_ steps: [MacroStep], from downIndex: Int, button: MouseButton)
        -> (end: Int, up: CGPoint, wander: CGFloat, hold: Double) {
        let down = steps[downIndex].action.point ?? .zero
        var last = down, wander: CGFloat = 0, hold = 0.0
        var k = downIndex + 1
        while k < steps.count {
            let s = steps[k]
            hold += s.delay
            if let p = s.action.point {
                last = p
                wander = max(wander, dist(p, down))
            }
            if case .mouseUp(let b, _, _, _, _) = s.action, b == button { return (k + 1, last, wander, hold) }
            k += 1
        }
        return (steps.count, last, wander, hold)
    }

    private static func isKeyboard(_ a: StepAction) -> Bool {
        switch a {
        case .key, .flags: true
        default: false
        }
    }

    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// "Type “hello”, then press ⌘S"
    static func describeKeys(_ steps: ArraySlice<MacroStep>) -> String {
        enum Part { case typed(String), press([String]) }
        var parts: [Part] = []
        for s in steps {
            guard case .key(let code, true, let f) = s.action else { continue }
            let flags = CGEventFlags(rawValue: f)
            let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
            if !shortcut, let ch = KeyText.character(for: code, shift: flags.contains(.maskShift)) {
                if case .typed(let t)? = parts.last { parts[parts.count - 1] = .typed(t + ch) } else { parts.append(.typed(ch)) }
            } else {
                let name = KeyNames.modifierSymbols(cgFlags: f) + KeyNames.name(for: code)
                if case .press(let p)? = parts.last { parts[parts.count - 1] = .press(p + [name]) } else { parts.append(.press([name])) }
            }
        }
        if parts.isEmpty { return "Modifier keys" }
        let text = parts.map { part -> String in
            switch part {
            case .typed(let t): "type “\(t)”"
            case .press(let names): "press " + names.joined(separator: ", ")
            }
        }.joined(separator: ", then ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// What a key produces on the user's current keyboard layout.
enum KeyText {
    private static var cache: [UInt32: String?] = [:]

    /// The printable character for a key, or nil for non-printing keys (Return, arrows, F-keys…).
    static func character(for code: UInt16, shift: Bool) -> String? {
        let key = UInt32(code) | (shift ? 0x1_0000 : 0)
        if let cached = cache[key] { return cached }
        let result = translate(code, shift: shift)
        cache[key] = result
        return result
    }

    /// The key (and whether Shift is needed) that types `ch` on the current layout, if any.
    static func key(for ch: Character) -> (code: UInt16, shift: Bool)? {
        let target = String(ch)
        for shift in [false, true] {
            for code in UInt16(0)..<128 where character(for: code, shift: shift) == target { return (code, shift) }
        }
        return nil
    }

    private static func translate(_ code: UInt16, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let mods: UInt32 = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        let printable = s.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && $0.value != 0x7F }
        return printable ? s : nil
    }
}
