import Foundation
import SwiftUI

struct ReadingPosition: Codable {
    var anchor: String
    var excerpt: String
    var offset: Double
    var progress: Double
}

struct LocalReadingState: Codable {
    var favorites: Set<UUID> = []
    var positions: [String: ReadingPosition] = [:]
    var lastOpened: [String: Date] = [:]
}

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [LibraryDocument] = [] { didSet { rebuildIndexes() } }
    @Published private(set) var organization = LibraryOrganization() { didSet { rebuildIndexes() } }
    /// Reading state is not `@Published`: scroll saves arrive several times a second and most of
    /// them change nothing the shelf draws. Notifications are sent explicitly instead.
    private(set) var state = LocalReadingState()
    @Published var isImporting = false
    @Published var errorMessage: String?
    @Published var notice: String?
    private(set) var isReadOnly = false
    let libraryURL: URL
    private let stateURL: URL
    private let organizationURL: URL
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.personal.studyreader.reading-state", qos: .utility)

    // Derived views of the library. Rebuilt only when documents or folders change, because the
    // shelf reads them on every render pass and the reader publishes while scrolling.
    private(set) var revision = 0
    private var documentIndex: [UUID: LibraryDocument] = [:]
    private var sortedFolders: [LibraryFolder] = []
    private var folderByFilter: [String: LibraryFolder] = [:]
    private var folderOrderByID: [UUID: [UUID]] = [:]
    private var folderNameByDocument: [UUID: String] = [:]
    private var cachedRoots: [String: URL] = [:]
    private struct VisibleKey: Equatable { var revision: Int; var filter: String?; var search: String }
    private var visibleCache: (key: VisibleKey, value: [LibraryDocument])?

    init(rootURL: URL? = nil, seedSamples: Bool = true) {
        let root = rootURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("StudyReader", isDirectory: true)
        libraryURL = root.appendingPathComponent("Collections", isDirectory: true)
        stateURL = root.appendingPathComponent("reading-state.json")
        organizationURL = root.appendingPathComponent("library-organization.json")
        do {
            documents = try LibraryDisk.load(from: libraryURL)
            if FileManager.default.fileExists(atPath: stateURL.path) {
                state = try JSONDecoder().decode(LocalReadingState.self, from: Data(contentsOf: stateURL))
            }
            let seeded = root.appendingPathComponent(".samples-installed")
            if seedSamples, !FileManager.default.fileExists(atPath: seeded.path), let examples = Bundle.main.resourceURL?.appendingPathComponent("samples") {
                _ = try LibraryDisk.importItem(at: examples, into: libraryURL, name: "开始阅读")
                try Data().write(to: seeded, options: .atomic)
                documents = try LibraryDisk.load(from: libraryURL)
            }
            organization = try LibraryOrganization.load(from: organizationURL, documents: documents)
        } catch {
            isReadOnly = true
            errorMessage = "资料库读取失败，已保留原文件并暂停写入。\n\(error.localizedDescription)"
        }
        rebuildIndexes()
    }

    private func rebuildIndexes() {
        revision &+= 1
        visibleCache = nil
        documentIndex = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedRoots = Dictionary(documents.map { ($0.collection.id.uuidString, $0.rootURL) }, uniquingKeysWith: { first, _ in first })
        sortedFolders = organization.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        folderByFilter = Dictionary(sortedFolders.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { first, _ in first })
        folderNameByDocument = [:]
        folderNameByDocument.reserveCapacity(documents.count)
        folderOrderByID = [:]
        folderOrderByID.reserveCapacity(organization.folders.count)
        for folder in organization.folders {
            folderOrderByID[folder.id] = folder.documentIDs
            for id in folder.documentIDs where folderNameByDocument[id] == nil { folderNameByDocument[id] = folder.name }
        }
    }

    var collections: [LibraryFolder] { sortedFolders }
    var canOrganize: Bool { !isReadOnly && !isImporting }
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
    func visibleDocuments(filter: String?, search: String) -> [LibraryDocument] {
        let key = VisibleKey(revision: revision, filter: filter, search: search)
        if let visibleCache, visibleCache.key == key { return visibleCache.value }
        let folderID = folder(matching: filter)?.id
        var result = orderedDocuments(in: folderID).filter { document in
            let inGroup = folderID != nil || filter == "all" || filter == nil
                || (filter == "favorites" && state.favorites.contains(document.id))
                || (filter == "recent" && state.lastOpened[document.id.uuidString] != nil)
            return inGroup && document.matches(search)
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
    }

    func position(for id: UUID) -> ReadingPosition? { state.positions[id.uuidString] }
    func opened(_ id: UUID) {
        guard !isReadOnly else { return }
        objectWillChange.send()
        state.lastOpened[id.uuidString] = Date()
        invalidateDerivedState()
        scheduleSave()
    }
    func toggleFavorite(_ id: UUID) {
        guard !isReadOnly else { return }
        objectWillChange.send()
        if state.favorites.contains(id) { state.favorites.remove(id) } else { state.favorites.insert(id) }
        invalidateDerivedState()
        flush()
    }
    func updatePosition(_ position: ReadingPosition, id: UUID) {
        guard !isReadOnly, position.offset.isFinite, position.progress.isFinite else { return }
        let key = id.uuidString
        // The shelf only draws a thin progress bar, so redraw when the drawn value moves, not on
        // every scroll tick the reader reports.
        if drawnProgress(state.positions[key]?.progress) != drawnProgress(position.progress) { objectWillChange.send() }
        state.positions[key] = position
        scheduleSave()
    }
    private func drawnProgress(_ value: Double?) -> Int { Int((min(1, max(0, value ?? 0)) * 200).rounded()) }
    /// Favorites and reading history feed the filtered list, so its cached answer must be dropped.
    private func invalidateDerivedState() {
        revision &+= 1
        visibleCache = nil
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.writeState(waiting: false) }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: save)
    }
    func flush() { writeState(waiting: true) }
    /// Debounced saves hand the file write to a serial queue so scrolling never waits on the disk;
    /// `flush` still returns only once the bytes are on their way out in order.
    private func writeState(waiting: Bool) {
        pendingSave?.cancel()
        pendingSave = nil
        guard !isReadOnly else { return }
        let url = stateURL
        let data: Data
        do { data = try JSONEncoder().encode(state) }
        catch { errorMessage = "阅读状态未能保存：\(error.localizedDescription)"; return }
        let write: @Sendable () -> Void = { [weak self] in
            do { try data.write(to: url, options: .atomic) }
            catch {
                let message = "阅读状态未能保存：\(error.localizedDescription)"
                Task { @MainActor in self?.errorMessage = message }
            }
        }
        if waiting { saveQueue.sync(execute: write) } else { saveQueue.async(execute: write) }
    }

    func importItems(_ urls: [URL], intoFolderID: UUID? = nil) async {
        guard !isReadOnly, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        let destination = libraryURL
        var imported = 0, duplicate = 0
        var failures: [String] = []
        for source in urls {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try LibraryDisk.importItem(at: source, into: destination)
                }.value
                switch result {
                case .imported(let count): imported += count
                case .duplicate: duplicate += 1
                }
            } catch { failures.append("\(source.lastPathComponent)：\(error.localizedDescription)") }
        }
        do {
            let loaded = try await Task.detached { try LibraryDisk.load(from: destination) }.value
            var updated = organization
            updated.reconcile(with: loaded, newDocumentsFolderID: intoFolderID)
            try updated.save(to: organizationURL)
            documents = loaded
            organization = updated
        }
        catch { failures.append(error.localizedDescription) }
        notice = "已导入 \(imported) 篇" + (duplicate > 0 ? "，跳过 \(duplicate) 份重复资料" : "")
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }
}
