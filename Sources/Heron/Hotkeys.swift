import AppKit
import Carbon.HIToolbox

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask

    var display: String { CarbonMods.symbols(modifiers) + KeyNames.name(for: UInt16(keyCode)) }

    /// Shortcuts every Mac app relies on (Quit, Copy, Paste, screenshots…). Taking them globally would break them everywhere.
    var isReserved: Bool {
        let cmd = CarbonMods.cmd, cmdShift = CarbonMods.cmd | CarbonMods.shift
        let cmdOnly: Set<Int> = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A,
                                 kVK_ANSI_S, kVK_ANSI_H, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_T,
                                 kVK_ANSI_F, kVK_ANSI_Comma, kVK_Tab, kVK_Space, kVK_ANSI_Grave]
        if modifiers == cmd && cmdOnly.contains(Int(keyCode)) { return true }
        if modifiers == cmdShift && [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_Z].contains(Int(keyCode)) { return true }
        if modifiers == CarbonMods.control && Int(keyCode) == kVK_Space { return true }
        return false
    }

    func matches(keyCode code: UInt16, flags: CGEventFlags) -> Bool {
        UInt32(code) == keyCode && CarbonMods.from(flags) == modifiers
    }
}

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case toggleAutoClick, toggleRecording, togglePlayback, stopAll, capturePoint, toggleWatchers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleAutoClick: "Start / stop auto clicker"
        case .toggleRecording: "Start / stop recording"
        case .togglePlayback: "Play / stop selected macro"
        case .stopAll: "Stop everything (panic)"
        case .capturePoint: "Add a spot at the pointer"
        case .toggleWatchers: "Start / stop background macros"
        }
    }

    var defaultHotkey: Hotkey {
        let ctrlOpt = CarbonMods.control | CarbonMods.option
        switch self {
        case .toggleAutoClick: return Hotkey(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt)
        case .toggleRecording: return Hotkey(keyCode: UInt32(kVK_ANSI_R), modifiers: ctrlOpt)
        case .togglePlayback: return Hotkey(keyCode: UInt32(kVK_ANSI_P), modifiers: ctrlOpt)
        case .stopAll: return Hotkey(keyCode: UInt32(kVK_ANSI_X), modifiers: ctrlOpt)
        case .capturePoint: return Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrlOpt)
        case .toggleWatchers: return Hotkey(keyCode: UInt32(kVK_ANSI_W), modifiers: ctrlOpt)
        }
    }

    static var defaults: [HotkeyAction: Hotkey] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultHotkey) })
    }
}

/// Global hotkeys via Carbon's RegisterEventHotKey (works without any permissions).
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let id = hkID.id
            DispatchQueue.main.async { HotkeyManager.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(_ bindings: [(Hotkey, () -> Void)]) {
        installHandlerIfNeeded()
        unregisterAll()
        for (i, (hk, handler)) in bindings.enumerated() {
            let id = UInt32(i + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, EventHotKeyID(signature: 0x4D434C4B, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = handler
            }
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        handlers = [:]
    }
}
