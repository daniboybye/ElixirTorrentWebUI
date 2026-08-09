import AppKit
import Foundation

// MARK: - Dock Menu (Active Torrents)

struct DockTorrent: Decodable, Sendable {
    let name: String
    let status: String
    let downKbps: Double
    let upKbps: Double
}

private struct TorrentsResponse: Decodable, Sendable {
    let torrents: [DockTorrent]
}

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

    func startDockTorrentRefresh() {
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
