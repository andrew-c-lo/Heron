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

/// Keeps the Mac from going to sleep on its own while a schedule is waiting (the display can still turn off).
final class StayAwake {
    private var id: IOPMAssertionID?

    func set(_ on: Bool) {
        if on, id == nil {
            var a: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Heron is waiting for a scheduled macro" as CFString, &a) == kIOReturnSuccess {
                id = a
            }
        } else if !on, let a = id {
            IOPMAssertionRelease(a)
            id = nil
        }
    }
}
