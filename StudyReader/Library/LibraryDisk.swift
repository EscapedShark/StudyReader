import Foundation
import CryptoKit

struct ReaderFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct DocumentRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let relativePath: String
    // Optional fields keep existing imported manifests readable.
    var revision: UUID? = nil
    var usesCustomTitle: Bool? = nil
}

struct CollectionManifest: Codable, Sendable {
    let id: UUID
    let name: String
    let importedAt: Date
    let fingerprint: String
    let documents: [DocumentRecord]
}

struct LibraryDocument: Identifiable, Sendable {
    let record: DocumentRecord
    let collection: CollectionManifest
    let rootURL: URL
    var id: UUID { record.id }
    var title: String { DocumentFileName.title(for: record.relativePath) }
    var fileURL: URL { rootURL.appendingPathComponent(record.relativePath) }
    var subtitle: String { (record.relativePath as NSString).deletingLastPathComponent }
    var baseURL: String {
        var url = URL(string: "reader://library/\(collection.id.uuidString)/")!
        for component in record.relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url.absoluteString
    }
}

enum ImportResult: Sendable { case imported([LibraryDocument]), duplicate }

struct DocumentDeletion: Sendable {
    let collection: CollectionManifest
    let cleanupError: String?
}

enum LibraryDisk {
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let supportedExtensions = markdownExtensions.union(["png", "jpg", "jpeg", "gif", "webp", "svg"])

    static func containedURL(root: URL, relativePath: String) -> URL? {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("\0") else { return nil }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let result = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
        guard result.path.hasPrefix(canonicalRoot.path + "/") else { return nil }
        // Resolving the entire URL is insufficient when its final component does not exist.
        // Reject symbolic links at every ancestor, including an existing linked directory.
        var ancestor = result
        while ancestor.path != canonicalRoot.path {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { return nil }
            ancestor.deleteLastPathComponent()
        }
        return result
    }

    /// Every collection folder carries one small manifest. Duplicate detection only needs those,
    /// so it never re-reads the Markdown of the whole library.
    private static func manifests(in libraryURL: URL) throws -> [(folder: URL, manifest: CollectionManifest)] {
        let fm = FileManager.default
        try fm.createDirectory(at: libraryURL, withIntermediateDirectories: true)
        let folders = try fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var result: [(folder: URL, manifest: CollectionManifest)] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let metadataURL = folder.appendingPathComponent(".reader-collection.json")
            guard fm.fileExists(atPath: metadataURL.path) else { continue }
            result.append((folder, try JSONDecoder().decode(CollectionManifest.self, from: Data(contentsOf: metadataURL))))
        }
        return result
    }

    static func fingerprints(in libraryURL: URL) throws -> Set<String> {
        Set(try manifests(in: libraryURL).map(\.manifest.fingerprint))
    }

    /// The shelf only needs manifests. Body validation and file access happen when it is opened.
    static func loadMetadata(from libraryURL: URL) throws -> [LibraryDocument] {
        var documents: [LibraryDocument] = []
        for (folder, storedManifest) in try manifests(in: libraryURL) {
            for record in storedManifest.documents {
                let path = record.relativePath
                let candidate = folder.appendingPathComponent(path).standardizedFileURL
                guard !path.hasPrefix("/"), !path.contains("\0"), candidate.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
                    throw ReaderFailure(message: "资料路径无效：\(record.relativePath)")
                }
            }
            let manifest = try migrateFileNames(in: storedManifest, root: folder)
            documents.append(contentsOf: manifest.documents.map { LibraryDocument(record: $0, collection: manifest, rootURL: folder) })
        }
        return documents.sorted {
            if $0.collection.importedAt != $1.collection.importedAt { return $0.collection.importedAt > $1.collection.importedAt }
            return $0.record.relativePath.localizedStandardCompare($1.record.relativePath) == .orderedAscending
        }
    }

    static func readMarkdown(for document: LibraryDocument) throws -> String {
        guard let url = containedURL(root: document.rootURL, relativePath: document.record.relativePath) else {
            throw ReaderFailure(message: "资料路径无效：\(document.record.relativePath)")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 5_000_000 else { throw ReaderFailure(message: "这篇 Markdown 超过 5 MB，请拆分后导入。") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func deleteDocument(_ document: LibraryDocument) throws -> DocumentDeletion {
        let manifestURL = document.rootURL.appendingPathComponent(".reader-collection.json")
        let manifest = try JSONDecoder().decode(CollectionManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.id == document.collection.id,
              let record = manifest.documents.first(where: { $0.id == document.id }),
              let fileURL = containedURL(root: document.rootURL, relativePath: record.relativePath) else {
            throw ReaderFailure(message: "文章已发生变化，请重新打开资料库后重试。")
        }
        let fm = FileManager.default
        let fileExists = fm.fileExists(atPath: fileURL.path)
        if fileExists {
            guard try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw ReaderFailure(message: "文章路径不是普通文件，未删除任何内容。")
            }
        }
        // A changed package must no longer block reimporting the original source as a duplicate.
        let fingerprint = SHA256.hash(data: Data("\(manifest.fingerprint):deleted:\(document.id.uuidString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let updated = CollectionManifest(id: manifest.id, name: manifest.name, importedAt: manifest.importedAt,
                                         fingerprint: fingerprint, documents: manifest.documents.filter { $0.id != document.id })
        // The manifest is authoritative. Commit it before removing the copied Markdown so an
        // interrupted deletion never leaves a visible article pointing at a missing file.
        try JSONEncoder().encode(updated).write(to: manifestURL, options: .atomic)
        var cleanupError: String?
        if fileExists {
            do { try fm.removeItem(at: fileURL) }
            catch { cleanupError = "文章已从书架删除，但本地副本未能清理：\(error.localizedDescription)" }
        }
        // Images can be shared by other articles in the package; only remove this Markdown.
        return DocumentDeletion(collection: updated, cleanupError: cleanupError)
    }

    static func importItem(at source: URL, into libraryURL: URL, name: String? = nil, knownFingerprints: Set<String>? = nil) throws -> ImportResult {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let sourceInfo = try source.resourceValues(forKeys: keys)
        guard sourceInfo.isSymbolicLink != true else { throw ReaderFailure(message: "请导入实际文件，暂不导入符号链接。") }
        let isDirectory = sourceInfo.isDirectory == true
        var files: [(path: String, url: URL)] = []
        if isDirectory {
            var enumerationError: Error?
            guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                enumerationError = error
                return false
            }) else { throw ReaderFailure(message: "无法读取这个文件夹。") }
            for case let url as URL in enumerator {
                let info = try url.resourceValues(forKeys: keys)
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true, supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                // Foundation may enumerate /var through its /private/var alias.
                // Enumerator depth gives a relative path without comparing those prefixes.
                let relative = url.pathComponents.suffix(enumerator.level).joined(separator: "/")
                files.append((relative, url))
            }
            if let error = enumerationError { throw error }
        } else {
            guard markdownExtensions.contains(source.pathExtension.lowercased()) else { throw ReaderFailure(message: "请选择 .md、.markdown 文件或资料文件夹。") }
            files = [(source.lastPathComponent, source)]
        }
        files.sort { $0.path < $1.path }
        guard files.contains(where: { markdownExtensions.contains($0.url.pathExtension.lowercased()) }) else {
            throw ReaderFailure(message: "这个文件夹里没有 Markdown 文件。")
        }
        var hasher = SHA256()
        var totalBytes = 0
        for file in files {
            let size = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            totalBytes += size
            let maxSize = markdownExtensions.contains(file.url.pathExtension.lowercased()) ? 5_000_000 : 25_000_000
            guard size <= maxSize, totalBytes <= 200_000_000 else {
                throw ReaderFailure(message: "这批资料较大。原型支持单篇 MD 5 MB、单张图片 25 MB、每批 200 MB，请分批导入。")
            }
            hasher.update(data: Data(file.path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(SHA256.hash(data: try Data(contentsOf: file.url, options: .mappedIfSafe))))
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let existing = try knownFingerprints ?? fingerprints(in: libraryURL)
        if existing.contains(fingerprint) { return .duplicate }

        let collectionID = UUID()
        let staging = libraryURL.appendingPathComponent(".import-\(collectionID.uuidString)")
        let destination = libraryURL.appendingPathComponent(collectionID.uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var records: [DocumentRecord] = []
        for file in files {
            guard let copiedURL = containedURL(root: staging, relativePath: file.path) else { throw ReaderFailure(message: "文件路径超出资料范围。") }
            try fm.createDirectory(at: copiedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file.url, to: copiedURL)
            if markdownExtensions.contains(file.url.pathExtension.lowercased()) {
                guard String(data: try Data(contentsOf: copiedURL), encoding: .utf8) != nil else {
                    throw ReaderFailure(message: "\(file.path) 不是 UTF-8 文本，请在编辑器中以 UTF-8 保存后导入。")
                }
                records.append(DocumentRecord(id: UUID(), title: DocumentFileName.title(for: file.path), relativePath: file.path))
            }
        }
        let manifest = CollectionManifest(id: collectionID, name: name ?? source.deletingPathExtension().lastPathComponent,
                                          importedAt: Date(), fingerprint: fingerprint, documents: records)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(".reader-collection.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        let ordered = records.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return .imported(ordered.map { LibraryDocument(record: $0, collection: manifest, rootURL: destination) })
    }
}
