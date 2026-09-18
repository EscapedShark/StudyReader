import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A portable directory: original Markdown and assets, plus a small, optional ordering manifest.
/// Each source collection has its own namespace, so identical relative image names never collide.
struct LibraryPackageManifest: Codable, Equatable, Sendable {
    static let filename = "StudyReader-package.json"
    var version = 1
    var name: String
    var documentPaths: [String]

    static func read(from root: URL) throws -> Self? {
        let candidate = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        guard let url = LibraryDisk.containedURL(root: root, relativePath: filename) else {
            throw ReaderFailure(message: "资料包清单路径无效。")
        }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 2_000_000 else {
            throw ReaderFailure(message: "资料包清单无效或过大。")
        }
        let result = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard result.version == 1, !result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.name.count <= 100, result.name.rangeOfCharacter(from: .controlCharacters) == nil,
              Set(result.documentPaths).count == result.documentPaths.count,
              result.documentPaths.allSatisfy({ SyncModel.validPath($0) && LibraryDisk.markdownExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) else {
            throw ReaderFailure(message: "资料包格式不受支持或清单无效。")
        }
        return result
    }
}

struct PreparedLibraryPackage: Sendable {
    let name: String
    let files: [String: Data]

    func fileWrapper() -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let parts = path.split(separator: "/").map(String.init)
            var parent = root
            for name in parts.dropLast() {
                if let directory = parent.fileWrappers?[name] { parent = directory }
                else {
                    let directory = FileWrapper(directoryWithFileWrappers: [:])
                    directory.preferredFilename = name
                    parent.addFileWrapper(directory)
                    parent = directory
                }
            }
            parent.addRegularFile(withContents: data, preferredFilename: parts.last!)
        }
        return root
    }
}

enum LibraryPackage {
    static func prepare(documents: [LibraryDocument], name: String) throws -> PreparedLibraryPackage {
        let fm = FileManager.default
        var files: [String: Data] = [:]
        var totalBytes = 0
        func add(path: String, url: URL, limit: Int) throws {
            try Task.checkCancellation()
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= limit else {
                throw ReaderFailure(message: "资料包中的文件无法读取或超过大小限制：\(url.lastPathComponent)")
            }
            let data = try Data(contentsOf: url)
            totalBytes += data.count
            guard data.count <= limit, totalBytes <= 200_000_000 else {
                throw ReaderFailure(message: "资料包超过 200 MB，请把资料分到较小的资料夹后分别导出。")
            }
            files[path] = data
        }
        func prefix(_ document: LibraryDocument) -> String { "资料/\(document.collection.id.uuidString)" }
        var paths: [String] = []
        var seenCollections = Set<UUID>()
        for document in documents {
            guard let body = LibraryDisk.containedURL(root: document.rootURL, relativePath: document.record.relativePath) else {
                throw ReaderFailure(message: "文章路径无效，未导出资料包。")
            }
            let path = prefix(document) + "/" + document.record.relativePath
            try add(path: path, url: body, limit: 5_000_000)
            paths.append(path)
            guard seenCollections.insert(document.collection.id).inserted else { continue }
            var enumerationError: Error?
            guard let walker = fm.enumerator(at: document.rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw ReaderFailure(message: "无法读取文章附件，未导出资料包。")
            }
            for case let url as URL in walker {
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isSymbolicLink != true else { throw ReaderFailure(message: "资料中包含符号链接，请先恢复原始附件。") }
                guard info.isRegularFile == true,
                      LibraryDisk.supportedExtensions.subtracting(LibraryDisk.markdownExtensions).contains(url.pathExtension.lowercased()) else { continue }
                let relative = url.pathComponents.suffix(walker.level).joined(separator: "/")
                guard let contained = LibraryDisk.containedURL(root: document.rootURL, relativePath: relative) else {
                    throw ReaderFailure(message: "附件路径超出资料范围。")
                }
                try add(path: prefix(document) + "/" + relative, url: contained, limit: 25_000_000)
            }
            if let enumerationError { throw enumerationError }
        }
        let manifest = LibraryPackageManifest(name: String(name.prefix(100)), documentPaths: paths)
        files[LibraryPackageManifest.filename] = try SyncFolderIO.encoder.encode(manifest)
        let filename = name.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_")
        return PreparedLibraryPackage(name: String(filename.prefix(100)) + " 资料包", files: files)
    }
}

struct LibraryExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .folder] }
    var markdown: String?
    var package: PreparedLibraryPackage?
    init(markdown: String) { self.markdown = markdown }
    init(package: PreparedLibraryPackage) { self.package = package }
    init(configuration: ReadConfiguration) throws {
        throw ReaderFailure(message: "请使用「导入资料文件夹／资料包」打开备份。")
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        if let package { return package.fileWrapper() }
        return FileWrapper(regularFileWithContents: Data((markdown ?? "").utf8))
    }
}
