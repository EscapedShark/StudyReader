import Foundation
import CryptoKit

/// A failed rollback is different from a rejected write: stop further changes until reload.
struct LibraryUpdateFailure: LocalizedError, Sendable {
    let errorDescription: String?
}

extension LibraryDisk {
    static func saveMarkdown(_ markdown: String, for document: LibraryDocument,
                             originalMarkdown: String) throws -> CollectionManifest {
        let (manifest, fileURL, manifestURL) = try editableDocument(document)
        let bytes = Data(markdown.utf8)
        guard bytes.count <= 5_000_000 else { throw ReaderFailure(message: "文章超过 5 MB，请缩短后再保存。") }
        let original = try Data(contentsOf: fileURL)
        guard String(data: original, encoding: .utf8) == originalMarkdown else {
            throw ReaderFailure(message: "文章已在其他地方修改。请先复制保留这份草稿，重新打开 App 后再修改。")
        }
        guard bytes != original else { return manifest }
        let title = DocumentFileName.title(for: document.record.relativePath)
        let record = DocumentRecord(id: document.id, title: title, relativePath: document.record.relativePath,
                                    revision: UUID())
        let updated = replacing(record, in: manifest)
        // Atomic body replacement prevents truncated Markdown. If metadata cannot commit,
        // restore the exact original bytes before reporting a failed save to the editor.
        try bytes.write(to: fileURL, options: .atomic)
        try commit(updated, to: manifestURL) { try original.write(to: fileURL, options: .atomic) }
        return updated
    }

    static func renameDocument(_ document: LibraryDocument, to name: String) throws -> CollectionManifest {
        let (manifest, originalURL, manifestURL) = try editableDocument(document)
        let filename = try DocumentFileName.renamedFileName(name, originalExtension: originalURL.pathExtension)
        guard filename != originalURL.lastPathComponent else { return manifest }
        let directory = (document.record.relativePath as NSString).deletingLastPathComponent
        let relativePath = directory.isEmpty ? filename : (directory as NSString).appendingPathComponent(filename)
        guard let destination = containedURL(root: document.rootURL, relativePath: relativePath) else {
            throw ReaderFailure(message: "文件名或目标路径无效，未修改文件。")
        }
        let fm = FileManager.default
        // Reject real files and manifest entries, including case variants on a case-sensitive disk.
        // Other import directories may legitimately contain the same basename.
        let siblings = try fm.contentsOfDirectory(atPath: originalURL.deletingLastPathComponent().path)
        guard !siblings.contains(where: { $0 != originalURL.lastPathComponent && $0.caseInsensitiveCompare(filename) == .orderedSame }),
              !manifest.documents.contains(where: { $0.id != document.id && $0.relativePath.caseInsensitiveCompare(relativePath) == .orderedSame }) else {
            throw ReaderFailure(message: "同一导入目录里已经有同名文件，请换一个名称。")
        }
        let record = DocumentRecord(id: document.id, title: DocumentFileName.title(for: filename), relativePath: relativePath, revision: UUID())
        let updated = replacing(record, in: manifest)
        // Use an intermediate path for case-only renames on case-insensitive volumes. A failed
        // metadata write moves the exact same file back; no Markdown bytes are read or rewritten.
        try moveForRename(from: originalURL, to: destination)
        try commit(updated, to: manifestURL) { try moveForRename(from: destination, to: originalURL) }
        return updated
    }

    private static func moveForRename(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard source.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame else {
            try fm.moveItem(at: source, to: destination)
            return
        }
        let temporary = source.deletingLastPathComponent().appendingPathComponent(".reader-rename-\(UUID().uuidString)")
        try fm.moveItem(at: source, to: temporary)
        do { try fm.moveItem(at: temporary, to: destination) }
        catch {
            let moveError = error
            do { try fm.moveItem(at: temporary, to: source) }
            catch { throw LibraryUpdateFailure(errorDescription: "重命名失败，恢复原路径也失败了。请重新打开 App 检查资料。\n\(moveError.localizedDescription)\n\(error.localizedDescription)") }
            throw moveError
        }
    }

    /// Repair cached titles using paths only. Older heading-based titles and aliases no longer
    /// influence the shelf; migration never reads or edits article content or changes identity.
    static func migrateFileNames(in manifest: CollectionManifest, root: URL) throws -> CollectionManifest {
        let records = manifest.documents.map { record -> DocumentRecord in
            DocumentRecord(id: record.id, title: DocumentFileName.title(for: record.relativePath),
                           relativePath: record.relativePath, revision: record.revision)
        }
        guard records != manifest.documents else { return manifest }
        guard let url = containedURL(root: root, relativePath: ".reader-collection.json") else { throw ReaderFailure(message: "资料库路径无效。") }
        let updated = CollectionManifest(id: manifest.id, name: manifest.name, importedAt: manifest.importedAt,
                                         fingerprint: manifest.fingerprint, documents: records)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        return updated
    }

    private static func editableDocument(_ document: LibraryDocument) throws -> (CollectionManifest, URL, URL) {
        guard let manifestURL = containedURL(root: document.rootURL, relativePath: ".reader-collection.json") else {
            throw ReaderFailure(message: "资料库路径无效，未修改文件。")
        }
        let manifest = try JSONDecoder().decode(CollectionManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.id == document.collection.id,
              manifest.documents.first(where: { $0.id == document.id }) == document.record else {
            throw ReaderFailure(message: "文章已发生变化。请先保留草稿，重新打开后再试。")
        }
        guard let fileURL = containedURL(root: document.rootURL, relativePath: document.record.relativePath),
              try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ReaderFailure(message: "文章文件无效，未修改任何内容。")
        }
        return (manifest, fileURL, manifestURL)
    }

    private static func replacing(_ record: DocumentRecord, in manifest: CollectionManifest) -> CollectionManifest {
        let fingerprint = SHA256.hash(data: Data("\(manifest.fingerprint):updated:\(record.id):\(record.revision?.uuidString ?? "")".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return CollectionManifest(id: manifest.id, name: manifest.name, importedAt: manifest.importedAt,
                                  fingerprint: fingerprint, documents: manifest.documents.map { $0.id == record.id ? record : $0 })
    }

    private static func commit(_ manifest: CollectionManifest, to url: URL, rollback: () throws -> Void) throws {
        do { try JSONEncoder().encode(manifest).write(to: url, options: .atomic) }
        catch {
            let writeError = error
            do { try rollback() }
            catch {
                throw LibraryUpdateFailure(errorDescription: "保存未能完成，恢复原文件也失败了。请先复制保留草稿，再重新打开 App 检查文章。\n\(writeError.localizedDescription)\n\(error.localizedDescription)")
            }
            throw ReaderFailure(message: "未能保存，已恢复原文件。\n\(writeError.localizedDescription)")
        }
    }
}
