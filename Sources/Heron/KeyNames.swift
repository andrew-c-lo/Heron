import AppKit
import CoreGraphics

enum KeyNames {
    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return", 37: "L",
        38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M",
        47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Esc",
        54: "Right ⌘", 55: "⌘", 56: "⇧", 57: "Caps Lock", 58: "⌥", 59: "⌃",
        60: "Right ⇧", 61: "Right ⌥", 62: "Right ⌃", 63: "fn",
        65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
        76: "Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
        84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
        89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Fwd Delete", 119: "End", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static let functionKeyCodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

    static func name(for code: UInt16) -> String { names[code] ?? "Key \(code)" }

    static func modifierSymbols(cgFlags raw: UInt64) -> String {
        let f = CGEventFlags(rawValue: raw)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s
    }
}

// MARK: - Carbon modifier helpers

enum CarbonMods {
    static let cmd: UInt32 = 1 << 8      // cmdKey
    static let shift: UInt32 = 1 << 9    // shiftKey
    static let option: UInt32 = 1 << 11  // optionKey
    static let control: UInt32 = 1 << 12 // controlKey

    static func from(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= cmd }
        if f.contains(.shift) { m |= shift }
        if f.contains(.option) { m |= option }
        if f.contains(.control) { m |= control }
        return m
    }

    static func from(_ f: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.maskCommand) { m |= cmd }
        if f.contains(.maskShift) { m |= shift }
        if f.contains(.maskAlternate) { m |= option }
        if f.contains(.maskControl) { m |= control }
        return m
    }

    static func symbols(_ m: UInt32) -> String {
        var s = ""
        if m & control != 0 { s += "⌃" }
        if m & option != 0 { s += "⌥" }
        if m & shift != 0 { s += "⇧" }
        if m & cmd != 0 { s += "⌘" }
        return s
    }
}
