import AppKit
import CoreServices
import Foundation

// MARK: - Default handler coordination (LaunchServices)

/// Wraps the LaunchServices calls that answer "am I the default program for
/// .torrent files and magnet: links?" and, when asked, register the bundle as
/// such. The heavy lifting is inside a single actor so callers can rely on
/// serialised access from any thread.
enum DefaultHandlerCoordinator: Sendable {
    struct Status: Sendable {
        let torrent: Bool
        let magnet: Bool

        var bothDefault: Bool { torrent && magnet }

        func jsonPayload() -> String {
            "{\"torrent\":\(torrent ? "true" : "false"),\"magnet\":\(magnet ? "true" : "false")}"
        }
    }

    static let torrentType = "com.elixirtorrent.webui.torrent"
    static let legacyTorrentType = "org.bittorrent.torrent"
    static let magnetScheme = "magnet"

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.elixirtorrent.webui"
    }

    static func currentStatus() -> Status {
        let target = bundleIdentifier
        return Status(
            torrent: isDefaultForTorrentFiles(target),
            magnet: matches(handlerForURLScheme(magnetScheme), target)
        )
    }

    /// `.torrent` files on disk carry the shared `org.bittorrent.torrent` UTI,
    /// so that handler alone decides what a double-click opens. Our exported
    /// `com.elixirtorrent.webui.torrent` is declared by this bundle and no
    /// other, which means it resolves back to us as soon as we are registered
    /// — accepting it as an alternative reported "already the default" even
    /// while another client owned every real file. It is only meaningful as a
    /// fallback on a system where nothing claims the shared UTI.
    private static func isDefaultForTorrentFiles(_ target: String) -> Bool {
        if let handler = handlerForContentType(legacyTorrentType) {
            return matches(handler, target)
        }

        return matches(handlerForContentType(torrentType), target)
    }

    @discardableResult
    static func registerAsDefault() -> Bool {
        let target = bundleIdentifier as CFString
        var success = true

        let torrentStatus = LSSetDefaultRoleHandlerForContentType(
            torrentType as CFString,
            .viewer,
            target
        )

        if torrentStatus != noErr {
            launcherLog("LSSetDefaultRoleHandlerForContentType(torrent) returned \(torrentStatus)")
        }

        let legacyTorrentStatus = LSSetDefaultRoleHandlerForContentType(
            legacyTorrentType as CFString,
            .viewer,
            target
        )

        if legacyTorrentStatus != noErr {
            launcherLog("LSSetDefaultRoleHandlerForContentType(legacy torrent) returned \(legacyTorrentStatus)")
        }

        // Mirror `isDefaultForTorrentFiles`: the shared UTI is what real files
        // bind to, and our exported one only matters on a system where nothing
        // claims the shared type. Judge the outcome by whichever of the two
        // actually governs here, not by both.
        let torrentRegistered =
            handlerForContentType(legacyTorrentType) != nil
                ? legacyTorrentStatus == noErr
                : torrentStatus == noErr

        if !torrentRegistered {
            success = false
        }

        let magnetStatus = LSSetDefaultHandlerForURLScheme(
            magnetScheme as CFString,
            target
        )

        if magnetStatus != noErr {
            launcherLog("LSSetDefaultHandlerForURLScheme(magnet) returned \(magnetStatus)")
            success = false
        }

        // `LSSetDefaultRoleHandlerForContentType` can return `noErr` before
        // LaunchServices' database has actually persisted the change — even a
        // read from this same process immediately afterward can still see the
        // old handler. The Elixir side runs `--check-defaults` as a brand new
        // process right after this one exits, so without waiting here the UI
        // banner does not clear until the next unrelated status refresh. This
        // is a short, best-effort cushion for the common case — the `--await
        // -default-status` subcommand below covers the long tail.
        if success {
            _ = awaitStatus(timeoutSeconds: 1, intervalMicros: 25_000, until: { $0.bothDefault })
        }

        return success
    }

    /// Blocks the calling process — this is meant to be run from a CLI
    /// subcommand, not the GUI app — polling `currentStatus()` until
    /// `predicate` is satisfied or `timeoutSeconds` elapses, then returns
    /// whatever the final status was. Elixir uses this (via
    /// `--await-default-status`) to be notified the moment LaunchServices
    /// actually reflects a registration, instead of re-asking on a timer.
    static func awaitStatus(
        timeoutSeconds: Double,
        intervalMicros: UInt32 = 150_000,
        until predicate: (Status) -> Bool
    ) -> Status {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var status = currentStatus()

        while !predicate(status) && Date() < deadline {
            usleep(intervalMicros)
            status = currentStatus()
        }

        return status
    }

    private static func handlerForContentType(_ uti: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(uti as CFString, .viewer)?
            .takeRetainedValue() as String?
    }

    private static func handlerForURLScheme(_ scheme: String) -> String? {
        guard let schemeURL = URL(string: "\(scheme):"),
            let appURL = NSWorkspace.shared.urlForApplication(toOpen: schemeURL)
        else {
            return nil
        }

        return Bundle(url: appURL)?.bundleIdentifier
    }

    private static func matches(_ handler: String?, _ expected: String) -> Bool {
        guard let handler else { return false }
        return handler.caseInsensitiveCompare(expected) == .orderedSame
    }
}
