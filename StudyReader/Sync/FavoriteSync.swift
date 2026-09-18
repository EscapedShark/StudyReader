import Foundation

struct FavoriteUpdate: Codable, Equatable, Sendable {
    var id = UUID()
    var device: UUID
    var updatedAt: Date
    var isFavorite: Bool

    func isNewer(than other: Self?) -> Bool {
        guard let other else { return true }
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        if device != other.device { return device.uuidString > other.device.uuidString }
        return id.uuidString > other.id.uuidString
    }
}

/// Separate per-device snapshots keep this additive extension compatible with older readers.
/// False values are retained as removals, so reconnecting devices cannot resurrect a favorite.
struct FavoriteSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var library: UUID
    var device: UUID
    var updates: [String: FavoriteUpdate]

    func validate(library expectedLibrary: UUID, device expectedDevice: UUID) throws {
        guard version == 1, library == expectedLibrary, device == expectedDevice, updates.count <= 100_000,
              updates.allSatisfy({ key, update in
                  UUID(uuidString: key)?.uuidString == key && update.updatedAt.timeIntervalSince1970.isFinite
              }) else { throw ReaderFailure(message: "收藏记录无效，已保留本机进度。") }
    }

    static func merge(_ incoming: [String: FavoriteUpdate], into result: inout [String: FavoriteUpdate]) {
        for (key, update) in incoming where update.isNewer(than: result[key]) { result[key] = update }
    }

    static func remap(_ updates: [String: FavoriteUpdate], aliases: [String: UUID]) -> [String: FavoriteUpdate] {
        var result: [String: FavoriteUpdate] = [:]
        for (key, update) in updates {
            let target = aliases[key]?.uuidString ?? key
            if update.isNewer(than: result[target]) { result[target] = update }
        }
        return result
    }
}

struct FavoriteExchange: Sendable {
    var updates: [String: FavoriteUpdate]
    var waitingForUpload: Bool
    var waitingForDownload: Bool
}

enum FavoriteSync {
    static let maxBytes = 20_000_000

    static func exchange(_ local: FavoriteSnapshot, in root: URL) throws -> FavoriteExchange {
        guard try SyncFolderIO.header(at: root).id == local.library else {
            throw ReaderFailure(message: "所选文件夹已不是原来的同步资料库。")
        }
        try local.validate(library: local.library, device: local.device)
        let directory = try SyncFolderIO.child("Favorites", in: root)
        try SyncFolderIO.requestDownload(directory)
        try SyncFolderIO.coordinate(writing: root) { folder in
            let directory = try SyncFolderIO.child("Favorites", in: folder)
            if FileManager.default.fileExists(atPath: directory.path) {
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { throw ReaderFailure(message: "收藏目录无效。") }
            } else { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
        }
        let urls = try SyncFolderIO.coordinate(reading: directory) {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        var result = local, pending = false
        var snapshots: [UUID: URL] = [:]
        for url in urls {
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            snapshots[id] = try SyncFolderIO.child("Favorites/\(name)", in: root)
        }
        for (device, url) in snapshots {
            do {
                let snapshot = try JSONDecoder().decode(FavoriteSnapshot.self, from: SyncFolderIO.read(url, maxBytes: maxBytes))
                try snapshot.validate(library: local.library, device: device)
                FavoriteSnapshot.merge(snapshot.updates, into: &result.updates)
            } catch is SyncPending { pending = true }
        }
        let ownURL = try SyncFolderIO.child("Favorites/\(local.device.uuidString).json", in: root)
        // Never overwrite an evicted snapshot before it has downloaded. It may contain a more
        // recent reading action after a restart or a delayed cloud update.
        do {
            try SyncFolderIO.requestDownload(ownURL)
            try SyncFolderIO.coordinate(writing: ownURL) { destination in
                var previous: Data?
                if FileManager.default.fileExists(atPath: destination.path) {
                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maxBytes else {
                        throw ReaderFailure(message: "收藏文件无效，未覆盖原文件。")
                    }
                    let data = try Data(contentsOf: destination)
                    let stored = try JSONDecoder().decode(FavoriteSnapshot.self, from: data)
                    try stored.validate(library: local.library, device: local.device)
                    FavoriteSnapshot.merge(stored.updates, into: &result.updates)
                    previous = data
                }
                let data = try SyncFolderIO.encoder.encode(result)
                guard data.count <= maxBytes else { throw ReaderFailure(message: "收藏超过同步大小限制。") }
                if data != previous { try data.write(to: destination, options: .atomic) }
            }
        } catch is SyncPending { pending = true }
        return FavoriteExchange(updates: result.updates,
                                       waitingForUpload: SyncFolderIO.waitingForUpload([ownURL]), waitingForDownload: pending)
    }
}
