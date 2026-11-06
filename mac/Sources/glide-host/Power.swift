import Foundation
import IOKit.pwr_mgt

/// Power management for a remote-controlled Mac.
enum Power {
    /// Keeps the system from idle-sleeping while the host runs: the Mac dials out to the viewer,
    /// so a sleeping Mac is unreachable.
    static func preventSystemSleep() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Glide Host is available for remote control" as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
    }

    /// Keeps the display on while a viewer is connected (no display -> nothing to capture).
    static func preventDisplaySleep() -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let r = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Glide remote session active" as CFString, &id)
        return r == kIOReturnSuccess ? id : nil
    }

    static func release(_ id: IOPMAssertionID?) { if let id { IOPMAssertionRelease(id) } }

    /// Wakes the display (as if the user touched the keyboard). Cheap; safe to call often.
    private static var lastWake: UInt64 = 0
    static func wakeDisplay() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastWake > 1_000_000_000 else { return }  // at most once a second
        lastWake = now
        var id = IOPMAssertionID(0)
        IOPMAssertionDeclareUserActivity("Glide remote input" as CFString, kIOPMUserActiveLocal, &id)
    }
}
