import XCTest
@testable import StudyReader

final class LibraryDeletionTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func source(_ name: String) throws -> URL {
        let url = temp.appendingPathComponent("\(name).md")
        try Data("# \(name)\n\noriginal".utf8).write(to: url)
        return url
    }

    @MainActor func testDeletionPersistsAndClearsStateWithoutTouchingOtherArticlesOrSource() async throws {
        let source = temp.appendingPathComponent("lessons")
        let assets = source.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: assets.appendingPathComponent("shared.png"))
        for name in ["A", "B"] {
            try Data("# \(name)\n\nkeyword-\(name)\n![shared](assets/shared.png)".utf8)
                .write(to: source.appendingPathComponent("\(name).md"))
        }
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([source])
        let a = try XCTUnwrap(store.documents.first { $0.title == "A" })
        let b = try XCTUnwrap(store.documents.first { $0.title == "B" })
        let folder = try store.createFolder(named: "自建资料夹")
        try store.moveDocuments([a.id], to: folder)
        let position = ReadingPosition(anchor: "section", excerpt: "text", offset: 30, progress: 0.5)
        for document in [a, b] {
            store.toggleFavorite(document.id)
            store.opened(document.id)
            store.updatePosition(position, id: document.id)
        }
        _ = try await store.content.markdown(for: a)
        let beforeMatches = try await store.searchEngine.matches(query: "keyword-A", documents: store.documents, revision: store.contentRevision)
        XCTAssertEqual(beforeMatches, [a.id])
        let previousRevision = store.contentRevision

        try await store.deleteDocument(a.id)
        XCTAssertFalse(store.isDeleting)
        XCTAssertTrue(store.canOrganize)
        XCTAssertNil(store.document(id: a.id))
        XCTAssertEqual(store.documents.map(\.id), [b.id])
        XCTAssertTrue(store.orderedDocuments(in: folder).isEmpty)
        XCTAssertEqual(store.orderedDocuments(in: nil).map(\.id), [b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("A.md").path))
        XCTAssertEqual(try Data(contentsOf: b.rootURL.appendingPathComponent("assets/shared.png")), Data([1, 2, 3]))
        XCTAssertEqual(store.contentRevision, previousRevision + 1)
        XCTAssertNotEqual(store.document(id: b.id)?.collection.fingerprint, b.collection.fingerprint)

        // A WebKit position message can arrive after the visible reader has switched articles.
        store.opened(a.id)
        store.toggleFavorite(a.id)
        store.updatePosition(position, id: a.id)
        await store.flush()
        XCTAssertFalse(store.isFavorite(a.id))
        XCTAssertNil(store.position(for: a.id))
        XCTAssertNil(store.state.lastOpened[a.id.uuidString])
        XCTAssertTrue(store.isFavorite(b.id))
        XCTAssertEqual(store.position(for: b.id)?.progress, 0.5)
        let matches = try await store.searchEngine.matches(query: "keyword-A", documents: store.documents, revision: store.contentRevision)
        XCTAssertTrue(matches.isEmpty)
        do { _ = try await store.content.markdown(for: a); XCTFail("Deleted content must leave the body cache") }
        catch { }

        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.documents.map(\.id), [b.id])
        XCTAssertTrue(reopened.orderedDocuments(in: folder).isEmpty)
        XCTAssertEqual(reopened.visibleDocuments(filter: "favorites").map(\.id), [b.id])
        XCTAssertEqual(reopened.visibleDocuments(filter: "recent").map(\.id), [b.id])
        XCTAssertNil(reopened.position(for: a.id))
    }

    @MainActor func testDeletingLastArticleStaysEmptyAndAllowsReimport() async throws {
        let original = try source("概率论")
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([original])
        let document = try XCTUnwrap(store.documents.first)
        try await store.deleteDocument(document.id)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.roots.isEmpty)
        XCTAssertTrue(store.visibleDocuments(filter: "all").isEmpty)
        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertTrue(reopened.documents.isEmpty)
        guard case .imported(let reimported) = try LibraryDisk.importItem(at: original, into: store.libraryURL) else {
            XCTFail("Deleting an article must allow importing its source again"); return
        }
        XCTAssertEqual(reimported.count, 1)
        XCTAssertNotEqual(reimported.first?.id, document.id)
    }

    @MainActor func testMissingBodyCanStillBeDeletedFromShelf() async throws {
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([try source("Missing")])
        let document = try XCTUnwrap(store.documents.first)
        try FileManager.default.removeItem(at: document.fileURL)
        try await store.deleteDocument(document.id)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(try LibraryDisk.loadMetadata(from: store.libraryURL).isEmpty)
    }

    @MainActor func testFailedManifestWritePreservesArticleAndReadingState() async throws {
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([try source("ReadOnly")])
        let document = try XCTUnwrap(store.documents.first)
        store.toggleFavorite(document.id)
        let before = try Data(contentsOf: document.rootURL.appendingPathComponent(".reader-collection.json"))
        let revision = store.contentRevision
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: document.rootURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: document.rootURL.path) }
        do { try await store.deleteDocument(document.id); XCTFail("Read-only package must reject the deletion") }
        catch { }
        XCTAssertNotNil(store.document(id: document.id))
        XCTAssertTrue(store.isFavorite(document.id))
        XCTAssertFalse(store.isDeleting)
        XCTAssertEqual(store.contentRevision, revision)
        XCTAssertEqual(try Data(contentsOf: document.rootURL.appendingPathComponent(".reader-collection.json")), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.fileURL.path))
    }

    @MainActor func testSecondarySaveFailureDoesNotResurrectDeletedArticle() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([try source("Delete")])
        let document = try XCTUnwrap(store.documents.first)
        store.toggleFavorite(document.id)
        let organizationURL = root.appendingPathComponent("library-organization.json")
        let savedOrganization = try Data(contentsOf: organizationURL)
        try FileManager.default.removeItem(at: organizationURL)
        try FileManager.default.createDirectory(at: organizationURL, withIntermediateDirectories: true)
        do { try await store.deleteDocument(document.id); XCTFail("Folder-state write should report failure") }
        catch { }
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertFalse(store.canOrganize)
        XCTAssertFalse(store.isFavorite(document.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: document.fileURL.path))
        try FileManager.default.removeItem(at: organizationURL)
        try savedOrganization.write(to: organizationURL)
        let reopened = LibraryStore(rootURL: root, seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.documents.isEmpty)
        XCTAssertTrue(reopened.organization.documentOrder.isEmpty)
        XCTAssertTrue(reopened.state.favorites.isEmpty)
    }

    @MainActor func testDeletionRejectsLinkedFilesOutsideTheImportedPackage() async throws {
        let original = try source("Original")
        let bytes = try Data(contentsOf: original)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([original])
        let document = try XCTUnwrap(store.documents.first)
        try FileManager.default.removeItem(at: document.fileURL)
        try FileManager.default.createSymbolicLink(at: document.fileURL, withDestinationURL: original)
        do { try await store.deleteDocument(document.id); XCTFail("Do not delete through a link") }
        catch { }
        XCTAssertNotNil(store.document(id: document.id))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: store.libraryURL).map(\.id), [document.id])
    }
}
