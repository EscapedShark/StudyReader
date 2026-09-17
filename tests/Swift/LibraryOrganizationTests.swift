import XCTest
@testable import StudyReader

final class LibraryOrganizationTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func source(named name: String = "source", count: Int = 3, image: UInt8 = 1) throws -> URL {
        let root = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("lessons"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try Data([image]).write(to: root.appendingPathComponent("assets/shared.png"))
        for index in 0..<count {
            try Data("# Article \(index)\n\n![image](../assets/shared.png)\n\n$P(A)$".utf8)
                .write(to: root.appendingPathComponent("lessons/\(index).md"))
        }
        return root
    }
    private func documents(count: Int = 3) throws -> [LibraryDocument] {
        let library = temp.appendingPathComponent("Collections")
        _ = try LibraryDisk.importItem(at: source(count: count), into: library)
        return try LibraryDisk.loadMetadata(from: library)
    }

    func testMigrationAndEmptyFolderSurviveReload() throws {
        let docs = try documents()
        let file = temp.appendingPathComponent("organization.json")
        var organization = try LibraryOrganization.load(from: file, documents: docs)
        XCTAssertEqual(organization.folders.count, 1)
        XCTAssertEqual(organization.folders[0].id, docs[0].collection.id)
        XCTAssertEqual(organization.folders[0].documentIDs, docs.map(\.id))
        let folder = try organization.createFolder(named: "  概率论  ")
        try organization.save(to: file)
        let reloaded = try LibraryOrganization.load(from: file, documents: docs)
        XCTAssertEqual(reloaded, organization)
        XCTAssertEqual(reloaded.folders.first { $0.id == folder }?.name, "概率论")
        XCTAssertEqual(reloaded.folders.first { $0.id == folder }?.documentIDs, [])
    }

    func testReorderingUsesInsertionGapsAndPersists() throws {
        let docs = try documents(count: 4)
        let ids = docs.map(\.id)
        var organization = LibraryOrganization()
        organization.reconcile(with: docs)
        let folder = docs[0].collection.id
        try organization.reorderDocuments([ids[0]], visibleIDs: ids, at: 4, folderID: folder)
        let moved = [ids[1], ids[2], ids[3], ids[0]]
        XCTAssertEqual(organization.folders[0].documentIDs, moved)
        try organization.reorderDocuments([ids[0]], visibleIDs: moved, at: 0, folderID: folder)
        XCTAssertEqual(organization.folders[0].documentIDs, ids)
        try organization.reorderDocuments([ids[1]], visibleIDs: ids, at: 2, folderID: folder)
        XCTAssertEqual(organization.folders[0].documentIDs, ids, "Dropping immediately after itself is a no-op")
        try organization.reorderDocuments([ids[3]], visibleIDs: ids, at: 0, folderID: folder)
        let file = temp.appendingPathComponent("organization.json")
        try organization.save(to: file)
        XCTAssertEqual(try LibraryOrganization.load(from: file, documents: docs).folders[0].documentIDs, [ids[3], ids[0], ids[1], ids[2]])
    }

    func testFilteredReorderingPreservesHiddenItems() throws {
        let docs = try documents(count: 5)
        let ids = docs.map(\.id)
        var organization = LibraryOrganization()
        organization.reconcile(with: docs)
        try organization.reorderDocuments([ids[4]], visibleIDs: [ids[0], ids[2], ids[4]], at: 0, folderID: nil)
        XCTAssertEqual(organization.documentOrder, [ids[4], ids[1], ids[0], ids[3], ids[2]])
        XCTAssertEqual(organization.folders[0].documentIDs, ids, "Each folder keeps its own order")
        let unchanged = organization
        XCTAssertThrowsError(try organization.reorderDocuments([ids[0]], visibleIDs: ids, at: 5, folderID: nil))
        XCTAssertEqual(organization, unchanged, "A stale drop must not overwrite a more recent order")
    }

    @MainActor func testCrossFolderMovePreservesOriginalsAssetsFavoritesAndPosition() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.loadIfNeeded()
        await store.importItems([try source(named: "A", count: 1, image: 1), try source(named: "B", count: 1, image: 2)])
        XCTAssertNil(store.errorMessage)
        let document = try XCTUnwrap(store.documents.first { $0.collection.name == "A" })
        let destination = try XCTUnwrap(store.collections.first { $0.name == "B" })
        let otherDocument = try XCTUnwrap(store.documents.first { $0.collection.name == "B" })
        let original = try Data(contentsOf: document.fileURL)
        store.toggleFavorite(document.id)
        store.updatePosition(ReadingPosition(anchor: "line-1", excerpt: "Article", offset: 0.2, progress: 0.4), id: document.id)
        store.flush()
        try store.moveDocuments([document.id], to: destination.id)
        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.organization.folder(containing: document.id)?.id, destination.id)
        XCTAssertEqual(reopened.collections.first { $0.id == document.collection.id }?.documentIDs, [])
        XCTAssertEqual(reopened.orderedDocuments(in: destination.id).map(\.id), [otherDocument.id, document.id])
        XCTAssertTrue(reopened.state.favorites.contains(document.id))
        XCTAssertEqual(reopened.position(for: document.id)?.progress, 0.4)
        let movedDocument = try XCTUnwrap(reopened.documents.first { $0.id == document.id })
        XCTAssertEqual(movedDocument.baseURL, document.baseURL)
        XCTAssertEqual(try Data(contentsOf: movedDocument.fileURL), original)
        XCTAssertEqual(try Data(contentsOf: movedDocument.rootURL.appendingPathComponent("assets/shared.png")), Data([1]))
        XCTAssertEqual(try Data(contentsOf: otherDocument.rootURL.appendingPathComponent("assets/shared.png")), Data([2]))
    }

    @MainActor func testImportIntoCreatedFolderAndDeduplication() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.loadIfNeeded()
        let folder = try store.createFolder(named: "概率论")
        let source = try source(count: 1)
        await store.importItems([source], intoFolderID: folder)
        let ids = store.documents.map(\.id)
        XCTAssertEqual(store.collections.count, 1)
        XCTAssertEqual(store.collections[0].id, folder)
        XCTAssertEqual(store.collections[0].documentIDs, ids)
        await store.importItems([source], intoFolderID: folder)
        XCTAssertEqual(store.documents.map(\.id), ids)
        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.collections.count, 1)
        XCTAssertEqual(reopened.collections[0].documentIDs, ids)
    }

    func testInvalidNamesAndMovesLeaveOrganizationUnchanged() throws {
        let docs = try documents()
        var organization = LibraryOrganization()
        organization.reconcile(with: docs)
        let before = organization
        XCTAssertThrowsError(try organization.createFolder(named: " \n "))
        XCTAssertThrowsError(try organization.createFolder(named: "SOURCE"))
        XCTAssertThrowsError(try organization.moveDocuments([docs[0].id], to: UUID()))
        XCTAssertThrowsError(try organization.moveDocuments([UUID()], to: docs[0].collection.id))
        XCTAssertEqual(organization, before)
    }

    @MainActor func testWriteFailureDoesNotPublishUnpersistedMove() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.loadIfNeeded()
        await store.importItems([try source(count: 1)])
        let destination = try store.createFolder(named: "目标")
        let before = store.organization
        let file = root.appendingPathComponent("library-organization.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.moveDocuments([store.documents[0].id], to: destination))
        let revision = store.revision
        XCTAssertThrowsError(try store.renameFolder(destination, to: "未保存的名称"))
        XCTAssertThrowsError(try store.reorderFolders([destination], visibleIDs: store.collections.map(\.id), at: 0))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.folder(matching: destination.uuidString)?.name, "目标")
        XCTAssertEqual(store.organization, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.documents[0].fileURL.path))
    }

    func testCorruptOrganizationIsNotOverwritten() throws {
        let docs = try documents()
        let file = temp.appendingPathComponent("organization.json")
        let corrupt = Data("{incomplete".utf8)
        try corrupt.write(to: file)
        XCTAssertThrowsError(try LibraryOrganization.load(from: file, documents: docs))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    @MainActor func testDragPayloadRoundTrip() async throws {
        let id = UUID()
        let provider = DocumentDrag.provider(for: id, title: "Article")
        let decoded = try await DocumentDrag.read([provider])
        XCTAssertEqual(decoded, [id])
    }

    @MainActor func testFolderRenamePersistsWithContentsOrderAndReadingStateIntact() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([try source(count: 3)])
        let folder = try XCTUnwrap(store.collections.first)
        let ids = folder.documentIDs
        try store.reorderDocuments([ids[2]], visibleIDs: ids, at: 0, folderID: folder.id)
        let order = [ids[2], ids[0], ids[1]]
        let empty = try store.createFolder(named: "空资料夹")
        let documents = store.documents
        let bodies = try documents.map { try Data(contentsOf: $0.fileURL) }
        let globalOrder = store.organization.documentOrder
        let contentRevision = store.contentRevision
        store.toggleFavorite(ids[0])
        store.updatePosition(ReadingPosition(anchor: "line-2", excerpt: "正文", offset: 0.5, progress: 0.74), id: ids[0])
        store.flush()

        try store.renameFolder(folder.id, to: "  概率论  ")
        try store.renameFolder(empty, to: "待学习")
        XCTAssertEqual(store.folder(matching: folder.id.uuidString)?.name, "概率论")
        XCTAssertEqual(store.folderName(for: ids[0]), "概率论")
        XCTAssertEqual(store.orderedDocuments(in: folder.id).map(\.id), order)
        XCTAssertEqual(store.organization.documentOrder, globalOrder)
        XCTAssertEqual(store.contentRevision, contentRevision, "Folder names must not reload article content or restart searches")
        XCTAssertEqual(store.documents.map(\.record), documents.map(\.record))
        XCTAssertEqual(store.documents.map(\.fileURL), documents.map(\.fileURL))
        XCTAssertEqual(try store.documents.map { try Data(contentsOf: $0.fileURL) }, bodies)

        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.folder(matching: folder.id.uuidString)?.name, "概率论")
        XCTAssertEqual(reopened.folder(matching: empty.uuidString)?.name, "待学习")
        XCTAssertEqual(reopened.folder(matching: empty.uuidString)?.documentIDs, [])
        XCTAssertEqual(reopened.orderedDocuments(in: folder.id).map(\.id), order)
        XCTAssertEqual(reopened.organization.documentOrder, globalOrder)
        XCTAssertTrue(reopened.isFavorite(ids[0]))
        XCTAssertEqual(reopened.position(for: ids[0])?.progress, 0.74)
    }

    func testFolderRenameValidationAndCaseOnlyChange() throws {
        var organization = LibraryOrganization()
        let target = try organization.createFolder(named: "English")
        _ = try organization.createFolder(named: "概率论")
        let before = organization
        for invalid in [" \n ", "概率论", String(repeating: "长", count: 101), "名称\n换行", "名称\0"] {
            XCTAssertThrowsError(try organization.renameFolder(target, to: invalid))
            XCTAssertEqual(organization, before)
        }
        XCTAssertThrowsError(try organization.renameFolder(UUID(), to: "不存在"))
        XCTAssertEqual(organization, before)
        try organization.renameFolder(target, to: " english ")
        XCTAssertEqual(organization.folders.first { $0.id == target }?.name, "english")
        XCTAssertEqual(organization.folders.map(\.id), before.folders.map(\.id))
    }

    @MainActor func testStaleRenameDoesNotOverwriteNewNameButAllowsMembershipChanges() async throws {
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([try source(count: 1)])
        let target = try store.createFolder(named: "原名称")
        try store.moveDocuments([store.documents[0].id], to: target)
        try store.renameFolder(target, to: "新名称", expectedName: "原名称")
        XCTAssertThrowsError(try store.renameFolder(target, to: "过期名称", expectedName: "原名称"))
        XCTAssertEqual(store.folder(matching: target.uuidString)?.name, "新名称")
        XCTAssertEqual(store.folder(matching: target.uuidString)?.documentIDs, [store.documents[0].id])
    }

    @MainActor func testFolderReorderPersistsAndRenameKeepsItsPositionAndReadingState() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([try source(count: 2)])
        let sourceFolder = try XCTUnwrap(store.collections.first)
        let b = try store.createFolder(named: "B")
        let a = try store.createFolder(named: "A")
        let ids = [sourceFolder.id, b, a]
        XCTAssertEqual(store.collections.map(\.id), ids, "New folders append instead of sorting by name")
        let document = try XCTUnwrap(store.documents.first)
        let body = try Data(contentsOf: document.fileURL)
        let documentOrder = store.organization.documentOrder
        let revision = store.contentRevision
        store.toggleFavorite(document.id)
        store.updatePosition(ReadingPosition(anchor: "line-2", excerpt: "body", offset: 1, progress: 0.7), id: document.id)
        store.flush()
        try store.reorderFolders([a], visibleIDs: ids, at: 0)
        try store.renameFolder(a, to: "Z")
        XCTAssertEqual(store.collections.map(\.id), [a, sourceFolder.id, b])
        XCTAssertEqual(store.contentRevision, revision)
        XCTAssertEqual(store.organization.documentOrder, documentOrder)
        XCTAssertEqual(store.folder(matching: sourceFolder.id.uuidString)?.documentIDs, sourceFolder.documentIDs)
        XCTAssertEqual(try Data(contentsOf: document.fileURL), body)
        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.collections.map(\.id), [a, sourceFolder.id, b])
        XCTAssertEqual(reopened.collections.first?.name, "Z")
        XCTAssertEqual(reopened.organization, store.organization)
        XCTAssertTrue(reopened.isFavorite(document.id))
        XCTAssertEqual(reopened.position(for: document.id)?.progress, 0.7)
    }

    func testLegacyAlphabeticalFolderOrderIsMigratedOnlyOnce() throws {
        var legacy = LibraryOrganization(folderOrderVersion: nil)
        let c = try legacy.createFolder(named: "C")
        let a = try legacy.createFolder(named: "A")
        let b = try legacy.createFolder(named: "B")
        let url = temp.appendingPathComponent("organization.json")
        try legacy.save(to: url)
        var loaded = try LibraryOrganization.load(from: url, documents: [])
        XCTAssertEqual(loaded.folders.map(\.id), [a, b, c], "Preserve the order the legacy UI showed")
        try loaded.reorderFolders([c], visibleIDs: [a, b, c], at: 0)
        try loaded.save(to: url)
        XCTAssertEqual(try LibraryOrganization.load(from: url, documents: []).folders.map(\.id), [c, a, b])
    }

    func testFolderReorderRejectsStaleIDsAndPreservesRelativeOrderForMultipleMoves() throws {
        var organization = LibraryOrganization()
        let ids = try ["A", "B", "C", "D"].map { try organization.createFolder(named: $0) }
        try organization.reorderFolders([ids[1], ids[3]], visibleIDs: ids, at: 0)
        let reordered = [ids[1], ids[3], ids[0], ids[2]]
        XCTAssertEqual(organization.folders.map(\.id), reordered)
        let before = organization
        XCTAssertThrowsError(try organization.reorderFolders([ids[0]], visibleIDs: ids, at: 0))
        XCTAssertThrowsError(try organization.reorderFolders([UUID()], visibleIDs: reordered, at: 0))
        XCTAssertThrowsError(try organization.reorderFolders([ids[0], ids[0]], visibleIDs: reordered, at: 0))
        XCTAssertEqual(organization, before)
        try organization.reorderFolders([ids[1]], visibleIDs: reordered, at: reordered.count)
        XCTAssertEqual(organization.folders.map(\.id), [ids[3], ids[0], ids[2], ids[1]])
    }
}
