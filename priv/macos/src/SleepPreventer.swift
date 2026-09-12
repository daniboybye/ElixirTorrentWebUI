import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Holds `kIOPMAssertPreventUserIdleSystemSleep` while a torrent still needs
/// bytes and the machine is on AC power.
///
/// Without it the engine simply stops making progress unattended. Measured on
/// 2026-09-12: macOS put this Mac into `'Maintenance Sleep':TCPKeepAlive=active`
/// repeatedly overnight, waking only for 45-second DarkWake slices, so the node
/// accumulated **64 minutes of awake time in 7 hours** and five incomplete
/// torrents moved 19 MB between them. Sleeping is worse than just lost time:
/// every peer TCP connection dies with it, so each wake has to re-dial the swarm
/// from cold — the `[peer_dial] fail … reason=:etimedout` burst after each wake.
///
/// Two deliberate limits, both chosen by the owner:
///   * **Seeding does not hold the assertion.** Once everything is complete the
///     laptop is allowed to sleep; otherwise a finished queue would keep it
///     awake indefinitely.
///   * **Battery does not hold it either.** The assertion is dropped as soon as
///     the charger comes out, so this can never flatten the battery.
@MainActor
final class SleepPreventer {
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    /// Anything that is not seeding still needs the machine awake, which is why
    /// this is `!= "Seeding"` rather than `== "Downloading"`. The engine derives
    /// the status from the piece currently being fetched, so an incomplete
    /// torrent reports `"Connecting"` or `"Idle"` whenever no piece is assigned
    /// — and behind CGNAT, where a torrent runs on one to three peers, that is a
    /// state it passes through constantly while hunting for somewhere to ask.
    /// Letting the Mac sleep there would strand it exactly when re-dialling is
    /// the only thing that can rescue it. This also matches the Dock menu, which
    /// files every non-seeding torrent under "Downloading:".
    ///
    /// `downKbps` cannot be the trigger even though it reads like the natural
    /// one: the API reports `0.0` for torrents that are demonstrably
    /// progressing, because the underlying counter is piece-granular and the
    /// sample window is shorter than one piece (engine `PLAN.md` open bug #53b).
    private static func hasIncompleteTorrent(_ torrents: [DockTorrent]) -> Bool {
        torrents.contains { $0.status != "Seeding" }
    }

    /// A machine with no battery (desktop) reports AC, which is what we want.
    /// An unreadable power source is treated as AC too: the failure mode of
    /// guessing wrong here is a laptop that stays awake, which is recoverable,
    /// versus a download queue that silently never finishes, which is the bug
    /// this class exists to fix.
    private static func isOnACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else {
            return true
        }

        return (source as String) == kIOPSACPowerValue
    }

    /// Re-evaluated on every Dock refresh tick (2 s), so the assertion follows
    /// both the queue and the power source without a timer of its own.
    func update(torrents: [DockTorrent]) {
        if Self.hasIncompleteTorrent(torrents) && Self.isOnACPower() {
            acquire()
        } else {
            release()
        }
    }

    /// Released explicitly on quit — an assertion outlives the process that made
    /// it only until the port closes, and leaving it to chance would leave the
    /// Mac awake after the app is gone.
    func releaseForShutdown() {
        release()
    }

    private func acquire() {
        guard !isHeld else { return }

        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "ElixirTorrent is downloading" as CFString,
            &id
        )

        guard result == kIOReturnSuccess else {
            launcherLog("Could not create sleep assertion: IOReturn \(result)")
            return
        }

        assertionID = id
        isHeld = true
        launcherLog("Holding sleep assertion: downloading on AC power")
    }

    private func release() {
        guard isHeld else { return }

        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
        launcherLog("Released sleep assertion")
    }
}
