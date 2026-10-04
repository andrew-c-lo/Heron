import AppKit
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

/// The Mac-side pieces scheduled runs need.
enum SystemState {
    /// Clicks can't reach apps behind the lock screen.
    static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Wakes the display (as if the mouse moved) so a run can see the screen.
    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Heron scheduled run" as CFString, kIOPMUserActiveLocal, &id)
    }

    /// Opening at login (so schedules work after a restart).
    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func setOpensAtLogin(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "Couldn't change Open at Login: \(error.localizedDescription)"
        }
    }
}

/// Keeps the Mac (and, when asked, the screen) from going to sleep on its own.
final class StayAwake {
    private var system: IOPMAssertionID?
    private var display: IOPMAssertionID?

    /// `mac`: no idle sleep. `screen`: the display stays on too, so the screen saver and auto-lock don't start.
    func set(mac: Bool, screen: Bool) {
        Self.hold(&system, mac || screen, kIOPMAssertionTypePreventUserIdleSystemSleep, "Heron is keeping the Mac awake for a macro")
        Self.hold(&display, screen, kIOPMAssertionTypePreventUserIdleDisplaySleep, "Heron is running a macro")
    }

    private static func hold(_ id: inout IOPMAssertionID?, _ on: Bool, _ type: String, _ reason: String) {
        if on, id == nil {
            var a: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason as CFString, &a) == kIOReturnSuccess {
                id = a
            }
        } else if !on, let a = id {
            IOPMAssertionRelease(a)
            id = nil
        }
    }
}
