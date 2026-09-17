import Foundation
import CryptoKit

struct ReaderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct DocumentRecord: Codable, Identifiable {
    let id: UUID
    let title: String
    let relativePath: String
}

struct CollectionManifest: Codable {
    let id: UUID
    let name: String
    let importedAt: Date
    let fingerprint: String
    let documents: [DocumentRecord]
}

struct LibraryDocument: Identifiable {
    let record: DocumentRecord
    let collection: CollectionManifest
    let rootURL: URL
    let markdown: String
    var id: UUID { record.id }
    var title: String { record.title }
    var fileURL: URL { rootURL.appendingPathComponent(record.relativePath) }
    var subtitle: String { (record.relativePath as NSString).deletingLastPathComponent }
    /// Search runs over every article on each keystroke, so the two fields are scanned in place
    /// instead of allocating a combined haystack per document per pass.
    func matches(_ search: String) -> Bool {
        search.isEmpty || title.localizedStandardContains(search) || markdown.localizedStandardContains(search)
    }
    var baseURL: String {
        var url = URL(string: "reader://library/\(collection.id.uuidString)/")!
        for component in record.relativePath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url.absoluteString
    }
}

enum ImportResult { case imported(Int), duplicate }

enum LibraryDisk {
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let supportedExtensions = markdownExtensions.union(["png", "jpg", "jpeg", "gif", "webp", "svg"])

    static func title(from markdown: String, fallback: String) -> String {
        var text = markdown.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        if let range = text.range(of: "^---\\r?\\n[\\s\\S]*?\\r?\\n(?:---|\\.\\.\\.)\\s*(?:\\r?\\n|$)", options: .regularExpression) {
            text.removeSubrange(range)
        }
        var fence: String?
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = String(line.prefix(3))
                if fence == marker { fence = nil } else if fence == nil { fence = marker }
            }
            if fence == nil, line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return fallback
    }

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

    static func load(from libraryURL: URL) throws -> [LibraryDocument] {
        var documents: [LibraryDocument] = []
        for (folder, manifest) in try manifests(in: libraryURL) {
            for record in manifest.documents {
                guard let fileURL = containedURL(root: folder, relativePath: record.relativePath) else {
                    throw ReaderFailure(message: "资料路径无效：\(record.relativePath)")
                }
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                documents.append(LibraryDocument(record: record, collection: manifest, rootURL: folder, markdown: content))
            }
        }
        return documents.sorted {
            if $0.collection.importedAt != $1.collection.importedAt { return $0.collection.importedAt > $1.collection.importedAt }
            return $0.record.relativePath.localizedStandardCompare($1.record.relativePath) == .orderedAscending
        }
    }

    static func importItem(at source: URL, into libraryURL: URL, name: String? = nil) throws -> ImportResult {
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
        if try fingerprints(in: libraryURL).contains(fingerprint) { return .duplicate }

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
                guard let content = String(data: try Data(contentsOf: copiedURL), encoding: .utf8) else {
                    throw ReaderFailure(message: "\(file.path) 不是 UTF-8 文本，请在编辑器中以 UTF-8 保存后导入。")
                }
                records.append(DocumentRecord(id: UUID(), title: title(from: content, fallback: file.url.deletingPathExtension().lastPathComponent), relativePath: file.path))
            }
        }
        let manifest = CollectionManifest(id: collectionID, name: name ?? source.deletingPathExtension().lastPathComponent,
                                          importedAt: Date(), fingerprint: fingerprint, documents: records)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent(".reader-collection.json"), options: .atomic)
        try fm.moveItem(at: staging, to: destination)
        return .imported(records.count)
    }
}
