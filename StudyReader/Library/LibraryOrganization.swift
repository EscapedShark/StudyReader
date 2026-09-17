import Foundation

struct LibraryFolder: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var documentIDs: [UUID]
}

/// Display folders are independent of import packages, so organizing never breaks relative assets.
struct LibraryOrganization: Codable, Equatable {
    var folders: [LibraryFolder] = []
    var documentOrder: [UUID] = []

    static func load(from url: URL, documents: [LibraryDocument]) throws -> LibraryOrganization {
        let stored = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) : nil
        var result = stored ?? Self()
        result.reconcile(with: documents)
        // Launching without any change must not pay for an atomic rewrite of the whole record.
        if result != stored { try result.save(to: url) }
        return result
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func reconcile(with documents: [LibraryDocument], newDocumentsFolderID: UUID? = nil) {
        let validIDs = Set(documents.map(\.id))
        var assigned = Set<UUID>()
        for index in folders.indices {
            folders[index].documentIDs = folders[index].documentIDs.filter {
                validIDs.contains($0) && assigned.insert($0).inserted
            }
        }
        // A hand-edited record could repeat an id; first match wins, as a linear search would.
        var folderIndexByID = Dictionary(folders.indices.map { (folders[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        for document in documents where !assigned.contains(document.id) {
            let destination = newDocumentsFolderID.flatMap { folderIndexByID[$0] } ?? folderIndexByID[document.collection.id]
            if let destination {
                folders[destination].documentIDs.append(document.id)
            } else {
                folderIndexByID[document.collection.id] = folders.count
                folders.append(LibraryFolder(id: document.collection.id, name: document.collection.name, documentIDs: [document.id]))
            }
            assigned.insert(document.id)
        }
        var ordered = Set<UUID>()
        documentOrder = documentOrder.filter { validIDs.contains($0) && ordered.insert($0).inserted }
        documentOrder.append(contentsOf: documents.map(\.id).filter { ordered.insert($0).inserted })
    }

    mutating func createFolder(named name: String) throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ReaderFailure(message: "请输入资料夹名称。") }
        guard name.count <= 100 else { throw ReaderFailure(message: "资料夹名称请控制在 100 个字以内。") }
        guard !folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw ReaderFailure(message: "已经有同名资料夹，请换一个名称。")
        }
        let id = UUID()
        folders.append(LibraryFolder(id: id, name: name, documentIDs: []))
        return id
    }

    func folder(containing documentID: UUID) -> LibraryFolder? {
        folders.first { $0.documentIDs.contains(documentID) }
    }

    mutating func moveDocuments(_ ids: [UUID], to folderID: UUID, at insertionIndex: Int? = nil) throws {
        guard let destination = folders.firstIndex(where: { $0.id == folderID }) else {
            throw ReaderFailure(message: "目标资料夹不存在，请重新选择。")
        }
        try validate(ids)
        let moving = Set(ids)
        let oldDestination = folders[destination].documentIDs
        let index = min(max(0, insertionIndex ?? oldDestination.count), oldDestination.count)
        let adjustedIndex = oldDestination.prefix(index).filter { !moving.contains($0) }.count
        for folder in folders.indices {
            folders[folder].documentIDs.removeAll { moving.contains($0) }
        }
        folders[destination].documentIDs.insert(contentsOf: ids, at: adjustedIndex)
    }

    /// Indices are insertion gaps in the displayed list, before the dragged items are removed.
    mutating func reorderDocuments(_ ids: [UUID], visibleIDs: [UUID], at insertionIndex: Int, folderID: UUID?) throws {
        try validate(ids)
        let visible = Set(visibleIDs)
        guard visible.count == visibleIDs.count, !visibleIDs.isEmpty, ids.allSatisfy(visible.contains) else {
            throw ReaderFailure(message: "请在当前列表内调整顺序，或拖到左侧资料夹进行移动。")
        }
        let folderIndex = folderID.flatMap { id in folders.firstIndex { $0.id == id } }
        if folderID != nil && folderIndex == nil { throw ReaderFailure(message: "资料夹不存在。") }
        let order = folderIndex.map { folders[$0].documentIDs } ?? documentOrder
        // A pending drop must not reorder a list that changed while its payload was loading.
        guard order.filter(visible.contains) == visibleIDs else {
            throw ReaderFailure(message: "列表已发生变化，请重新拖动。")
        }
        let moving = Set(ids)
        let index = min(max(0, insertionIndex), visibleIDs.count)
        let adjustedIndex = visibleIDs.prefix(index).filter { !moving.contains($0) }.count
        var reordered = visibleIDs.filter { !moving.contains($0) }
        reordered.insert(contentsOf: ids, at: adjustedIndex)
        var cursor = 0
        let result = order.map { id -> UUID in
            guard visible.contains(id) else { return id }
            defer { cursor += 1 }
            return reordered[cursor]
        }
        if let folderIndex { folders[folderIndex].documentIDs = result }
        else { documentOrder = result }
    }

    private func validate(_ ids: [UUID]) throws {
        let existing = Set(documentOrder)
        guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy(existing.contains) else {
            throw ReaderFailure(message: "拖动的文章已不存在，请刷新后重试。")
        }
    }
}
