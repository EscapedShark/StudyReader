import Foundation

struct SyncConnection: Codable, Sendable {
    var libraryID: UUID
    var bookmark: Data
    var folderName: String
}

/// Retain the security scope for the connection's lifetime, including background file work.
final class SyncFolderAccess: NSObject, NSFilePresenter, @unchecked Sendable {
    let url: URL
    let scoped: Bool
    let onChange: @Sendable () -> Void
    private var closed = false
    var presentedItemURL: URL? { url }
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.scoped = url.startAccessingSecurityScopedResource()
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
    }
    func close() {
        guard !closed else { return }
        closed = true
        NSFileCoordinator.removeFilePresenter(self)
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
    deinit { close() }
    func presentedItemDidChange() { onChange() }
    func presentedSubitemDidAppear(at url: URL) { onChange() }
    func presentedSubitemDidChange(at url: URL) { onChange() }
    func presentedItemDidMove(to newURL: URL) { onChange() }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { onChange() }
    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) { onChange(); completionHandler(nil) }
    func accommodatePresentedSubitemDeletion(at url: URL, completionHandler: @escaping (Error?) -> Void) { onChange(); completionHandler(nil) }

    static func bookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    static func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        #if os(macOS)
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }
}

enum SyncFolderIO {
    static let headerName = "StudyReader-library.json"
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func coordinate<T>(reading url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        if let result { return try result.get() }
        throw error ?? ReaderFailure(message: "无法读取所选资料库。") as NSError
    }
    static func coordinate<T>(writing url: URL, _ body: (URL) throws -> T) throws -> T {
        var error: NSError?, result: Result<T, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { coordinatedURL in result = Result { try body(coordinatedURL) } }
        if let result { return try result.get() }
        throw error ?? ReaderFailure(message: "无法写入所选资料库。") as NSError
    }

    static func requestDownload(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw SyncPending.download
        }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: placeholder.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            throw SyncPending.download
        }
    }

    static func read(_ url: URL, maxBytes: Int) throws -> Data {
        try Task.checkCancellation()
        try requestDownload(url)
        return try coordinate(reading: url) { url in
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= maxBytes else {
                throw ReaderFailure(message: "同步文件无效或超过大小限制：\(url.lastPathComponent)")
            }
            let data = try Data(contentsOf: url)
            guard data.count <= maxBytes else { throw ReaderFailure(message: "同步文件超过大小限制。") }
            return data
        }
    }

    /// The caller only writes immutable names. Existing content must match byte-for-byte.
    static func writeNew(_ data: Data, to url: URL) throws {
        try Task.checkCancellation()
        try coordinate(writing: url) { destination in
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == data else { throw ReaderFailure(message: "同步资料中存在内容不同的同名文件，未覆盖原文件。") }
            } else { try data.write(to: destination, options: .atomic) }
        }
    }

    static func child(_ path: String, in root: URL) throws -> URL {
        guard let url = LibraryDisk.containedURL(root: root, relativePath: path) else {
            throw ReaderFailure(message: "同步路径超出所选资料库。")
        }
        return url
    }

    static func connect(at root: URL, create: Bool, localRoot: URL) throws -> SyncLibraryHeader {
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        let local = localRoot.standardizedFileURL.resolvingSymlinksInPath().path
        guard path != local, !path.hasPrefix(local + "/"), !local.hasPrefix(path + "/") else {
            throw ReaderFailure(message: "请选择独立的资料库文件夹，不能选择 App 本机数据目录。")
        }
        guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil else {
            throw ReaderFailure(message: "请选择实际的资料库文件夹。")
        }
        if create {
            return try coordinate(writing: root) { folder in
                let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" }
                guard contents.isEmpty else { throw ReaderFailure(message: "请为新资料库选择一个空文件夹。已有 StudyReader 资料库请使用「连接已有资料库」。") }
                let header = SyncLibraryHeader(id: UUID())
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Changes"), withIntermediateDirectories: false)
                try FileManager.default.createDirectory(at: folder.appendingPathComponent("Files"), withIntermediateDirectories: false)
                try encoder.encode(header).write(to: folder.appendingPathComponent(headerName), options: .atomic)
                return header
            }
        }
        return try header(at: root)
    }

    static func header(at root: URL) throws -> SyncLibraryHeader {
        let url = try child(headerName, in: root)
        let header = try JSONDecoder().decode(SyncLibraryHeader.self, from: read(url, maxBytes: 4096))
        guard header.format == "StudyReader", header.version == 1 else {
            throw ReaderFailure(message: "这个资料库格式暂不受支持，请更新 App 后再连接。")
        }
        return header
    }

    static func eventURLs(at root: URL) throws -> [UUID: URL] {
        let directory = try child("Changes", in: root)
        let urls = try coordinate(reading: directory) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
        var result: [UUID: URL] = [:]
        for url in urls {
            var name = url.lastPathComponent
            if name.hasPrefix("."), name.hasSuffix(".icloud") { name = String(name.dropFirst().dropLast(7)) }
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { continue }
            result[id] = try child("Changes/\(name)", in: root)
        }
        return result
    }

    static func waitingForUpload(_ urls: [URL]) -> Bool {
        urls.contains { url in
            let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey])
            return values?.isUbiquitousItem == true && values?.ubiquitousItemIsUploaded != true
        }
    }
}
