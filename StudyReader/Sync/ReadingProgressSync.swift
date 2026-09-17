import Foundation

/// A reading action, rather than a layout checkpoint. The timestamp is captured while reading,
/// never when uploading, so an older offline device cannot win just by reconnecting last.
struct ReadingProgressUpdate: Codable, Equatable, Sendable {
    var id = UUID()
    var device: UUID
    var updatedAt: Date
    var position: ReadingPosition

    func isNewer(than other: Self?) -> Bool {
        guard let other else { return true }
        if updatedAt != other.updatedAt { return updatedAt > other.updatedAt }
        if device != other.device { return device.uuidString > other.device.uuidString }
        return id.uuidString > other.id.uuidString
    }
}

/// One compact, replaceable snapshot per device. Frequent scrolling does not grow the immutable
/// article journal or cause Markdown/images to be recopied. Each snapshot can relay known winners.
struct ReadingProgressSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var library: UUID
    var device: UUID
    var updates: [String: ReadingProgressUpdate]

    func validate(library expectedLibrary: UUID, device expectedDevice: UUID) throws {
        guard version == 1, library == expectedLibrary, device == expectedDevice, updates.count <= 100_000,
              updates.allSatisfy({ key, update in
                  UUID(uuidString: key)?.uuidString == key && update.updatedAt.timeIntervalSince1970.isFinite &&
                  update.position.offset.isFinite && update.position.progress.isFinite &&
                  (0...1).contains(update.position.progress) && abs(update.position.offset) <= 1_000_000 &&
                  update.position.anchor.utf8.count <= 1024 && update.position.excerpt.utf8.count <= 4096
              }) else { throw ReaderFailure(message: "阅读进度记录无效，已保留本机进度。") }
    }

    static func merge(_ incoming: [String: ReadingProgressUpdate], into result: inout [String: ReadingProgressUpdate]) {
        for (key, update) in incoming where update.isNewer(than: result[key]) { result[key] = update }
    }

    static func remap(_ updates: [String: ReadingProgressUpdate], aliases: [String: UUID]) -> [String: ReadingProgressUpdate] {
        var result: [String: ReadingProgressUpdate] = [:]
        for (key, update) in updates {
            let target = aliases[key]?.uuidString ?? key
            if update.isNewer(than: result[target]) { result[target] = update }
        }
        return result
    }
}

struct ReadingProgressExchange: Sendable {
    var updates: [String: ReadingProgressUpdate]
    var waitingForUpload: Bool
    var waitingForDownload: Bool
}

enum ReadingProgressSync {
    static let maxBytes = 20_000_000

    static func exchange(_ local: ReadingProgressSnapshot, in root: URL) throws -> ReadingProgressExchange {
        guard try SyncFolderIO.header(at: root).id == local.library else {
            throw ReaderFailure(message: "所选文件夹已不是原来的同步资料库。")
        }
        try local.validate(library: local.library, device: local.device)
        let directory = try SyncFolderIO.child("Reading", in: root)
        try SyncFolderIO.requestDownload(directory)
        try SyncFolderIO.coordinate(writing: root) { folder in
            let directory = try SyncFolderIO.child("Reading", in: folder)
            if FileManager.default.fileExists(atPath: directory.path) {
                let info = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true else { throw ReaderFailure(message: "阅读进度目录无效。") }
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
            snapshots[id] = try SyncFolderIO.child("Reading/\(name)", in: root)
        }
        for (device, url) in snapshots {
            do {
                let snapshot = try JSONDecoder().decode(ReadingProgressSnapshot.self, from: SyncFolderIO.read(url, maxBytes: maxBytes))
                try snapshot.validate(library: local.library, device: device)
                ReadingProgressSnapshot.merge(snapshot.updates, into: &result.updates)
            } catch is SyncPending { pending = true }
        }
        let ownURL = try SyncFolderIO.child("Reading/\(local.device.uuidString).json", in: root)
        // Never overwrite an evicted snapshot before it has downloaded. It may contain a more
        // recent reading action after a restart or a delayed cloud update.
        do {
            try SyncFolderIO.requestDownload(ownURL)
            try SyncFolderIO.coordinate(writing: ownURL) { destination in
                var previous: Data?
                if FileManager.default.fileExists(atPath: destination.path) {
                    let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maxBytes else {
                        throw ReaderFailure(message: "阅读进度文件无效，未覆盖原文件。")
                    }
                    let data = try Data(contentsOf: destination)
                    let stored = try JSONDecoder().decode(ReadingProgressSnapshot.self, from: data)
                    try stored.validate(library: local.library, device: local.device)
                    ReadingProgressSnapshot.merge(stored.updates, into: &result.updates)
                    previous = data
                }
                let data = try SyncFolderIO.encoder.encode(result)
                guard data.count <= maxBytes else { throw ReaderFailure(message: "阅读进度超过同步大小限制。") }
                if data != previous { try data.write(to: destination, options: .atomic) }
            }
        } catch is SyncPending { pending = true }
        return ReadingProgressExchange(updates: result.updates,
                                       waitingForUpload: SyncFolderIO.waitingForUpload([ownURL]), waitingForDownload: pending)
    }
}
