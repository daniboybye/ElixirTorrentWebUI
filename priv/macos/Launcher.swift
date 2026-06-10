import AppKit
import Darwin
import Foundation

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
            return false
        }

        do {
            try FileManager.default.createDirectory(at: dataDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
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
            return true
        } catch {
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
        await terminateOwnedProcess()
        await killListenersOnPort(port)
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "4000") ?? 4000
    private lazy var server = ServerLifecycle(
        dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            .appendingPathComponent("ElixirTorrentWebUI",
                                    isDirectory: true),
        releaseBinary: Bundle.main.resourceURL!
            .appendingPathComponent("rel/bin/elixir_torrent_web_ui")
    )

    private var appURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        ProcessInfo.processInfo.disableSuddenTermination()
        Task { await bootstrap() }
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

    private func bootstrap() async {
        if await server.isPortListening(port) {
            await MainActor.run { openBrowser() }
            return
        }

        guard await server.start(port: port) else {
            await MainActor.run {
                showAlert("Could not start ElixirTorrent Web.")
                NSApp.terminate(nil)
            }
            return
        }

        if await server.waitUntilReady(url: appURL, attempts: 60, intervalNanos: 250_000_000) {
            await MainActor.run { openBrowser() }
        }
    }

    @MainActor
    private func openBrowser() {
        NSWorkspace.shared.open(appURL)
    }

    @MainActor
    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ElixirTorrent Web"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
app.delegate = AppDelegate()
app.run()
