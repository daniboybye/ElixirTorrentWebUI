import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject {
    private static let loopbackHost = "127.0.0.1"
    private static let appSupportDirectoryName = "ElixirTorrentWebUI"

    private lazy var appDisplayName = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ElixirTorrent Web"
    }()

    private let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "4000") ?? 4000
    var dockTorrents: [DockTorrent] = []
    var dockRefreshTask: Task<Void, Never>?
    private var openedFromURL = false
    private lazy var server = ServerLifecycle(
        dataDirectory: dataDirectory,
        releaseBinary: Bundle.main.resourceURL!
            .appendingPathComponent("rel/bin/elixir_torrent_web_ui")
    )

    private lazy var appURL = URL(string: "http://\(Self.loopbackHost):\(port)/")!

    lazy var torrentsEndpoint = appURL.appendingPathComponent("api/torrents")

    private lazy var magnetsEndpoint = appURL.appendingPathComponent("api/magnets")

    private lazy var dataDirectory =
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent(Self.appSupportDirectoryName,
                                    isDirectory: true)

    private func bootstrap() async {
        _ = await ensureServerReady()

        startDockTorrentRefresh()

        // When launched via magnet/torrent URL, `application(_:open:)` opens the browser.
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !openedFromURL {
            openBrowser()
        }
    }

    @discardableResult
    private func ensureServerReady() async -> Bool {
        if await !server.isPortListening(port) {
            guard await server.start(port: port) else {
                showAlert("Could not start \(appDisplayName).")
                NSApp.terminate(nil)
                return false
            }
        }

        let ready = await server.waitUntilReady(url: appURL, attempts: 60, intervalNanos: 250_000_000)

        if !ready {
            launcherLog("Server did not become HTTP-ready on port \(port) within timeout")
        }

        return ready
    }

    private func submitTorrentFile(at url: URL) async -> Bool {
        guard let staged = stageTorrent(at: url) else { return false }
        return await submitTorrentPath(staged.path)
    }

    private func stageTorrent(at url: URL) -> URL? {
        let inbox = dataDirectory.appendingPathComponent("inbox", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: inbox,
                                                    withIntermediateDirectories: true)

            let baseName = url.lastPathComponent.isEmpty ? BitTorrentDocument.defaultFilename : url.lastPathComponent
            let dest = inbox.appendingPathComponent("\(UUID().uuidString)-\(baseName)")

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }

            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private func submitTorrentPath(_ path: String) async -> Bool {
        var request = URLRequest(url: torrentsEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload = ["path": path]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }

        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 202
        } catch {
            return false
        }
    }

    private func submitMagnet(_ magnet: String) async -> Bool {
        var request = URLRequest(url: magnetsEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let payload = ["magnet": magnet]

        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            launcherLog("Magnet submit failed: could not encode JSON body")
            return false
        }

        request.httpBody = body

        for attempt in 1...5 {
            if !(await ensureServerReady()) {
                launcherLog("Magnet submit attempt \(attempt)/5: server not HTTP-ready on port \(port)")
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    launcherLog("Magnet submit attempt \(attempt)/5: response was not HTTP")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                if http.statusCode == 202 {
                    launcherLog("Magnet submit accepted")
                    return true
                }

                launcherLog("Magnet submit failed status=\(http.statusCode) body=\(responseBody.prefix(500))")
            } catch {
                launcherLog("Magnet submit attempt \(attempt)/5 error: \(error)")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        launcherLog("Magnet submit gave up after 5 attempts")
        return false
    }
}

// MARK: - NSApplicationDelegate

extension AppDelegate: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableSuddenTermination()
        Task { await bootstrap() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromURL = true

        Task {
            await ensureServerReady()

            var handled = false

            for url in urls {
                if url.scheme?.lowercased() == "magnet" {
                    handled = await submitMagnet(url.absoluteString) || handled
                } else if BitTorrentDocument.matches(url) {
                    handled = await submitTorrentFile(at: url) || handled
                }
            }

            if handled {
                openBrowser()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openBrowser()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await server.shutdown(port: port)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - UI actions

private extension AppDelegate {
    func openBrowser() {
        NSWorkspace.shared.open(appURL)
    }

    func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = appDisplayName
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
