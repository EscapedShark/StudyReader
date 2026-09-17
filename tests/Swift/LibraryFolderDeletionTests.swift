import XCTest
@testable import StudyReader

final class LibraryFolderDeletionTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func source(_ name: String, articles: [String]) throws -> URL {
        let root = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("images/shared.png"))
        for article in articles {
            try Data("# \(article)\n\nkeyword-\(article)\n![图片](images/shared.png)".utf8).write(to: root.appendingPathComponent(article + ".md"))
        }
        return root
    }

    @MainActor func testWholeFolderDeletionAcrossPackagesPreservesOtherArticlesSharedImagesAndOriginals() async throws {
        let first = try source("Shared", articles: ["A", "B"]), second = try source("Single", articles: ["C"])
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false, automaticSync: false)
        await store.importItems([first, second])
        let a = try XCTUnwrap(store.documents.first { $0.title == "A" })
        let b = try XCTUnwrap(store.documents.first { $0.title == "B" })
        let c = try XCTUnwrap(store.documents.first { $0.title == "C" })
        let folderID = try store.createFolder(named: "整组删除")
        try store.moveDocuments([a.id, c.id], to: folderID)
        let folder = try XCTUnwrap(store.folder(matching: folderID.uuidString))
        for doc in store.documents {
            store.toggleFavorite(doc.id)
            store.opened(doc.id)
            store.updatePosition(ReadingPosition(anchor: "line-0", excerpt: doc.title, offset: 0, progress: 0.6), id: doc.id)
            _ = try await store.content.markdown(for: doc)
        }
        try await store.deleteFolder(folderID, expected: folder)
        XCTAssertNil(store.folder(matching: folderID.uuidString))
        XCTAssertEqual(store.documents.map(\.id), [b.id])
        XCTAssertTrue(store.isFavorite(b.id))
        XCTAssertEqual(store.position(for: b.id)?.progress, 0.6)
        for id in [a.id, c.id] {
            XCTAssertNil(store.position(for: id))
            XCTAssertNil(store.progressUpdate(for: id))
            XCTAssertNil(store.state.lastOpened[id.uuidString])
            XCTAssertFalse(store.isFavorite(id))
            store.updatePosition(ReadingPosition(anchor: "", excerpt: "late", offset: 0, progress: 0.8), id: id)
            XCTAssertNil(store.position(for: id))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.rootURL.path), "A package with no remaining articles can release its copied attachments")
        XCTAssertEqual(try Data(contentsOf: b.rootURL.appendingPathComponent("images/shared.png")), Data([1, 2, 3]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent("A.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("C.md").path))
        let matches = try await store.searchEngine.matches(query: "keyword-A", documents: store.documents, revision: store.contentRevision)
        XCTAssertTrue(matches.isEmpty)
        do { _ = try await store.content.markdown(for: a); XCTFail("Deleted content must leave the cache") } catch { }
        let reopened = LibraryStore(rootURL: root, seedSamples: false, automaticSync: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertEqual(reopened.documents.map(\.id), [b.id])
        XCTAssertNil(reopened.folder(matching: folderID.uuidString))
        XCTAssertFalse(reopened.isDeleting)
    }

    @MainActor func testDeletingEmptyFolderPersistsWithoutAffectingArticles() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false, automaticSync: false)
        await store.importItems([try source("Package", articles: ["A"])])
        let ids = store.documents.map(\.id), revision = store.contentRevision
        let folder = try store.createFolder(named: "空资料夹")
        try await store.deleteFolder(folder)
        XCTAssertEqual(store.documents.map(\.id), ids)
        XCTAssertEqual(store.contentRevision, revision)
        XCTAssertNil(store.folder(matching: folder.uuidString))
        let reopened = LibraryStore(rootURL: root, seedSamples: false, automaticSync: false)
        await reopened.loadIfNeeded()
        XCTAssertNil(reopened.folder(matching: folder.uuidString))
        XCTAssertEqual(reopened.documents.map(\.id), ids)
    }

    @MainActor func testChangedFolderRequiresFreshConfirmation() async throws {
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false, automaticSync: false)
        await store.importItems([try source("Package", articles: ["A"])])
        let id = try store.createFolder(named: "待删除")
        let confirmed = try XCTUnwrap(store.folder(matching: id.uuidString))
        try store.moveDocuments(store.documents.map(\.id), to: id)
        do { try await store.deleteFolder(id, expected: confirmed); XCTFail("Do not delete articles added since confirmation") } catch { }
        XCTAssertEqual(store.folder(matching: id.uuidString)?.documentIDs.count, 1)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertFalse(store.isDeleting)
    }

    @MainActor func testFailureInLaterPackageRollsBackEarlierManifestsAndKeepsReadingState() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false, automaticSync: false)
        await store.importItems([try source("First", articles: ["A"]), try source("Second", articles: ["B"])])
        let folder = try store.createFolder(named: "一起删除")
        try store.moveDocuments(store.documents.map(\.id), to: folder)
        let documents = store.documents.sorted { $0.rootURL.path < $1.rootURL.path }
        for doc in documents { store.toggleFavorite(doc.id) }
        let manifests = try documents.map { try Data(contentsOf: $0.rootURL.appendingPathComponent(".reader-collection.json")) }
        let organization = try Data(contentsOf: root.appendingPathComponent("library-organization.json"))
        let locked = try XCTUnwrap(documents.last?.rootURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        do { try await store.deleteFolder(folder); XCTFail("The read-only second package must reject deletion") } catch { }
        XCTAssertFalse(store.isReadOnly, "Successful rollback leaves the library usable")
        XCTAssertFalse(store.isDeleting)
        XCTAssertEqual(store.folder(matching: folder.uuidString)?.documentIDs.count, 2)
        XCTAssertEqual(try documents.map { try Data(contentsOf: $0.rootURL.appendingPathComponent(".reader-collection.json")) }, manifests)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("library-organization.json")), organization)
        for doc in documents { XCTAssertTrue(store.isFavorite(doc.id)); XCTAssertTrue(FileManager.default.fileExists(atPath: doc.fileURL.path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryFolderDeletion.journalName).path))
    }

    func testInterruptedDeletionAndRollbackRecoverEveryMetadataBoundary() throws {
        for phase in ["applying", "committed", "rollback"] {
            for boundary in 0...2 {
                let root = temp.appendingPathComponent("\(phase)-\(boundary)")
                let package = root.appendingPathComponent("Collections/package")
                try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                let body = package.appendingPathComponent("A.md")
                try Data("original".utf8).write(to: body)
                let paths = ["Collections/package/.reader-collection.json", "library-organization.json"]
                let replacements = paths.map { LibraryFolderDeletion.Replacement(path: $0, before: Data("before".utf8), after: Data("after".utf8)) }
                for (index, replacement) in replacements.enumerated() {
                    try (phase == "committed" || index < boundary ? replacement.after : replacement.before)
                        .write(to: root.appendingPathComponent(replacement.path))
                }
                let transaction = LibraryFolderDeletion.Transaction(phase: phase, replacements: replacements, cleanup: ["Collections/package/A.md"])
                try JSONEncoder().encode(transaction).write(to: root.appendingPathComponent(LibraryFolderDeletion.journalName))
                try LibraryFolderDeletion.recover(in: root)
                for path in paths { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), Data((phase == "rollback" ? "before" : "after").utf8)) }
                XCTAssertEqual(FileManager.default.fileExists(atPath: body.path), phase == "rollback")
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(LibraryFolderDeletion.journalName).path))
                try LibraryFolderDeletion.recover(in: root)
            }
        }
    }
}
