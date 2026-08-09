import Foundation
import UniformTypeIdentifiers

enum BitTorrentDocument: Sendable {
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

    static let defaultFilename = {
        let ext = exportedType?.preferredFilenameExtension
            ?? legacyType.preferredFilenameExtension
            ?? "torrent"
        return "download.\(ext)"
    }()
}
