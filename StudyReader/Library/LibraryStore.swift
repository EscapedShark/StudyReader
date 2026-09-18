import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ReadingPosition: Codable, Equatable, Sendable {
    var anchor: String
    var excerpt: String
    var offset: Double
    var progress: Double
}

struct LocalReadingState: Codable, Equatable, Sendable {
    var version = 2
    var favorites: Set<UUID> = []
    var positions: [String: ReadingPosition] = [:]
    var lastOpened: [String: Date] = [:]
    var readingDeviceID = UUID()
    var progressUpdates: [String: ReadingProgressUpdate] = [:]
    var favoriteUpdates: [String: FavoriteUpdate] = [:]

    init(favorites: Set<UUID> = []) {
        self.favorites = favorites
        favoriteUpdates = Dictionary(uniqueKeysWithValues: favorites.map {
            ($0.uuidString, FavoriteUpdate(device: readingDeviceID, updatedAt: .distantPast, isFavorite: true))
        })
    }
    private enum CodingKeys: String, CodingKey { case version, favorites, positions, lastOpened, readingDeviceID, progressUpdates, favoriteUpdates }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 0
        favorites = try values.decodeIfPresent(Set<UUID>.self, forKey: .favorites) ?? []
        positions = try values.decodeIfPresent([String: ReadingPosition].self, forKey: .positions) ?? [:]
        lastOpened = try values.decodeIfPresent([String: Date].self, forKey: .lastOpened) ?? [:]
        readingDeviceID = try values.decodeIfPresent(UUID.self, forKey: .readingDeviceID) ?? UUID()
        progressUpdates = try values.decodeIfPresent([String: ReadingProgressUpdate].self, forKey: .progressUpdates) ?? [:]
        favoriteUpdates = try values.decodeIfPresent([String: FavoriteUpdate].self, forKey: .favoriteUpdates) ?? [:]
        // Legacy favorites have no action time. They must never override a newer removal.
        for id in favorites where favoriteUpdates[id.uuidString] == nil {
            favoriteUpdates[id.uuidString] = FavoriteUpdate(device: readingDeviceID, updatedAt: .distantPast, isFavorite: true)
        }
        // Existing local positions keep their historical time; connecting is not new reading.
        for (key, position) in positions where progressUpdates[key] == nil {
            progressUpdates[key] = ReadingProgressUpdate(device: readingDeviceID, updatedAt: lastOpened[key] ?? .distantPast, position: position)
        }
    }
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = []
    @Published private(set) var organization = LibraryOrganization()
    @Published private(set) var isLoading = true
    /// Reading state is not `@Published`: scroll saves arrive several times a second and most of
    /// them change nothing the shelf draws. Notifications are sent explicitly instead.
    private(set) var state = LocalReadingState()
    @Published var isImporting = false
    @Published private(set) var isExporting = false
    @Published private(set) var isDeleting = false
    @Published private(set) var isUpdating = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published private(set) var syncConnection: SyncConnection?
    @Published private(set) var isSyncing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var syncStatus = "未连接资料库"
    @Published private(set) var syncIssue: String?
    @Published private(set) var lastSyncCheck: Date?
    private var isSyncInstalling = false
    private var syncEngine: LibrarySyncEngine?
    private var syncAccess: SyncFolderAccess?
    private var progressRedraw: DispatchWorkItem?
    private var lastProgressRedraw = Date.distantPast
    private var syncDebounce: Task<Void, Never>?
    private var syncPoll: Task<Void, Never>?
    private var syncRequested = false
    private var syncSceneActive = true
    private var progressObservedAt: [String: Date] = [:]
    #if os(iOS)
    private var backgroundSync: Task<Void, Never>?
    private var backgroundActivity: UIBackgroundTaskIdentifier = .invalid
    private var backgroundSyncID: UUID?
    #endif
    private(set) var isReadOnly = false
    let libraryURL: URL
    let content = LibraryContent()
    let searchEngine = LibrarySearchEngine()
    let attachments = LibraryImageSizes()
    private let stateURL: URL
    private let organizationURL: URL
    private var pendingSave: DispatchWorkItem?
    private var hasLoaded = false
    private let rootURL: URL
    private let seedSamples: Bool
    private let automaticSync: Bool
    private var loadTask: Task<Snapshot, Error>?
    private struct Snapshot: Sendable {
        var documents: [LibraryDocument]
        var organization: LibraryOrganization
        var state: LocalReadingState
        var needsStateSave: Bool
    }
    private let stateWriter: ReadingStateWriter
    private var stateRevision: UInt64 = 0
    private var savedStateRevision: UInt64 = 0
    private var pendingWrite: (revision: UInt64, task: Task<Bool, Never>)?
    #if os(iOS)
    private var lifecycleSave: Task<Void, Never>?
    private var lifecycleSaveID: UUID?
    private var lifecycleActivity: UIBackgroundTaskIdentifier = .invalid
    #endif

    // Derived views of the library. Rebuilt only when documents or folders change, because the
    // shelf reads them on every render pass and the reader publishes while scrolling.
    private(set) var revision = 0
    private(set) var contentRevision = 0
    private var documentIndex: [UUID: LibraryDocument] = [:]
    private var folderByFilter: [String: LibraryFolder] = [:]
    private var folderOrderByID: [UUID: [UUID]] = [:]
    private var folderNameByDocument: [UUID: String] = [:]
    private var cachedRoots: [String: URL] = [:]
    private struct VisibleKey: Equatable { var revision: Int; var filter: String?; var searchToken: UUID? }
    private var visibleCache: (key: VisibleKey, value: [LibraryDocument])?

    init(rootURL: URL? = nil, seedSamples: Bool = true, automaticSync: Bool = true, stateWriter: ReadingStateWriter = ReadingStateWriter()) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudyReader", isDirectory: true)
        self.rootURL = root
        self.stateWriter = stateWriter
        self.seedSamples = seedSamples
        self.automaticSync = automaticSync
        libraryURL = root.appendingPathComponent("Collections", isDirectory: true)
        stateURL = root.appendingPathComponent("reading-state.json")
        organizationURL = root.appendingPathComponent("library-organization.json")
    }

    /// No disk I/O in init: all windows share one initial metadata load.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        let task: Task<Snapshot, Error>
        if let existing = loadTask { task = existing }
        else {
            let libraryURL = libraryURL, stateURL = stateURL, organizationURL = organizationURL
            let seeded = rootURL.appendingPathComponent(".samples-installed")
            let examples = seedSamples ? Bundle.main.resourceURL?.appendingPathComponent("samples") : nil
            let root = rootURL
            task = Task.detached(priority: .userInitiated) {
                try SyncInstaller.recover(in: root)
                try LibraryFolderDeletion.recover(in: root)
                var documents = try LibraryDisk.loadMetadata(from: libraryURL)
                var state = FileManager.default.fileExists(atPath: stateURL.path)
                    ? try JSONDecoder().decode(LocalReadingState.self, from: Data(contentsOf: stateURL)) : LocalReadingState()
                let storedState = state
                let needsMigration = state.version < 2
                state.version = 2
                if let examples, !FileManager.default.fileExists(atPath: seeded.path) {
                    if case .imported(let added) = try LibraryDisk.importItem(at: examples, into: libraryURL, name: "开始阅读",
                        knownFingerprints: Set(documents.map { $0.collection.fingerprint })) {
                        documents.append(contentsOf: added)
                    }
                    try Data().write(to: seeded, options: .atomic)
                }
                let organization = try LibraryOrganization.load(from: organizationURL, documents: documents)
                try SyncInstaller.restoreAliases(in: &state, root: root)
                let validIDs = Set(documents.map(\.id))
                state.favorites.formIntersection(validIDs)
                let validKeys = Set(validIDs.map(\.uuidString))
                state.positions = state.positions.filter { validKeys.contains($0.key) }
                state.lastOpened = state.lastOpened.filter { validKeys.contains($0.key) }
                return Snapshot(documents: documents, organization: organization, state: state,
                    needsStateSave: needsMigration || !FileManager.default.fileExists(atPath: stateURL.path) || state != storedState)
            }
            loadTask = task
        }
        do {
            let snapshot = try await task.value
            guard !hasLoaded else { return }
            state = snapshot.state
            stateRevision = snapshot.needsStateSave ? 1 : 0
            let observedAt = Date()
            progressObservedAt = state.progressUpdates.mapValues { _ in observedAt }
            documents = snapshot.documents
            organization = snapshot.organization
            contentRevision &+= 1
            rebuildIndexes()
        } catch {
            guard !hasLoaded else { return }
            isReadOnly = true
            errorMessage = "资料库读取失败，已保留原文件并暂停写入。\n\(error.localizedDescription)"
        }
        hasLoaded = true
        isLoading = false
        loadTask = nil
        if !isReadOnly {
            if stateRevision != savedStateRevision { scheduleSave() }
            await restoreSyncConnection()
        }
    }

    private func rebuildIndexes() {
        revision &+= 1
        visibleCache = nil
        documentIndex = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedRoots = Dictionary(documents.map { ($0.collection.id.uuidString, $0.rootURL) }, uniquingKeysWith: { first, _ in first })
        folderByFilter = Dictionary(organization.folders.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        folderNameByDocument = [:]
        folderNameByDocument.reserveCapacity(documents.count)
        folderOrderByID = [:]
        folderOrderByID.reserveCapacity(organization.folders.count)
        for folder in organization.folders {
            folderOrderByID[folder.id] = folder.documentIDs
            for id in folder.documentIDs where folderNameByDocument[id] == nil { folderNameByDocument[id] = folder.name }
        }
    }

    var collections: [LibraryFolder] { organization.folders }
    var canOrganize: Bool { hasLoaded && !isReadOnly && !isImporting && !isExporting && !isDeleting && !isUpdating && !isSyncInstalling && !isConnecting }
    var roots: [String: URL] { cachedRoots }
    func document(id: UUID?) -> LibraryDocument? { id.flatMap { documentIndex[$0] } }
    func folder(matching filter: String?) -> LibraryFolder? { filter.flatMap { folderByFilter[$0] } }
    func folderName(for id: UUID) -> String { folderNameByDocument[id] ?? "资料" }
    func isFavorite(_ id: UUID) -> Bool { state.favorites.contains(id) }

    func orderedDocuments(in folderID: UUID?) -> [LibraryDocument] {
        let order = folderID.flatMap { folderOrderByID[$0] } ?? organization.documentOrder
        return order.compactMap { documentIndex[$0] }
    }

    /// The shelf asks for this list from several places in one render pass, so the answer is kept
    /// until something it depends on actually changes.
    func visibleDocuments(filter: String?, matching matches: Set<UUID>? = nil, searchToken: UUID? = nil) -> [LibraryDocument] {
        let key = VisibleKey(revision: revision, filter: filter, searchToken: searchToken)
        if let visibleCache, visibleCache.key == key { return visibleCache.value }
        let folderID = folder(matching: filter)?.id
        var result = orderedDocuments(in: folderID).filter { document in
            let inGroup = folderID != nil || filter == "all" || filter == nil
                || (filter == "favorites" && state.favorites.contains(document.id))
                || (filter == "recent" && state.lastOpened[document.id.uuidString] != nil)
            return inGroup && (matches?.contains(document.id) ?? true)
        }
        if filter == "recent" {
            result.sort { (state.lastOpened[$0.id.uuidString] ?? .distantPast) > (state.lastOpened[$1.id.uuidString] ?? .distantPast) }
        }
        visibleCache = (key, result)
        return result
    }

    @discardableResult func createFolder(named name: String) throws -> UUID {
        var updated = organization
        let id = try updated.createFolder(named: name)
        try commitOrganization(updated)
        return id
    }
    func renameFolder(_ id: UUID, to name: String, expectedName: String? = nil) throws {
        guard let current = folderByFilter[id.uuidString] else {
            throw ReaderFailure(message: "资料夹不存在，请重新选择。")
        }
        guard expectedName == nil || current.name == expectedName else {
            throw ReaderFailure(message: "资料夹名称已在其他窗口修改，请重新打开后再试。")
        }
        var updated = organization
        try updated.renameFolder(id, to: name)
        guard updated != organization else { return }
        try commitOrganization(updated)
        notice = "资料夹已重命名为「\(folderByFilter[id.uuidString]?.name ?? name)」"
    }
    func reorderFolders(_ ids: [UUID], visibleIDs: [UUID], at index: Int) throws {
        var updated = organization
        try updated.reorderFolders(ids, visibleIDs: visibleIDs, at: index)
        guard updated != organization else { return }
        try commitOrganization(updated)
    }
    func moveDocuments(_ ids: [UUID], to folderID: UUID) throws {
        var updated = organization
        try updated.moveDocuments(ids, to: folderID)
        try commitOrganization(updated)
    }
    func reorderDocuments(_ ids: [UUID], visibleIDs: [UUID], at index: Int, folderID: UUID?) throws {
        var updated = organization
        try updated.reorderDocuments(ids, visibleIDs: visibleIDs, at: index, folderID: folderID)
        try commitOrganization(updated)
    }
    private func commitOrganization(_ updated: LibraryOrganization) throws {
        guard canOrganize else { throw ReaderFailure(message: "资料库正在处理其他操作，请稍后重试。") }
        try updated.save(to: organizationURL)
        organization = updated
        rebuildIndexes()
        scheduleSync()
    }

    func deleteDocument(_ id: UUID) async throws {
        guard canOrganize else { throw ReaderFailure(message: "资料库正在处理其他操作，请稍后重试。") }
        guard let document = documentIndex[id] else { throw ReaderFailure(message: "这篇文章已不存在。") }
        isDeleting = true
        defer { isDeleting = false }
        let result = try await Task.detached(priority: .userInitiated) { try LibraryDisk.deleteDocument(document) }.value
        let remaining = documents.filter { $0.id != id }.map { existing in
            existing.collection.id == result.collection.id
                ? LibraryDocument(record: existing.record, collection: result.collection, rootURL: existing.rootURL) : existing
        }
        var updated = organization
        updated.reconcile(with: remaining)
        state.favorites.remove(id)
        state.positions.removeValue(forKey: id.uuidString)
        state.lastOpened.removeValue(forKey: id.uuidString)
        documents = remaining
        organization = updated
        contentRevision &+= 1
        rebuildIndexes()
        markStateChanged()
        await flush()
        await content.remove(id)
        notice = "已删除「\(document.title)」"
        if let cleanupError = result.cleanupError { errorMessage = cleanupError }
        // Deletion is already committed in the package. Keep the visible shelf consistent even
        // if saving the secondary folder/order record fails; launch will reconcile it again.
        let savedOrganization = updated, url = organizationURL
        do { try await Task.detached { try savedOrganization.save(to: url) }.value }
        catch {
            isReadOnly = true
            throw ReaderFailure(message: "文章已删除，但整理记录未能保存，已暂停写入。请重新打开 App。\n\(error.localizedDescription)")
        }
        scheduleSync()
    }

    func deleteFolder(_ id: UUID, expected: LibraryFolder? = nil) async throws {
        guard canOrganize else { throw ReaderFailure(message: "资料库正在处理其他操作，请稍后重试。") }
        guard let folder = folderByFilter[id.uuidString] else { throw ReaderFailure(message: "这个资料夹已不存在。") }
        guard expected == nil || expected == folder else {
            throw ReaderFailure(message: "资料夹名称或内容已发生变化，请重新确认后删除。")
        }
        let ids = Set(folder.documentIDs)
        let deleting = documents.filter { ids.contains($0.id) }
        var updated = organization
        updated.folders.removeAll { $0.id == id }
        updated.documentOrder.removeAll { ids.contains($0) }
        isDeleting = true
        defer { isDeleting = false }
        let result: LibraryFolderDeletion.Result
        let root = rootURL, savedOrganization = updated
        do {
            result = try await Task.detached(priority: .userInitiated) {
                try LibraryFolderDeletion.delete(documents: deleting, organization: savedOrganization, root: root)
            }.value
        } catch {
            if error is LibraryUpdateFailure { isReadOnly = true }
            throw error
        }
        for documentID in ids {
            state.favorites.remove(documentID)
            state.positions.removeValue(forKey: documentID.uuidString)
            state.progressUpdates.removeValue(forKey: documentID.uuidString)
            state.lastOpened.removeValue(forKey: documentID.uuidString)
            progressObservedAt.removeValue(forKey: documentID.uuidString)
        }
        documents = documents.filter { !ids.contains($0.id) }.map { document in
            guard let collection = result.collections[document.collection.id] else { return document }
            return LibraryDocument(record: document.record, collection: collection, rootURL: document.rootURL)
        }
        organization = updated
        if !ids.isEmpty { contentRevision &+= 1 }
        rebuildIndexes()
        for documentID in ids { await content.remove(documentID) }
        if !ids.isEmpty { markStateChanged() }
        await flush()
        notice = "已删除资料夹「\(folder.name)」" + (ids.isEmpty ? "" : "及其中 \(ids.count) 篇文章")
        if let cleanupError = result.cleanupError { errorMessage = cleanupError }
        scheduleSync()
    }

    /// Read alongside the body so the first layout already reserves the right box for each image.
    func imageSizes(for document: LibraryDocument) async -> [String: [Int]] {
        await attachments.sizes(collection: document.collection.id, root: document.rootURL, revision: contentRevision)
    }
    func position(for id: UUID) -> ReadingPosition? { state.positions[id.uuidString] }
    func progressUpdate(for id: UUID) -> ReadingProgressUpdate? { state.progressUpdates[id.uuidString] }
    func isRemoteProgress(for id: UUID) -> Bool {
        guard let update = progressUpdate(for: id) else { return false }
        return update.device != state.readingDeviceID
    }

    func saveMarkdown(_ markdown: String, for document: LibraryDocument, originalMarkdown: String) async throws {
        try await updateDocument(document) {
            try LibraryDisk.saveMarkdown(markdown, for: document, originalMarkdown: originalMarkdown)
        }
        notice = "已保存文章"
    }

    func renameDocument(_ document: LibraryDocument, to name: String) async throws {
        try await updateDocument(document) { try LibraryDisk.renameDocument(document, to: name) }
        notice = "已重命名为「\(documentIndex[document.id]?.title ?? name)」"
    }

    private func updateDocument(_ document: LibraryDocument,
                                operation: @escaping @Sendable () throws -> CollectionManifest) async throws {
        guard canOrganize else { throw ReaderFailure(message: "资料库正在处理其他操作，请稍后重试。") }
        guard documentIndex[document.id]?.record == document.record else {
            throw ReaderFailure(message: "文章已发生变化。请先保留草稿，重新打开后再试。")
        }
        isUpdating = true
        defer { isUpdating = false }
        let manifest: CollectionManifest
        do { manifest = try await Task.detached(priority: .userInitiated, operation: operation).value }
        catch {
            if error is LibraryUpdateFailure { isReadOnly = true }
            throw error
        }
        // Evict before publishing. A reader loading the new revision must never see old text.
        await content.remove(document.id)
        let records = Dictionary(uniqueKeysWithValues: manifest.documents.map { ($0.id, $0) })
        documents = documents.map { existing in
            guard existing.collection.id == manifest.id, let record = records[existing.id] else { return existing }
            return LibraryDocument(record: record, collection: manifest, rootURL: existing.rootURL)
        }
        contentRevision &+= 1
        rebuildIndexes()
        scheduleSync()
    }

    func opened(_ id: UUID) {
        guard hasLoaded, !isReadOnly, documentIndex[id] != nil else { return }
        objectWillChange.send()
        state.lastOpened[id.uuidString] = Date()
        markStateChanged()
        invalidateDerivedState()
        scheduleSave()
    }
    func toggleFavorite(_ id: UUID) {
        guard hasLoaded, !isReadOnly, documentIndex[id] != nil else { return }
        objectWillChange.send()
        let key = id.uuidString, favorite = !state.favorites.contains(id)
        let timestamp = max(Date(), (state.favoriteUpdates[key]?.updatedAt ?? .distantPast).addingTimeInterval(0.000001))
        state.favoriteUpdates[key] = FavoriteUpdate(device: state.readingDeviceID, updatedAt: timestamp, isFavorite: favorite)
        if favorite { state.favorites.insert(id) } else { state.favorites.remove(id) }
        markStateChanged()
        invalidateDerivedState()
        enqueueStateSave()
        scheduleSync()
    }
    func updatePosition(_ position: ReadingPosition, id: UUID, readAt: Date = Date()) {
        guard hasLoaded, !isReadOnly, documentIndex[id] != nil, position.offset.isFinite, position.progress.isFinite else { return }
        let key = id.uuidString
        guard state.positions[key] != position else { return }
        let previous = state.progressUpdates[key]
        // Only an action after observing the current checkpoint can advance its logical time.
        // An older WebKit callback delayed by cloud installation must keep its original time.
        let timestamp = readAt >= (progressObservedAt[key] ?? .distantPast)
            ? max(readAt, (previous?.updatedAt ?? .distantPast).addingTimeInterval(0.000001)) : readAt
        let update = ReadingProgressUpdate(device: state.readingDeviceID, updatedAt: timestamp, position: position)
        guard update.isNewer(than: previous) else { return }
        // The shelf only draws a thin progress bar, so redraw when the drawn value moves, not on
        // every scroll tick the reader reports.
        if drawnProgress(state.positions[key]?.progress) != drawnProgress(position.progress) { noteProgressRedraw() }
        state.positions[key] = position
        state.progressUpdates[key] = update
        markStateChanged()
        scheduleSave()
        scheduleSync(after: 3)
    }

    private func applyFavorites(_ updates: [String: FavoriteUpdate]) {
        var merged = state.favoriteUpdates
        FavoriteSnapshot.merge(updates, into: &merged)
        var favorites = state.favorites
        for document in documents {
            guard let update = merged[document.id.uuidString] else { continue }
            if update.isFavorite { favorites.insert(document.id) }
            else { favorites.remove(document.id) }
        }
        guard merged != state.favoriteUpdates || favorites != state.favorites else { return }
        objectWillChange.send()
        if favorites != state.favorites { invalidateDerivedState() }
        state.favoriteUpdates = merged
        state.favorites = favorites
        markStateChanged()
        enqueueStateSave()
    }

    private func applyProgress(_ updates: [String: ReadingProgressUpdate]) {
        let previous = state.progressUpdates
        ReadingProgressSnapshot.merge(updates, into: &state.progressUpdates)
        let observedAt = Date()
        for (key, update) in state.progressUpdates where previous[key] != update { progressObservedAt[key] = observedAt }
        var positions = state.positions
        for document in documents {
            if let update = state.progressUpdates[document.id.uuidString] { positions[document.id.uuidString] = update.position }
        }
        if positions != state.positions || previous != state.progressUpdates {
            objectWillChange.send()
            state.positions = positions
            markStateChanged()
            enqueueStateSave()
        }
    }
    private func drawnProgress(_ value: Double?) -> Int { Int((min(1, max(0, value ?? 0)) * 200).rounded()) }
    /// Every notification re-evaluates the whole shelf, including the reader's own toolbar, and
    /// scrolling produces several a second. A progress bar does not need that rate, so the
    /// notifications are limited and the last one always lands.
    private func noteProgressRedraw() {
        progressRedraw?.cancel()
        progressRedraw = nil
        guard Date().timeIntervalSince(lastProgressRedraw) < 0.5 else { sendProgressRedraw(); return }
        let redraw = DispatchWorkItem { [weak self] in self?.sendProgressRedraw() }
        progressRedraw = redraw
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: redraw)
    }
    private func sendProgressRedraw() {
        progressRedraw?.cancel()
        progressRedraw = nil
        lastProgressRedraw = Date()
        objectWillChange.send()
    }
    /// Favorites and reading history feed the filtered list, so its cached answer must be dropped.
    private func invalidateDerivedState() {
        revision &+= 1
        visibleCache = nil
    }

    private func markStateChanged() { stateRevision &+= 1 }

    private func scheduleSave() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.enqueueStateSave() }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: save)
    }

    /// Await durability without occupying the main thread. Concurrent callers share a write;
    /// mutations arriving during that write are saved in order before the flush completes.
    @discardableResult func flush() async -> Bool {
        if progressRedraw != nil { sendProgressRedraw() }
        while let write = enqueueStateSave() {
            guard await write.value else { return false }
        }
        return true
    }

    @discardableResult private func enqueueStateSave() -> Task<Bool, Never>? {
        pendingSave?.cancel()
        pendingSave = nil
        guard hasLoaded, !isReadOnly else { return nil }
        if let pendingWrite, pendingWrite.revision == stateRevision { return pendingWrite.task }
        guard stateRevision != savedStateRevision else { return pendingWrite?.task }
        let snapshot = state, revision = stateRevision, previous = pendingWrite?.task
        let writer = stateWriter, url = stateURL
        let task = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            let succeeded: Bool
            do {
                try await writer.write(snapshot, to: url)
                self?.savedStateRevision = revision
                succeeded = true
            } catch {
                self?.errorMessage = "阅读状态未能保存：\(error.localizedDescription)"
                succeeded = false
            }
            if self?.pendingWrite?.revision == revision { self?.pendingWrite = nil }
            return succeeded
        }
        pendingWrite = (revision, task)
        return task
    }

    /// iOS may suspend even a local-only library. Start the background assertion synchronously,
    /// before yielding to the writer; the reader's final checkpoint can join the same flush.
    func saveForLifecycle() {
        enqueueStateSave()
        #if os(iOS)
        guard lifecycleSave == nil else { return }
        let id = UUID()
        lifecycleSaveID = id
        lifecycleActivity = UIApplication.shared.beginBackgroundTask(withName: "保存本机阅读状态") { [weak self] in
            Task { @MainActor in self?.endLifecycleSave(id) }
        }
        lifecycleSave = Task { [self] in
            await flush()
            endLifecycleSave(id)
        }
        #else
        Task { await flush() }
        #endif
    }
    #if os(iOS)
    private func endLifecycleSave(_ id: UUID) {
        guard lifecycleSaveID == id else { return }
        if lifecycleActivity != .invalid {
            UIApplication.shared.endBackgroundTask(lifecycleActivity)
            lifecycleActivity = .invalid
        }
        lifecycleSave = nil
        lifecycleSaveID = nil
    }
    #endif

    func exportPackage(documentIDs: [UUID], name: String) async throws -> PreparedLibraryPackage {
        guard canOrganize else { throw ReaderFailure(message: "资料库正在处理其他操作，请稍后重试。") }
        let selected = documentIDs.compactMap { documentIndex[$0] }
        guard selected.count == documentIDs.count, Set(documentIDs).count == documentIDs.count else {
            throw ReaderFailure(message: "资料已发生变化，请重新选择后导出。")
        }
        isExporting = true
        defer { isExporting = false }
        return try await Task.detached(priority: .userInitiated) {
            try LibraryPackage.prepare(documents: selected, name: name)
        }.value
    }

    func importItems(_ urls: [URL], intoFolderID: UUID? = nil) async {
        await loadIfNeeded()
        guard canOrganize else { return }
        isImporting = true
        defer { isImporting = false }
        let destination = libraryURL
        var added: [LibraryDocument] = []
        var duplicate = 0
        var emptyFolders: [String] = []
        var fingerprints = Set(documents.map { $0.collection.fingerprint })
        var failures: [String] = []
        for source in urls {
            do {
                let known = fingerprints
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryDisk.importItem(at: source, into: destination, knownFingerprints: known)
                }.value
                switch result {
                case .imported(let incoming):
                    added.append(contentsOf: incoming)
                    fingerprints.formUnion(incoming.map { $0.collection.fingerprint })
                case .duplicate: duplicate += 1
                case .emptyFolder(let name): emptyFolders.append(name)
                }
            } catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        do {
            if !added.isEmpty || !emptyFolders.isEmpty {
                let loaded = documents + added
                var updated = organization
                updated.reconcile(with: loaded, newDocumentsFolderID: intoFolderID)
                for name in emptyFolders {
                    var candidate = name, number = 2
                    while updated.folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(candidate) == .orderedSame }) {
                        candidate = String(name.prefix(90)) + " (\(number))"
                        number += 1
                    }
                    _ = try updated.createFolder(named: candidate)
                }
                let organizationToSave = updated, url = organizationURL
                try await Task.detached { try organizationToSave.save(to: url) }.value
                documents = loaded
                organization = updated
                contentRevision &+= 1
                rebuildIndexes()
            }
        }
        catch {
            // Imported packages are already committed to disk. Keep the current shelf intact
            // and prevent another import from using its now-incomplete fingerprint snapshot.
            isReadOnly = true
            failures.append("资料文件已保留，但整理记录未能保存，已暂停写入。重新打开 App 后会重新读取资料库。\n\(error.localizedDescription)")
        }
        notice = "已导入 \(added.count) 篇" + (emptyFolders.isEmpty ? "" : "，\(emptyFolders.count) 个空资料夹") + (duplicate > 0 ? "，跳过 \(duplicate) 份重复资料" : "")
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
        scheduleSync()
    }

    private var connectionURL: URL { rootURL.appendingPathComponent("sync-connection.json") }

    private func makeSyncAccess(_ url: URL) -> SyncFolderAccess {
        SyncFolderAccess(url: url) { [weak self] in
            Task { @MainActor in self?.scheduleSync(after: 2) }
        }
    }

    private func restoreSyncConnection() async {
        let url = connectionURL, root = rootURL
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let connection = try await Task.detached { try JSONDecoder().decode(SyncConnection.self, from: Data(contentsOf: url)) }.value
            syncConnection = connection
            let resolved = try SyncFolderAccess.resolve(connection.bookmark)
            let access = makeSyncAccess(resolved.url)
            if resolved.stale {
                var refreshed = connection
                refreshed.bookmark = try SyncFolderAccess.bookmark(for: resolved.url)
                try SyncFolderIO.encoder.encode(refreshed).write(to: url, options: .atomic)
                syncConnection = refreshed
            }
            syncEngine = try await Task.detached { try LibrarySyncEngine(root: root, libraryID: connection.libraryID) }.value
            syncAccess?.close()
            syncAccess = access
            syncStatus = "等待检查资料库"
            startSyncPolling()
            scheduleSync(after: 0)
        } catch {
            syncStatus = "需要重新连接"
            syncIssue = "无法恢复资料库访问权限，请重新选择原来的资料库文件夹。\n\(error.localizedDescription)"
        }
    }

    func connectSyncFolder(_ url: URL, create: Bool) async {
        await loadIfNeeded()
        guard canOrganize, !isSyncing else { return }
        isConnecting = true
        syncIssue = nil
        syncStatus = "正在连接资料库…"
        await flush()
        let root = rootURL
        let access = makeSyncAccess(url)
        do {
            let header = try await Task.detached { try SyncFolderIO.connect(at: url, create: create, localRoot: root) }.value
            if let connected = syncConnection, header.id != connected.libraryID {
                throw ReaderFailure(message: "请选择原来的资料库。更换资料库前，请先断开当前连接。")
            }
            _ = try await Task.detached { try SyncInstaller.backupBeforeConnecting(root: root) }.value
            let connection = SyncConnection(libraryID: header.id, bookmark: try SyncFolderAccess.bookmark(for: url), folderName: url.lastPathComponent)
            let engine = try await Task.detached { try LibrarySyncEngine(root: root, libraryID: header.id) }.value
            try SyncFolderIO.encoder.encode(connection).write(to: connectionURL, options: .atomic)
            syncAccess?.close()
            syncAccess = access
            syncConnection = connection
            syncEngine = engine
            syncStatus = "资料库已连接"
            notice = "已连接「\(url.lastPathComponent)」，本机资料已备份"
        } catch {
            access.close()
            syncStatus = syncConnection == nil ? "未连接资料库" : "连接未完成"
            if error is SyncPending { syncIssue = "资料库尚未下载完成，请在「文件」或 Finder 中下载该文件夹后再连接。" }
            else { syncIssue = error.localizedDescription }
        }
        isConnecting = false
        if syncEngine != nil {
            startSyncPolling()
            await synchronize()
        }
    }

    func disconnectSyncFolder() {
        guard !isSyncing, !isConnecting else { return }
        do {
            if FileManager.default.fileExists(atPath: connectionURL.path) { try FileManager.default.removeItem(at: connectionURL) }
            syncDebounce?.cancel()
            syncPoll?.cancel()
            syncDebounce = nil
            syncPoll = nil
            syncAccess?.close()
            syncAccess = nil
            syncEngine = nil
            syncConnection = nil
            syncIssue = nil
            lastSyncCheck = nil
            syncStatus = "未连接资料库"
            notice = "已断开连接，已下载的资料和本机修改均已保留"
        } catch { syncIssue = error.localizedDescription }
    }

    func syncSceneChanged(isActive: Bool) {
        syncSceneActive = isActive
        if isActive {
            startSyncPolling()
            scheduleSync(after: 0)
        } else {
            syncPoll?.cancel()
            syncPoll = nil
            syncDebounce?.cancel()
            syncDebounce = nil
            #if os(iOS)
            finishSyncInBackground()
            #endif
        }
    }

    #if os(iOS)
    /// Give the small progress snapshot a chance to leave the phone when switching apps. The
    /// local checkpoint is already durable; iOS expiration/offline conditions retry next launch.
    private func finishSyncInBackground() {
        guard automaticSync, syncEngine != nil, backgroundSync == nil, UIApplication.shared.applicationState == .background else { return }
        let id = UUID()
        backgroundSyncID = id
        backgroundActivity = UIApplication.shared.beginBackgroundTask(withName: "保存阅读进度") { [weak self] in
            Task { @MainActor in
                guard self?.backgroundSyncID == id else { return }
                self?.backgroundSync?.cancel()
                self?.endBackgroundSync(id)
            }
        }
        backgroundSync = Task { [weak self] in
            guard let self else { return }
            defer { endBackgroundSync(id) }
            do {
                while isSyncing { try await Task.sleep(for: .milliseconds(100)) }
                try Task.checkCancellation()
                await synchronize()
            } catch { /* Local progress remains saved for the next foreground sync. */ }
        }
    }

    private func endBackgroundSync(_ id: UUID) {
        guard backgroundSyncID == id else { return }
        if backgroundActivity != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundActivity)
            backgroundActivity = .invalid
        }
        backgroundSync = nil
        backgroundSyncID = nil
    }
    #endif

    private func startSyncPolling() {
        guard automaticSync, syncSceneActive, syncEngine != nil, syncPoll == nil else { return }
        syncPoll = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                await self?.synchronize()
            }
        }
    }

    private func scheduleSync(after seconds: Double = 1) {
        guard automaticSync, syncSceneActive, syncEngine != nil, !isReadOnly else { return }
        if isSyncing { syncRequested = true; return }
        syncDebounce?.cancel()
        syncDebounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.synchronize()
        }
    }

    func synchronize() async {
        guard !isSyncing else { syncRequested = true; return }
        guard canOrganize, let engine = syncEngine, let access = syncAccess else { return }
        isSyncing = true
        syncRequested = false
        syncStatus = "正在检查并同步…"
        syncIssue = nil
        defer {
            isSyncInstalling = false
            isSyncing = false
            if syncRequested { scheduleSync(after: 2) }
        }
        do {
            // Fetch before the first local capture so identical imported packages can be
            // recognized without replacing the user's current local library.
            if await engine.needsBootstrap() { _ = try await engine.exchange(with: access.url) }
            guard canOrganize else { syncRequested = true; return }
            isSyncInstalling = true
            await flush()
            try await engine.prepare(documents: documents, organization: organization)
            var capturedRevision = revision
            isSyncInstalling = false
            var progressExchange: ReadingProgressExchange?
            var progressError: String?
            do {
                progressExchange = try await engine.exchangeProgress(state.progressUpdates, device: state.readingDeviceID,
                    documentIDs: Set(documents.map(\.id)), folder: access.url)
                if let progressExchange { applyProgress(progressExchange.updates) }
            } catch { progressError = error.localizedDescription }
            var favoriteExchange: FavoriteExchange?
            do {
                favoriteExchange = try await engine.exchangeFavorites(state.favoriteUpdates, device: state.readingDeviceID,
                    documentIDs: Set(documents.map(\.id)), folder: access.url)
                let unchanged = revision == capturedRevision
                if let favoriteExchange { applyFavorites(favoriteExchange.updates) }
                if unchanged { capturedRevision = revision }
            } catch {
                progressError = [progressError, "收藏同步：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
            let exchange = try await engine.exchange(with: access.url)
            guard revision == capturedRevision, canOrganize else { syncRequested = true; return }
            isSyncInstalling = true
            await flush()
            if let installed = try await engine.install(exchange.projection, documents: documents, organization: organization) {
                let changed = installed.documents.filter { current in
                    documentIndex[current.id]?.record != current.record || documentIndex[current.id]?.rootURL != current.rootURL
                }.map(\.id)
                let removed = Set(documents.map(\.id)).subtracting(installed.documents.map(\.id))
                for id in Set(changed).union(removed) { await content.remove(id) }
                let previousState = state
                SyncInstaller.remap(&state, aliases: installed.aliases)
                documents = installed.documents
                organization = installed.organization
                let validIDs = Set(documents.map(\.id)), validKeys = Set(documents.map { $0.id.uuidString })
                state.favorites.formIntersection(validIDs)
                state.positions = state.positions.filter { validKeys.contains($0.key) }
                state.lastOpened = state.lastOpened.filter { validKeys.contains($0.key) }
                if !changed.isEmpty || !removed.isEmpty { contentRevision &+= 1 }
                rebuildIndexes()
                if state != previousState { markStateChanged() }
                await flush()
            }
            // Reading metadata can arrive before its article. Keep it until the corresponding
            // content has downloaded, then make it available on the very first open.
            applyProgress([:])
            applyFavorites([:])
            await flush()
            lastSyncCheck = Date()
            if let progressError {
                syncStatus = "资料已更新，收藏或进度待同步"
                syncIssue = "本机收藏与阅读进度已保留，将在下次检查时重试。\n\(progressError)"
            } else if progressExchange?.waitingForDownload == true || favoriteExchange?.waitingForDownload == true {
                syncStatus = "资料已更新，等待下载收藏或进度"
            } else {
                syncStatus = exchange.waitingForUpload || progressExchange?.waitingForUpload == true || favoriteExchange?.waitingForUpload == true ? "等待 iCloud 上传" : "资料、收藏与阅读进度已更新"
            }
        } catch is SyncPending {
            syncStatus = "等待 iCloud 下载"
        } catch is CancellationError {
            syncStatus = "稍后继续同步"
        } catch {
            if error is LibraryUpdateFailure { isReadOnly = true; errorMessage = error.localizedDescription }
            syncStatus = "同步暂未完成"
            syncIssue = "本机资料已保留，将在下次检查时重试。\n\(error.localizedDescription)"
        }
    }

    deinit { syncPoll?.cancel(); syncDebounce?.cancel(); syncAccess?.close() }
}
