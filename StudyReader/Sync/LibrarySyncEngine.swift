import Foundation

struct SyncExchange: Sendable {
    var projection: SyncProjection
    var waitingForUpload: Bool
}

struct SyncInstallation: Sendable {
    var documents: [LibraryDocument]
    var organization: LibraryOrganization
    var aliases: [String: UUID]
}

/// All hashing, cloud coordination and cache writes run off the UI executor. The store only
/// blocks local edits while capturing a consistent snapshot or installing downloaded files.
actor LibrarySyncEngine {
    let root: URL
    let stateURL: URL
    let blobs: URL
    private var cache: SyncCache
    private var verifiedBlobs = Set<String>()
    private let eventBatchLimit: Int

    init(root: URL, libraryID: UUID, eventBatchLimit: Int = 2_000_000) throws {
        self.root = root
        self.eventBatchLimit = max(1, eventBatchLimit)
        stateURL = root.appendingPathComponent("sync-state.json")
        blobs = root.appendingPathComponent("SyncCache/Files", isDirectory: true)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let stored = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: stateURL))
            guard stored.version == 1 else { throw ReaderFailure(message: "本机同步记录版本不受支持。") }
            cache = stored.libraryID == libraryID ? stored : SyncCache(libraryID: libraryID)
        } else { cache = SyncCache(libraryID: libraryID) }
    }

    func needsBootstrap() -> Bool { !cache.didCaptureLocal }
    private func persist() throws { try SyncFolderIO.encoder.encode(cache).write(to: stateURL, options: .atomic) }

    private func cacheBlob(_ data: Data, extension ext: String) throws -> String {
        let key = SyncModel.digest(data) + "." + ext.lowercased()
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let url = blobs.appendingPathComponent(key)
        if !verifiedBlobs.contains(key) {
            let existing = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            if existing != data {
                try data.write(to: url, options: .atomic)
            }
            verifiedBlobs.insert(key)
        }
        return key
    }

    private func capture(_ document: LibraryDocument) throws -> SyncArticle {
        let fm = FileManager.default
        var paths = [document.record.relativePath]
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: document.rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ReaderFailure(message: "无法读取文章附件。")
        }
        for case let url as URL in enumerator {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if info.isRegularFile == true, LibraryDisk.supportedExtensions.subtracting(LibraryDisk.markdownExtensions).contains(url.pathExtension.lowercased()) {
                paths.append(url.pathComponents.suffix(enumerator.level).joined(separator: "/"))
            }
        }
        if let enumerationError { throw enumerationError }
        var files: [SyncFile] = []
        var total = 0
        for path in paths.sorted() {
            guard SyncModel.validPath(path), let url = LibraryDisk.containedURL(root: document.rootURL, relativePath: path) else {
                throw ReaderFailure(message: "文章或附件路径不能同步：\(path)")
            }
            let maxSize = LibraryDisk.markdownExtensions.contains(url.pathExtension.lowercased()) ? 5_000_000 : 25_000_000
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= maxSize else {
                throw ReaderFailure(message: "文章或附件超过同步大小限制。")
            }
            let data = try Data(contentsOf: url)
            total += data.count
            guard data.count <= maxSize, total <= 200_000_000 else { throw ReaderFailure(message: "文章及附件超过同步大小限制。") }
            files.append(SyncFile(path: path, blob: try cacheBlob(data, extension: url.pathExtension), bytes: data.count))
        }
        return SyncArticle(record: document.record, packageName: document.collection.name,
                           importedAt: document.collection.importedAt, sourceFingerprint: document.collection.fingerprint, files: files)
    }

    /// Commit the local outbox and its baseline in one atomic JSON write before any cloud I/O.
    /// A crash/offline device can retry without inferring removals from missing remote files.
    func prepare(documents: [LibraryDocument], organization: LibraryOrganization) throws {
        let currentRecords = Dictionary(uniqueKeysWithValues: documents.map { ($0.id.uuidString, $0.record) })
        if cache.didCaptureLocal, currentRecords == cache.baseline.records, organization == cache.baseline.organization { return }
        var next = cache
        guard next.clock < UInt64.max - 1 else { throw ReaderFailure(message: "同步版本计数已超出支持范围。") }
        var event = SyncEvent(id: UUID(), device: next.deviceID, clock: next.clock + 1)
        let existingProjection = try SyncModel.project(cache.events)
        var incoming: [UUID: SyncArticle] = [:]
        for document in documents where cache.baseline.records[document.id.uuidString] != document.record {
            incoming[document.id] = try capture(document)
        }
        var effectiveOrganization = organization
        if !next.didCaptureLocal, !existingProjection.articles.isEmpty {
            // Two fresh installs contain the same sample package with different UUIDs. Match
            // only identical imported content, and retain local progress through the ID mapping.
            for (id, article) in incoming {
                if let match = existingProjection.articles.values.sorted(by: { $0.record.id.uuidString < $1.record.id.uuidString }).first(where: {
                    $0.sourceFingerprint == article.sourceFingerprint && $0.record.relativePath == article.record.relativePath && $0.files == article.files
                }) {
                    next.aliases[id.uuidString] = match.record.id
                    incoming.removeValue(forKey: id)
                }
            }
            effectiveOrganization = existingProjection.organization
            let newIDs = Set(incoming.keys)
            for folder in organization.folders {
                let ids = folder.documentIDs.filter { newIDs.contains($0) }
                let wasDuplicatePackage = !folder.documentIDs.isEmpty && ids.isEmpty && folder.documentIDs.allSatisfy { next.aliases[$0.uuidString] != nil }
                guard !wasDuplicatePackage else { continue }
                if let index = effectiveOrganization.folders.firstIndex(where: { $0.id == folder.id }) {
                    effectiveOrganization.folders[index].documentIDs.append(contentsOf: ids)
                } else {
                    effectiveOrganization.folders.append(LibraryFolder(id: folder.id, name: folder.name, documentIDs: ids))
                }
            }
            effectiveOrganization.documentOrder.append(contentsOf: organization.documentOrder.filter { newIDs.contains($0) })
        }
        for (id, article) in incoming.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            event.articles.append(.init(id: id, parents: next.baseline.heads[id.uuidString] ?? [], article: article))
            next.baseline.heads[id.uuidString] = [event.id]
        }
        let currentIDs = Set(documents.map { $0.id.uuidString })
        for key in next.baseline.records.keys.sorted() where !currentIDs.contains(key) && next.aliases[key] == nil {
            guard let id = UUID(uuidString: key) else { continue }
            event.articles.append(.init(id: id, parents: next.baseline.heads[key] ?? [], article: nil))
            next.baseline.heads[key] = [event.id]
        }
        let baselineOrganization = !next.didCaptureLocal ? existingProjection.organization : next.baseline.organization
        let oldFolders = Dictionary(uniqueKeysWithValues: baselineOrganization.folders.map { ($0.id, $0) })
        let oldMemberships = Dictionary(baselineOrganization.folders.flatMap { folder in folder.documentIDs.map { ($0, folder.id) } }, uniquingKeysWith: { first, _ in first })
        for folder in effectiveOrganization.folders {
            if oldFolders[folder.id]?.name != folder.name { event.folderNames[folder.id.uuidString] = folder.name }
            if oldFolders[folder.id]?.documentIDs != folder.documentIDs { event.folderOrders[folder.id.uuidString] = folder.documentIDs }
            for id in folder.documentIDs where oldMemberships[id] != folder.id { event.memberships[id.uuidString] = folder.id }
        }
        if baselineOrganization.folders.map(\.id) != effectiveOrganization.folders.map(\.id) { event.folderOrder = effectiveOrganization.folders.map(\.id) }
        if baselineOrganization.documentOrder != effectiveOrganization.documentOrder { event.documentOrder = effectiveOrganization.documentOrder }
        next.baseline.records = currentRecords
        next.baseline.organization = organization
        next.didCaptureLocal = true
        let hasChanges = !event.articles.isEmpty || !event.folderNames.isEmpty || !event.memberships.isEmpty ||
            !event.folderOrders.isEmpty || event.folderOrder != nil || event.documentOrder != nil
        if hasChanges {
            // Bound individual journal files. Large imports with many shared images must not
            // produce a single record that the receiving device's size limit rejects.
            let changes = event.articles
            event.articles = []
            var batches: [SyncEvent] = []
            var estimatedBytes = try SyncFolderIO.encoder.encode(event).count
            for change in changes {
                let size = try SyncFolderIO.encoder.encode(change).count
                if !event.articles.isEmpty, estimatedBytes + size > eventBatchLimit {
                    batches.append(event)
                    guard event.clock < UInt64.max - 1 else { throw ReaderFailure(message: "同步版本计数已超出支持范围。") }
                    event = SyncEvent(id: UUID(), device: next.deviceID, clock: event.clock + 1)
                    estimatedBytes = 0
                }
                event.articles.append(change)
                estimatedBytes += size
                next.baseline.heads[change.id.uuidString] = [event.id]
            }
            batches.append(event)
            for batch in batches {
                try SyncModel.validate(batch)
                guard try SyncFolderIO.encoder.encode(batch).count <= 20_000_000 else {
                    throw ReaderFailure(message: "单篇资料的附件清单过大，请拆分附件后再同步。")
                }
            }
            next.events.append(contentsOf: batches)
            next.clock = event.clock
        }
        try SyncFolderIO.encoder.encode(next).write(to: stateURL, options: .atomic)
        cache = next
    }

    func exchange(with folder: URL) throws -> SyncExchange {
        guard try SyncFolderIO.header(at: folder).id == cache.libraryID else {
            throw ReaderFailure(message: "所选文件夹已变成另一个资料库，请重新连接。")
        }
        let remote = try SyncFolderIO.eventURLs(at: folder)
        let known = Set(cache.events.map(\.id))
        var waiting = false
        for (id, url) in remote.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where !known.contains(id) {
            do {
                let event = try JSONDecoder().decode(SyncEvent.self, from: SyncFolderIO.read(url, maxBytes: 20_000_000))
                guard event.id == id else { throw ReaderFailure(message: "同步记录名称与内容不一致。") }
                try SyncModel.validate(event)
                cache.events.append(event)
                cache.clock = max(cache.clock, event.clock)
            } catch is SyncPending { waiting = true }
        }
        if cache.events.count != known.count { try persist() }
        // Persist remote metadata even when its body/parent is still downloading. Never
        // install a partial library or prune reading state on the basis of those absences.
        var projection: SyncProjection?
        do {
            let result = try SyncModel.project(cache.events)
            if !result.recoveries.isEmpty {
                cache.events.append(contentsOf: result.recoveries)
                try persist()
            }
            projection = result
        } catch is SyncPending { waiting = true }
        if let projection {
            let files = Dictionary(projection.articles.values.flatMap(\.files).map { ($0.blob, $0) }, uniquingKeysWith: { first, _ in first })
            for file in files.values.sorted(by: { $0.blob < $1.blob }) {
                do { try download(file, from: folder) }
                catch is SyncPending { waiting = true }
            }
        }
        var written: [URL] = []
        for event in cache.events.sorted(by: SyncEvent.precedes) where remote[event.id] == nil {
            var eventReady = true
            for file in Dictionary(event.articles.compactMap(\.article).flatMap(\.files).map { ($0.blob, $0) }, uniquingKeysWith: { first, _ in first }).values {
                let source = blobs.appendingPathComponent(file.blob)
                if !FileManager.default.fileExists(atPath: source.path) { eventReady = false; waiting = true; continue }
                let target = try SyncFolderIO.child("Files/\(file.blob)", in: folder)
                try SyncFolderIO.requestDownload(target)
                let data = try Data(contentsOf: source)
                guard data.count == file.bytes, SyncModel.digest(data) == (file.blob as NSString).deletingPathExtension else {
                    throw ReaderFailure(message: "本机同步缓存损坏，未上传。")
                }
                try SyncFolderIO.writeNew(data, to: target)
                written.append(target)
            }
            guard eventReady else { continue }
            let target = try SyncFolderIO.child("Changes/\(event.id.uuidString).json", in: folder)
            try SyncFolderIO.writeNew(SyncFolderIO.encoder.encode(event), to: target)
            written.append(target)
        }
        guard !waiting, let projection else { throw SyncPending.download }
        // Include our earlier queued journal files; a successful file write is not proof that
        // iCloud has finished sending bytes to Apple's servers.
        written.append(contentsOf: cache.events.filter { $0.device == cache.deviceID }.compactMap { remote[$0.id] })
        return SyncExchange(projection: projection, waitingForUpload: SyncFolderIO.waitingForUpload(written))
    }

    private func download(_ file: SyncFile, from folder: URL) throws {
        guard !verifiedBlobs.contains(file.blob) else { return }
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let local = blobs.appendingPathComponent(file.blob)
        let hash = (file.blob as NSString).deletingPathExtension
        if let data = try? Data(contentsOf: local), data.count == file.bytes, SyncModel.digest(data) == hash {
            verifiedBlobs.insert(file.blob)
            return
        }
        let url = try SyncFolderIO.child("Files/\(file.blob)", in: folder)
        let data: Data
        do { data = try SyncFolderIO.read(url, maxBytes: file.bytes) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { throw SyncPending.download }
        guard data.count == file.bytes, SyncModel.digest(data) == hash else {
            throw ReaderFailure(message: "下载的资料校验未通过，本机原文已保留。")
        }
        try data.write(to: local, options: .atomic)
        verifiedBlobs.insert(file.blob)
    }

    func install(_ projection: SyncProjection, documents: [LibraryDocument], organization: LibraryOrganization) throws -> SyncInstallation? {
        let records = Dictionary(uniqueKeysWithValues: documents.map { ($0.id.uuidString, $0.record) })
        let nextBaseline = projection.baseline
        var next = cache
        next.baseline = nextBaseline
        let aliases = next.aliases
        guard records != nextBaseline.records || organization != projection.organization else {
            if cache.baseline.records != nextBaseline.records || cache.baseline.heads != nextBaseline.heads || cache.baseline.organization != nextBaseline.organization {
                try SyncFolderIO.encoder.encode(next).write(to: stateURL, options: .atomic)
            }
            cache = next
            return nil
        }
        let installed = try SyncInstaller.install(projection, cache: next, root: root, blobs: blobs,
                                                  replaceDocuments: records != nextBaseline.records)
        cache = next
        return SyncInstallation(documents: installed, organization: projection.organization, aliases: aliases)
    }
}
