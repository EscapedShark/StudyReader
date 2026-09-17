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
        return try LibraryDisk.load(from: library)
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
        await store.importItems([try source(count: 1)])
        let destination = try store.createFolder(named: "目标")
        let before = store.organization
        let file = root.appendingPathComponent("library-organization.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.moveDocuments([store.documents[0].id], to: destination))
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
}
