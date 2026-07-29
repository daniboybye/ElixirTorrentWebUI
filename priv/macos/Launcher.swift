import AppKit
import Darwin
import Foundation
import UniformTypeIdentifiers

fileprivate func launcherLog(_ message: String) {
    NSLog("[ElixirTorrentWebUI] \(message)")
}

private enum BitTorrentDocument {
    static let exportedType = UTType("com.elixirtorrent.webui.torrent")
    static let legacyType = UTType(importedAs: "org.bittorrent.torrent")

    static func matches(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           conformsToTorrentType(type) {
            return true
        }

        if let type = UTType(filenameExtension: url.pathExtension),
           conformsToTorrentType(type) {
            return true
        }

        return false
    }

    private static func conformsToTorrentType(_ type: UTType) -> Bool {
        if let exportedType, type.conforms(to: exportedType) {
            return true
        }

        if type.conforms(to: legacyType) {
            return true
        }

        return false
    }

    static var defaultFilename: String {
        let ext = exportedType?.preferredFilenameExtension
            ?? legacyType.preferredFilenameExtension
            ?? "torrent"
        return "download.\(ext)"
    }
}

fileprivate actor ServerLifecycle {
    private var ownedProcess: Process?
    private let dataDirectory: URL
    private let releaseBinary: URL

    init(dataDirectory: URL, releaseBinary: URL) {
        self.dataDirectory = dataDirectory
        self.releaseBinary = releaseBinary
    }

    func isPortListening(_ port: Int) -> Bool {
        !listenerPIDs(on: port).isEmpty
    }

    func start(port: Int) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: releaseBinary.path) else {
            launcherLog("Server start failed: release binary is not executable at \(releaseBinary.path)")
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dataDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            launcherLog("Server start failed: could not create data directory \(dataDirectory.path): \(error)")
            return false
        }

        let process = Process()
        process.executableURL = releaseBinary
        process.arguments = ["start"]
        process.currentDirectoryURL = dataDirectory
        process.environment = releaseEnvironment(port: port)

        do {
            try process.run()
            ownedProcess = process
            launcherLog("Server process started on port \(port)")
            return true
        } catch {
            launcherLog("Server start failed: \(error)")
            return false
        }
    }

    func waitUntilReady(url: URL, attempts: Int, intervalNanos: UInt64) async -> Bool {
        for _ in 0..<attempts {
            if await isServerReady(url: url) {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanos)
        }
        return false
    }

    func shutdown(port: Int) async {
        stopRelease(port: port)
        await waitUntilPortClosed(port, timeout: 10)
        await terminateOwnedProcess()
        await killListenersOnPort(port)
    }

    private func waitUntilPortClosed(_ port: Int, timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !isPortListening(port) {
                return
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func stopRelease(port: Int) {
        guard isPortListening(port) else { return }

        let process = Process()
        process.executableURL = releaseBinary
        process.arguments = ["stop"]
        process.currentDirectoryURL = dataDirectory
        process.environment = releaseEnvironment(port: port)
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Fall back to port/PID termination below.
        }
    }

    private func terminateOwnedProcess() async {
        guard let process = ownedProcess, process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(3)

        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func killListenersOnPort(_ port: Int) async {
        let pids = listenerPIDs(on: port)
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(3)

        while Date() < deadline {
            if listenerPIDs(on: port).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        for pid in listenerPIDs(on: port) {
            kill(pid, SIGKILL)
        }
    }

    private func isServerReady(url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode < 500
        } catch {
            return false
        }
    }

    private func releaseEnvironment(port: Int) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PHX_SERVER"] = "true"
        environment["ELIXIR_TORRENT_DESKTOP"] = "1"
        environment["PORT"] = String(port)
        return environment
    }

    private func listenerPIDs(on port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-tiTCP:\(port)", "-sTCP:LISTEN"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}

final class AppDelegate: NSObject {
    private static let loopbackHost = "127.0.0.1"
    private static let appSupportDirectoryName = "ElixirTorrentWebUI"

    private lazy var appDisplayName: String = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "ElixirTorrent Web"
    }()

    private let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "4000") ?? 4000
    @MainActor private var dockTorrents: [DockTorrent] = []
    @MainActor private var dockRefreshTask: Task<Void, Never>?
    private var openedFromURL = false
    private lazy var server = ServerLifecycle(
        dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            .appendingPathComponent(Self.appSupportDirectoryName,
                                    isDirectory: true),
        releaseBinary: Bundle.main.resourceURL!
            .appendingPathComponent("rel/bin/elixir_torrent_web_ui")
    )

    private var appURL: URL {
        URL(string: "http://\(Self.loopbackHost):\(port)/")!
    }

    private var torrentsEndpoint: URL {
        appURL.appendingPathComponent("api/torrents")
    }

    private var magnetsEndpoint: URL {
        appURL.appendingPathComponent("api/magnets")
    }

    private var dataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
            .appendingPathComponent(Self.appSupportDirectoryName,
                                    isDirectory: true)
    }

    private func bootstrap() async {
        _ = await ensureServerReady()

        await MainActor.run {
            startDockTorrentRefresh()
        }

        // When launched via magnet/torrent URL, `application(_:open:)` opens the browser.
        try? await Task.sleep(nanoseconds: 200_000_000)
        if !openedFromURL {
            await MainActor.run { openBrowser() }
        }
    }

    @discardableResult
    private func ensureServerReady() async -> Bool {
        if await !server.isPortListening(port) {
            guard await server.start(port: port) else {
                await MainActor.run {
                    showAlert("Could not start \(appDisplayName).")
                    NSApp.terminate(nil)
                }
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

        let preview = magnet.prefix(120)

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
                    launcherLog("Magnet submit ok status=202 uri=\(preview) body=\(responseBody.prefix(200))")
                    return true
                }

                launcherLog("Magnet submit failed status=\(http.statusCode) uri=\(preview) body=\(responseBody.prefix(500))")
            } catch {
                launcherLog("Magnet submit attempt \(attempt)/5 error uri=\(preview): \(error)")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        launcherLog("Magnet submit gave up after 5 attempts uri=\(preview)")
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
                await MainActor.run { openBrowser() }
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

            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

// MARK: - UI actions

@MainActor
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

// MARK: - Dock Menu (Active Torrents)

private struct DockTorrent: Decodable, Sendable {
    let name: String
    let status: String
    let downKbps: Double
    let upKbps: Double
}

private struct TorrentsResponse: Decodable, Sendable {
    let torrents: [DockTorrent]
}

@MainActor
extension AppDelegate {
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard !dockTorrents.isEmpty else { return nil }

        let menu = NSMenu()
        let downloading = dockTorrents.filter { $0.status != "Seeding" }
        let seeding = dockTorrents.filter { $0.status == "Seeding" }

        if !downloading.isEmpty {
            menu.addItem(dockHeaderItem("Downloading:"))
            for torrent in downloading {
                menu.addItem(dockTorrentItem(torrent, seeding: false))
            }
        }

        if !seeding.isEmpty {
            menu.addItem(dockHeaderItem("Seeding:"))
            for torrent in seeding {
                menu.addItem(dockTorrentItem(torrent, seeding: true))
            }
        }

        menu.addItem(.separator())
        return menu
    }

    private func startDockTorrentRefresh() {
        dockRefreshTask?.cancel()
        dockRefreshTask = Task {
            while !Task.isCancelled {
                if let torrents = await Self.refreshDockTorrents(endpoint: torrentsEndpoint) {
                    dockTorrents = torrents
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    nonisolated fileprivate static func refreshDockTorrents(endpoint: URL) async -> [DockTorrent]? {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(TorrentsResponse.self, from: data)
            return decoded.torrents
        } catch {
            return nil
        }
    }

    private func dockHeaderItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func dockTorrentItem(_ torrent: DockTorrent, seeding: Bool) -> NSMenuItem {
        let suffix: String
        if seeding {
            suffix = "|↑| \(formatDockSpeed(torrent.upKbps))"
        } else if torrent.downKbps > 0 {
            suffix = "|↓| \(formatDockSpeed(torrent.downKbps))"
        } else {
            suffix = "|↓| \(torrent.status.lowercased())"
        }

        let title = "\(truncateDockName(torrent.name))  \(suffix)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    private func truncateDockName(_ name: String, prefix: Int = 24, suffix: Int = 16) -> String {
        let maxLength = prefix + suffix + 1
        guard name.count > maxLength else { return name }

        let start = name.prefix(prefix)
        let end = name.suffix(suffix)
        return "\(start)…\(end)"
    }

    private func formatDockSpeed(_ kbps: Double) -> String {
        guard kbps > 0 else { return "0 B/s" }

        let bytesPerSecond = kbps * 1024
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / (1024 * 1024))
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.1f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
