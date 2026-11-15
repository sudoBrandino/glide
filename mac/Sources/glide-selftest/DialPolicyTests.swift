import Foundation
import GlideCore

/// The host's dial-out decisions (GlideCore/DialPolicy.swift, PROTOCOL.md §0 and §2.5).
func dialPolicyTests() {
    print("dial policy:")
    func next(paused: Bool = false, session: Bool = false, paired: Int = 0, open: Bool = false) -> DialPolicy.Action {
        DialPolicy.next(paused: paused, sessionActive: session, pairedViewers: paired, pairingOpen: open)
    }
    check(next(paired: 0, open: false) == .waitForPairing, "dial: no paired viewer + pairing closed -> don't dial")
    check(next(paired: 0, open: true) == .dial, "dial: pairing open -> dial the unpaired PC")
    check(next(paired: 1, open: false) == .dial, "dial: a paired viewer -> dial normally with pairing closed")
    check(next(session: true, paired: 1) == .waitForSession && next(session: true, paired: 0, open: true) == .waitForSession,
          "dial: idle while a viewer is connected")
    check(next(paused: true, paired: 1) == .stop && next(paused: true, paired: 0) == .stop, "dial: paused stops the loop")
    let delays = (0...8).map { Int(DialPolicy.redialDelay(failures: $0)) }
    check(delays == [2, 2, 4, 8, 16, 32, 60, 60, 60], "dial: redial 2 s, doubling from the 2nd failure to 60 s \(delays)")
}
