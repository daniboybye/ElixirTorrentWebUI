import Foundation

// MARK: - CLI

enum LauncherCLI: Sendable {
    static func handle(arguments: [String]) -> Int32? {
        // The bundle launcher is normally invoked with zero arguments. When
        // the release shells back into us for default-handler coordination
        // we're invoked with a single subcommand and must exit without
        // starting the desktop lifecycle.
        guard arguments.count >= 2 else { return nil }

        switch arguments[1] {
        case "--check-defaults":
            let payload = DefaultHandlerCoordinator.currentStatus().jsonPayload()
            print(payload)
            return 0

        case "--register-defaults":
            let ok = DefaultHandlerCoordinator.registerAsDefault()
            return ok ? 0 : 2

        case "--await-default-status":
            // Elixir spawns this in the background (not blocking the click
            // that triggered registration) right after a `--register-
            // defaults` that did not converge immediately. It blocks here,
            // in this one process, until LaunchServices actually reflects
            // the change — the caller is notified by this process exiting
            // with fresh status, rather than re-invoking `--check-defaults`
            // on a fixed timer.
            let payload = DefaultHandlerCoordinator.awaitStatus(
                timeoutSeconds: 15,
                until: { $0.bothDefault }
            ).jsonPayload()
            print(payload)
            return 0

        default:
            return nil
        }
    }
}
