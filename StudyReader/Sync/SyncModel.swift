import Foundation
import CryptoKit

/// The shared folder is an append-only journal. Devices never replace another device's
/// manifest or upload their local reading-state / organization JSON over it.
struct SyncLibraryHeader: Codable, Equatable, Sendable {
    var format = "StudyReader"
    var version = 1
    var id: UUID
}

struct SyncFile: Codable, Equatable, Sendable {
    var path: String
    var blob: String
    var bytes: Int
}

struct SyncArticle: Codable, Equatable, Sendable {
    var record: DocumentRecord
    var packageName: String
    var importedAt: Date
    var sourceFingerprint: String
    var files: [SyncFile]
}

struct SyncArticleChange: Codable, Equatable, Sendable {
    var id: UUID
    var parents: [UUID]
    /// nil is a tombstone, not a file that hasn't downloaded yet.
    var article: SyncArticle?
}

struct SyncEvent: Codable, Equatable, Sendable {
    var version = 1
    var id: UUID
    var device: UUID
    var clock: UInt64
    var articles: [SyncArticleChange] = []
    var folderNames: [String: String] = [:]
    var memberships: [String: UUID] = [:]
    var folderOrders: [String: [UUID]] = [:]
    var folderOrder: [UUID]?
    var documentOrder: [UUID]?

    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.clock != rhs.clock { return lhs.clock < rhs.clock }
        if lhs.device != rhs.device { return lhs.device.uuidString < rhs.device.uuidString }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct SyncBaseline: Codable, Sendable {
    var records: [String: DocumentRecord] = [:]
    var heads: [String: [UUID]] = [:]
    var organization = LibraryOrganization()
}

struct SyncCache: Codable, Sendable {
    var version = 1
    var libraryID: UUID
    var deviceID = UUID()
    var clock: UInt64 = 0
    var events: [SyncEvent] = []
    var baseline = SyncBaseline()
    var didCaptureLocal = false
    var aliases: [String: UUID] = [:]
}

struct SyncProjection: Sendable {
    var articles: [UUID: SyncArticle]
    var heads: [String: [UUID]]
    var organization: LibraryOrganization
    var recoveries: [SyncEvent]

    var baseline: SyncBaseline {
        SyncBaseline(records: Dictionary(uniqueKeysWithValues: articles.map { ($0.key.uuidString, $0.value.record) }),
                     heads: heads, organization: organization)
    }
}

enum SyncPending: LocalizedError {
    case download
    var errorDescription: String? { "正在等待 iCloud 下载资料，已保存的文章仍可离线阅读。" }
}

enum SyncModel {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") &&
        path.rangeOfCharacter(from: .controlCharacters) == nil &&
        path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    static func validBlob(_ blob: String) -> Bool {
        let parts = blob.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts[0].count == 64 && parts[0].allSatisfy { "0123456789abcdef".contains($0) }
            && LibraryDisk.supportedExtensions.contains(String(parts[1]))
    }

    static func validate(_ event: SyncEvent) throws {
        guard event.version == 1, event.clock < UInt64.max,
              Set(event.articles.map(\.id)).count == event.articles.count else {
            throw ReaderFailure(message: "同步记录版本不受支持或记录损坏，已保留本机资料。")
        }
        for change in event.articles {
            guard !change.parents.contains(event.id), Set(change.parents).count == change.parents.count else {
                throw ReaderFailure(message: "同步记录的版本关系无效。")
            }
            guard let article = change.article else { continue }
            let files = article.files
            guard article.record.id == change.id, validPath(article.record.relativePath),
                  LibraryDisk.markdownExtensions.contains((article.record.relativePath as NSString).pathExtension.lowercased()),
                  Set(files.map { $0.path.lowercased() }).count == files.count,
                  files.contains(where: { $0.path == article.record.relativePath }), files.count <= 10_000 else {
                throw ReaderFailure(message: "同步文章的路径或附件清单无效。")
            }
            var total = 0
            for file in files {
                guard validPath(file.path), validBlob(file.blob), file.bytes >= 0,
                      file.bytes <= (LibraryDisk.markdownExtensions.contains((file.path as NSString).pathExtension.lowercased()) ? 5_000_000 : 25_000_000),
                      (file.path as NSString).pathExtension.lowercased() == (file.blob as NSString).pathExtension else {
                    throw ReaderFailure(message: "同步附件无效或超过大小限制。")
                }
                total += file.bytes
            }
            guard total <= 200_000_000 else { throw ReaderFailure(message: "同步文章及附件超过 200 MB。") }
        }
        for (key, name) in event.folderNames {
            guard UUID(uuidString: key) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.count <= 100, name.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw ReaderFailure(message: "同步资料夹名称无效。")
            }
        }
        guard event.memberships.keys.allSatisfy({ UUID(uuidString: $0) != nil }),
              event.folderOrders.keys.allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw ReaderFailure(message: "同步整理记录无效。")
        }
    }

    /// Registers merge independently: renaming one folder cannot undo moving an unrelated
    /// article. Concurrent sorts use a deterministic Lamport order and retain all new items.
    static func project(_ events: [SyncEvent]) throws -> SyncProjection {
        var byEvent: [UUID: SyncEvent] = [:]
        for event in events {
            try validate(event)
            if let old = byEvent[event.id], old != event { throw ReaderFailure(message: "发现内容不同的同名同步记录。") }
            byEvent[event.id] = event
        }
        let ordered = byEvent.values.sorted(by: SyncEvent.precedes)
        var nodes: [UUID: [(event: SyncEvent, change: SyncArticleChange)]] = [:]
        var names: [String: String] = [:], memberships: [String: UUID] = [:]
        var folderOrders: [String: [UUID]] = [:]
        var folderOrder: [UUID] = [], documentOrder: [UUID] = []
        for event in ordered {
            names.merge(event.folderNames) { _, new in new }
            memberships.merge(event.memberships) { _, new in new }
            folderOrders.merge(event.folderOrders) { _, new in new }
            if let order = event.folderOrder { folderOrder = order }
            if let order = event.documentOrder { documentOrder = order }
            for change in event.articles { nodes[change.id, default: []].append((event, change)) }
        }
        var articles: [UUID: SyncArticle] = [:], heads: [String: [UUID]] = [:], recoveries: [SyncEvent] = []
        for (id, versions) in nodes {
            let versionIDs = Set(versions.map { $0.event.id })
            var consumed = Set<UUID>()
            for node in versions {
                for parent in node.change.parents {
                    guard versionIDs.contains(parent), let ancestor = byEvent[parent] else { throw SyncPending.download }
                    guard ancestor.clock < node.event.clock else { throw ReaderFailure(message: "同步记录存在循环版本关系。") }
                    consumed.insert(parent)
                }
            }
            let tips = versions.filter { !consumed.contains($0.event.id) }
            heads[id.uuidString] = tips.map { $0.event.id }.sorted { $0.uuidString < $1.uuidString }
            let live = tips.filter { $0.change.article != nil }
            // A concurrent deletion removes the original, but never destroys an unseen edit.
            let hasDeletion = tips.contains { $0.change.article == nil }
            let winner = hasDeletion ? nil : live.last
            if let article = winner?.change.article { articles[id] = article }
            for loser in live where loser.event.id != winner?.event.id {
                // Identical concurrent uploads are already preserved by the winning version.
                if let winnerArticle = winner?.change.article, let candidate = loser.change.article,
                   candidate.record.relativePath == winnerArticle.record.relativePath,
                   candidate.files == winnerArticle.files { continue }
                guard var recovered = loser.change.article else { continue }
                let recoveryID = stableID("conflict-document:\(id):\(loser.event.id)")
                let recoveryEventID = stableID("conflict-event:\(id):\(loser.event.id)")
                guard nodes[recoveryID] == nil else { continue }
                let originalPath = recovered.record.relativePath
                let directory = (originalPath as NSString).deletingLastPathComponent
                let ext = (originalPath as NSString).pathExtension
                // Leave room for the suffix even when the original UTF-8 filename was at its limit.
                var stem = DocumentFileName.title(for: originalPath)
                let suffix = "（冲突副本 \(loser.event.id.uuidString.prefix(6))）.\(ext)"
                while (stem + suffix).utf8.count > 240 { stem.removeLast() }
                let filename = stem + suffix
                let path = directory.isEmpty ? filename : directory + "/" + filename
                recovered.record = DocumentRecord(id: recoveryID, title: DocumentFileName.title(for: path), relativePath: path, revision: recoveryEventID)
                recovered.files = recovered.files.map { file in
                    var file = file
                    if file.path == originalPath { file.path = path }
                    return file
                }
                var event = SyncEvent(id: recoveryEventID, device: loser.event.device, clock: loser.event.clock,
                                      articles: [.init(id: recoveryID, parents: [], article: recovered)])
                // Recovery bytes must be identical even when devices have received different
                // subsets of unrelated folder moves. A stable recovery folder avoids encoding
                // the receiver's current membership into the same immutable event filename.
                let recoveryFolder = stableID("conflict-folder")
                let folderEventID = stableID("conflict-folder-event")
                event.memberships[recoveryID.uuidString] = recoveryFolder
                if byEvent[folderEventID] == nil, !recoveries.contains(where: { $0.id == folderEventID }) {
                    recoveries.append(SyncEvent(id: folderEventID, device: stableID("system"), clock: 0,
                                                folderNames: [recoveryFolder.uuidString: "冲突资料"]))
                }
                if names[recoveryFolder.uuidString] == nil { names[recoveryFolder.uuidString] = "冲突资料" }
                // Persist recovery as a real article. Later edits to the original must not make
                // the conflict copy disappear; deleting the copy creates its own tombstone.
                recoveries.append(event)
                articles[recoveryID] = recovered
                heads[recoveryID.uuidString] = [recoveryEventID]
                if let folder = event.memberships[recoveryID.uuidString] { memberships[recoveryID.uuidString] = folder }
            }
        }
        let docIDs = Set(articles.keys)
        func orderedIDs(_ preferred: [UUID], among valid: Set<UUID>) -> [UUID] {
            var seen = Set<UUID>()
            return preferred.filter { valid.contains($0) && seen.insert($0).inserted }
                + valid.filter { !seen.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        }
        // All document creates carry a folder name, but old/partial independent metadata may
        // arrive later. Keep a deterministic fallback instead of dropping the article.
        for id in docIDs where memberships[id.uuidString] == nil || names[memberships[id.uuidString]!.uuidString] == nil {
            let folder = stableID("unfiled")
            names[folder.uuidString] = "未分类资料"
            memberships[id.uuidString] = folder
        }
        let folderIDs = Set(names.keys.compactMap(UUID.init(uuidString:)))
        let folders = orderedIDs(folderOrder, among: folderIDs).map { id in
            LibraryFolder(id: id, name: names[id.uuidString]!, documentIDs: orderedIDs(folderOrders[id.uuidString] ?? [],
                among: Set(docIDs.filter { memberships[$0.uuidString] == id })))
        }
        return SyncProjection(articles: articles, heads: heads,
                              organization: LibraryOrganization(folders: folders, documentOrder: orderedIDs(documentOrder, among: docIDs)),
                              recoveries: recoveries.sorted { $0.id.uuidString < $1.id.uuidString })
    }
}
