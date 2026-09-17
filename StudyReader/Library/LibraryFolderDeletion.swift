import Foundation

/// Commit all affected package manifests and the folder list together before removing copies.
/// A small write-ahead record recovers an interrupted deletion without copying article bodies.
enum LibraryFolderDeletion {
    struct Replacement: Codable {
        var path: String
        var before: Data
        var after: Data
    }
    struct Transaction: Codable {
        var phase = "applying"
        var replacements: [Replacement]
        var cleanup: [String]
    }
    struct Result: Sendable {
        var collections: [UUID: CollectionManifest]
        var cleanupError: String?
    }
    static let journalName = ".folder-deletion.json"

    private static func target(_ path: String, root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path == "library-organization.json" ||
                (parts.count >= 2 && parts[0] == "Collections" && parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })),
              let url = LibraryDisk.containedURL(root: root, relativePath: path) else {
            throw ReaderFailure(message: "资料夹删除记录中的路径无效，已暂停删除。")
        }
        return url
    }

    private static func persist(_ transaction: Transaction, root: URL) throws {
        try JSONEncoder().encode(transaction).write(to: root.appendingPathComponent(journalName), options: .atomic)
    }

    static func recover(in root: URL) throws {
        let journal = root.appendingPathComponent(journalName)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        var transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: journal))
        guard ["applying", "committed", "rollback"].contains(transaction.phase) else {
            throw ReaderFailure(message: "无法识别资料夹删除记录。")
        }
        // Validate every path before touching the first file.
        for replacement in transaction.replacements { _ = try target(replacement.path, root: root) }
        for path in transaction.cleanup {
            guard path.hasPrefix("Collections/") else { throw ReaderFailure(message: "资料夹清理路径无效。") }
            _ = try target(path, root: root)
        }
        if transaction.phase != "committed" {
            for replacement in transaction.replacements {
                let data = transaction.phase == "rollback" ? replacement.before : replacement.after
                try data.write(to: target(replacement.path, root: root), options: .atomic)
            }
            if transaction.phase == "rollback" { try FileManager.default.removeItem(at: journal); return }
            transaction.phase = "committed"
            try persist(transaction, root: root)
        }
        _ = try cleanup(transaction, root: root)
    }

    private static func cleanup(_ transaction: Transaction, root: URL) throws -> String? {
        var errors: [String] = []
        for path in transaction.cleanup {
            let url = try target(path, root: root)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { errors.append(error.localizedDescription) }
            }
        }
        // The manifests already hide deleted articles even if unused copies cannot be removed.
        try FileManager.default.removeItem(at: root.appendingPathComponent(journalName))
        return errors.isEmpty ? nil : "资料夹已从书架删除，但部分本机副本未能清理：\n" + errors.joined(separator: "\n")
    }

    static func delete(documents: [LibraryDocument], organization: LibraryOrganization, root: URL) throws -> Result {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(journalName).path) else {
            throw LibraryUpdateFailure(errorDescription: "上次资料夹删除尚未完成，请重新打开 App 后重试。")
        }
        let fm = FileManager.default
        var replacements: [Replacement] = [], cleanupPaths: [String] = []
        var collections: [UUID: CollectionManifest] = [:]
        let rootPath = root.standardizedFileURL.path + "/"
        for (package, selected) in Dictionary(grouping: documents, by: \.rootURL).sorted(by: { $0.key.path < $1.key.path }) {
            guard package.standardizedFileURL.path.hasPrefix(rootPath) else { throw ReaderFailure(message: "文章不在本机资料库中。") }
            let packagePath = String(package.standardizedFileURL.path.dropFirst(rootPath.count))
            let manifestPath = packagePath + "/.reader-collection.json"
            let manifestURL = try target(manifestPath, root: root)
            let before = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(CollectionManifest.self, from: before)
            let ids = Set(selected.map(\.id))
            for document in selected {
                guard manifest.id == document.collection.id, manifest.documents.contains(document.record),
                      let file = LibraryDisk.containedURL(root: package, relativePath: document.record.relativePath) else {
                    throw ReaderFailure(message: "资料夹中的文章已发生变化，请重新确认后删除。")
                }
                if fm.fileExists(atPath: file.path), try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true {
                    throw ReaderFailure(message: "文章路径不是普通文件，未删除任何内容。")
                }
            }
            let updated = CollectionManifest(id: manifest.id, name: manifest.name, importedAt: manifest.importedAt,
                fingerprint: SyncModel.digest(Data("\(manifest.fingerprint):deleted:\(ids.map(\.uuidString).sorted().joined(separator: ","))".utf8)),
                documents: manifest.documents.filter { !ids.contains($0.id) })
            collections[updated.id] = updated
            replacements.append(Replacement(path: manifestPath, before: before, after: try JSONEncoder().encode(updated)))
            // A whole unused package may be removed, but shared packages retain their images.
            if updated.documents.isEmpty { cleanupPaths.append(packagePath) }
            else { cleanupPaths.append(contentsOf: selected.map { packagePath + "/" + $0.record.relativePath }) }
        }
        let organizationPath = "library-organization.json"
        replacements.append(Replacement(path: organizationPath, before: try Data(contentsOf: target(organizationPath, root: root)),
                                        after: try JSONEncoder().encode(organization)))
        var transaction = Transaction(replacements: replacements, cleanup: cleanupPaths)
        try persist(transaction, root: root)
        var written: [Replacement] = []
        do {
            for replacement in replacements {
                try replacement.after.write(to: target(replacement.path, root: root), options: .atomic)
                written.append(replacement)
            }
            transaction.phase = "committed"
            try persist(transaction, root: root)
        } catch {
            let originalError = error
            do {
                transaction.phase = "rollback"
                try persist(transaction, root: root)
                for replacement in written.reversed() { try replacement.before.write(to: target(replacement.path, root: root), options: .atomic) }
                try fm.removeItem(at: root.appendingPathComponent(journalName))
            } catch {
                throw LibraryUpdateFailure(errorDescription: "资料夹删除未能完成，已保留恢复记录并暂停写入。请重新打开 App。\n\(error.localizedDescription)")
            }
            throw originalError
        }
        do { return Result(collections: collections, cleanupError: try cleanup(transaction, root: root)) }
        catch { throw LibraryUpdateFailure(errorDescription: "资料夹删除已提交，但清理尚未完成，请重新打开 App。\n\(error.localizedDescription)") }
    }
}
