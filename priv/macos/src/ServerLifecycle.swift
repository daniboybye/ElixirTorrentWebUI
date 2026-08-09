import Darwin
import Foundation

actor ServerLifecycle {
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
            try FileManager.default.createDirectory(
                at: dataDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            launcherLog("Server start failed: could not create data directory \(dataDirectory.path): \(error)")
            return false
        }

        let process = Process()
        process.executableURL = releaseBinary
        process.arguments = ["start"]
        process.currentDirectoryURL = dataDirectory
        process.environment = releaseEnvironment(port: port)

        if let logHandle = openServerLog() {
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

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

        // Expose ourselves to the release so the DefaultHandler and folder
        // pickers can shell back into this bundle instead of reaching for
        // Finder/Explorer.
        if let launcher = Bundle.main.executablePath {
            environment["ELIXIR_TORRENT_LAUNCHER"] = launcher
        }

        return environment
    }

    private func openServerLog() -> FileHandle? {
        let logURL = dataDirectory.appendingPathComponent("server.log")

        do {
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: logURL)
            handle.seekToEndOfFile()
            return handle
        } catch {
            launcherLog("Could not open server log at \(logURL.path): \(error)")
            return nil
        }
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
