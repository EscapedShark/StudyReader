import Foundation

/// The entire new local view is staged before touching the live files. A small journal lets
/// launch finish an interrupted install, including its sync baseline, before loading metadata.
enum SyncInstaller {
    static let targets = ["Collections", "library-organization.json", "sync-state.json"]
    private struct Transaction: Codable { var directory: String; var targets: [String]? }

    static func recover(in root: URL) throws {
        let marker = root.appendingPathComponent(".sync-transaction.json")
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: marker))
        guard transaction.directory.hasPrefix(".sync-install-"),
              UUID(uuidString: String(transaction.directory.dropFirst(".sync-install-".count))) != nil,
              let staging = LibraryDisk.containedURL(root: root, relativePath: transaction.directory) else {
            throw ReaderFailure(message: "本机同步恢复记录无效，原文件已保留。")
        }
        let selected = transaction.targets ?? targets
        guard !selected.isEmpty, Set(selected).isSubset(of: Set(targets)), Set(selected).count == selected.count else {
            throw ReaderFailure(message: "本机同步恢复目标无效。")
        }
        try finish(staging: staging, root: root, targets: selected)
    }

    private static func finish(staging: URL, root: URL, targets: [String]) throws {
        let fm = FileManager.default
        for name in targets {
            let incoming = staging.appendingPathComponent(name)
            let destination = root.appendingPathComponent(name)
            let backup = staging.appendingPathComponent("previous-" + name)
            if fm.fileExists(atPath: incoming.path) {
                if fm.fileExists(atPath: destination.path) {
                    guard !fm.fileExists(atPath: backup.path) else {
                        throw ReaderFailure(message: "同步恢复遇到文件冲突，已保留所有副本。")
                    }
                    try fm.moveItem(at: destination, to: backup)
                }
                try fm.moveItem(at: incoming, to: destination)
            } else if !fm.fileExists(atPath: destination.path) {
                throw ReaderFailure(message: "同步恢复缺少文件，已保留暂存副本。")
            }
        }
        // Remove the journal first. Failure to clean obsolete backups must never replay an
        // old transaction over edits made after this installation.
        try fm.removeItem(at: root.appendingPathComponent(".sync-transaction.json"))
        try? fm.removeItem(at: staging)
    }

    static func install(_ projection: SyncProjection, cache: SyncCache, root: URL, blobs: URL, replaceDocuments: Bool = true) throws -> [LibraryDocument] {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".sync-install-\(UUID().uuidString)", isDirectory: true)
        let collections = staging.appendingPathComponent("Collections", isDirectory: true)
        try fm.createDirectory(at: replaceDocuments ? collections : staging, withIntermediateDirectories: true)
        var journalCommitted = false
        defer { if !journalCommitted { try? fm.removeItem(at: staging) } }
        for (id, article) in projection.articles where replaceDocuments {
            let package = collections.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: package, withIntermediateDirectories: true)
            for file in article.files {
                guard let destination = LibraryDisk.containedURL(root: package, relativePath: file.path) else {
                    throw ReaderFailure(message: "同步文章路径无效，未替换本机资料。")
                }
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let source = blobs.appendingPathComponent(file.blob)
                if LibraryDisk.markdownExtensions.contains((file.path as NSString).pathExtension.lowercased()) {
                    // Markdown remains independently editable. Immutable images share an inode
                    // so a package with many articles doesn't multiply the attachment bytes.
                    try fm.copyItem(at: source, to: destination)
                } else {
                    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: source.path)
                    do { try fm.linkItem(at: source, to: destination) }
                    catch { try fm.copyItem(at: source, to: destination) }
                }
            }
            let manifest = CollectionManifest(id: id, name: article.packageName, importedAt: article.importedAt,
                fingerprint: article.sourceFingerprint, documents: [article.record])
            try SyncFolderIO.encoder.encode(manifest).write(to: package.appendingPathComponent(".reader-collection.json"), options: .atomic)
        }
        try projection.organization.save(to: staging.appendingPathComponent("library-organization.json"))
        try SyncFolderIO.encoder.encode(cache).write(to: staging.appendingPathComponent("sync-state.json"), options: .atomic)
        let marker = root.appendingPathComponent(".sync-transaction.json")
        let selectedTargets = replaceDocuments ? targets : Array(targets.dropFirst())
        try SyncFolderIO.encoder.encode(Transaction(directory: staging.lastPathComponent, targets: selectedTargets)).write(to: marker, options: .atomic)
        journalCommitted = true
        do { try finish(staging: staging, root: root, targets: selectedTargets) }
        catch {
            throw LibraryUpdateFailure(errorDescription: "同步资料已暂存，但本机安装未完成。请重新打开 App 继续恢复。\n\(error.localizedDescription)")
        }
        return try LibraryDisk.loadMetadata(from: root.appendingPathComponent("Collections"))
    }

    static func backupBeforeConnecting(root: URL) throws -> URL {
        let fm = FileManager.default
        let backup = root.appendingPathComponent("Backups/BeforeSync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["Collections", "library-organization.json", "reading-state.json", "sync-state.json"] {
            let source = root.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try fm.copyItem(at: source, to: backup.appendingPathComponent(name)) }
        }
        return backup
    }

    static func restoreAliases(in state: inout LocalReadingState, root: URL) throws {
        let url = root.appendingPathComponent("sync-state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let cache = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: url))
        remap(&state, aliases: cache.aliases)
    }

    static func remap(_ state: inout LocalReadingState, aliases: [String: UUID]) {
        for (key, target) in aliases {
            guard let source = UUID(uuidString: key), source != target else { continue }
            if state.favorites.remove(source) != nil { state.favorites.insert(target) }
            if let position = state.positions.removeValue(forKey: key), state.positions[target.uuidString] == nil { state.positions[target.uuidString] = position }
            if let opened = state.lastOpened.removeValue(forKey: key) {
                state.lastOpened[target.uuidString] = max(opened, state.lastOpened[target.uuidString] ?? .distantPast)
            }
        }
    }
}
