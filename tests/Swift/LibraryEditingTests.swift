import XCTest
@testable import StudyReader

final class LibraryEditingTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    @MainActor private func importedLibrary() async throws -> (LibraryStore, LibraryDocument) {
        let source = temp.appendingPathComponent("source/lessons")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# 原标题\n\nold-keyword\n\n![图](diagram.png)\n".utf8).write(to: source.appendingPathComponent("lesson.md"))
        try Data("# 第二篇\n正文".utf8).write(to: source.appendingPathComponent("other.md"))
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("diagram.png"))
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([temp.appendingPathComponent("source")])
        XCTAssertNil(store.errorMessage)
        return (store, try XCTUnwrap(store.documents.first { $0.title == "lesson" }))
    }

    @MainActor func testSaveRefreshesBodyAndSearchWithoutChangingFilenameOrLosingState() async throws {
        let (store, original) = try await importedLibrary()
        let untouched = try XCTUnwrap(store.documents.first { $0.id != original.id })
        let folder = try store.createFolder(named: "概率论")
        try store.moveDocuments([original.id], to: folder)
        store.toggleFavorite(original.id)
        store.opened(original.id)
        store.updatePosition(ReadingPosition(anchor: "anchor", excerpt: "old", offset: 40, progress: 0.4), id: original.id)
        await store.flush()
        let organization = store.organization
        let body = try await store.content.markdown(for: original)
        let previousRevision = store.contentRevision
        _ = try await store.searchEngine.matches(query: "old-keyword", documents: store.documents, revision: previousRevision)
        _ = try await store.searchEngine.matches(query: "new-keyword", documents: store.documents, revision: previousRevision)
        let edited = "# 条件概率\n\nnew-keyword\n\n$$P(A|B)=\\frac{P(AB)}{P(B)}$$\n"
        try await store.saveMarkdown(edited, for: original, originalMarkdown: body)
        let saved = try XCTUnwrap(store.document(id: original.id))
        XCTAssertEqual(saved.title, "lesson")
        XCTAssertEqual(saved.record.title, "lesson")
        XCTAssertEqual(saved.fileURL, original.fileURL)
        XCTAssertNotEqual(saved.record, original.record)
        XCTAssertEqual(store.document(id: untouched.id)?.record, untouched.record, "Only the edited article should reload")
        XCTAssertEqual(store.document(id: untouched.id)?.collection.fingerprint, saved.collection.fingerprint)
        XCTAssertNotEqual(saved.collection.fingerprint, original.collection.fingerprint)
        XCTAssertEqual(store.organization, organization)
        XCTAssertTrue(store.isFavorite(original.id))
        XCTAssertEqual(store.position(for: original.id)?.offset, 40)
        XCTAssertEqual(store.contentRevision, previousRevision + 1)
        XCTAssertFalse(store.isUpdating)
        XCTAssertTrue(store.canOrganize)
        let cached = try await store.content.markdown(for: saved)
        XCTAssertEqual(cached, edited)
        let oldMatches = try await store.searchEngine.matches(query: "old-keyword", documents: store.documents, revision: store.contentRevision)
        let newMatches = try await store.searchEngine.matches(query: "new-keyword", documents: store.documents, revision: store.contentRevision)
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(newMatches, [original.id])
        XCTAssertEqual(try String(contentsOf: temp.appendingPathComponent("source/lessons/lesson.md"), encoding: .utf8), body)
        let reopened = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        let restored = try XCTUnwrap(reopened.document(id: saved.id))
        XCTAssertEqual(restored.record, saved.record)
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: restored), edited)
        XCTAssertEqual(reopened.organization, organization)
        XCTAssertTrue(reopened.isFavorite(saved.id))
        XCTAssertNotNil(reopened.state.lastOpened[saved.id.uuidString])
        XCTAssertEqual(reopened.position(for: saved.id)?.progress, 0.4)
    }

    @MainActor func testRenameChangesFilePathAndSearchButPreservesBodyImagesAndReadingState() async throws {
        let (store, original) = try await importedLibrary()
        let body = try await store.content.markdown(for: original)
        let organization = store.organization
        store.toggleFavorite(original.id)
        store.updatePosition(ReadingPosition(anchor: "", excerpt: "old", offset: 25, progress: 0.3), id: original.id)
        _ = try await store.searchEngine.matches(query: "贝叶斯笔记", documents: store.documents, revision: store.contentRevision)
        try await store.renameDocument(original, to: "  贝叶斯笔记.md  ")
        let renamed = try XCTUnwrap(store.document(id: original.id))
        XCTAssertEqual(renamed.title, "贝叶斯笔记")
        XCTAssertEqual(renamed.record.relativePath, "lessons/贝叶斯笔记.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.path))
        XCTAssertNil(renamed.record.usesCustomTitle)
        let renamedBody = body
        XCTAssertEqual(try Data(contentsOf: renamed.fileURL), Data(body.utf8))
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: renamed), renamedBody)
        XCTAssertEqual(try Data(contentsOf: renamed.fileURL.deletingLastPathComponent().appendingPathComponent("diagram.png")), Data([1, 2, 3]))
        XCTAssertEqual(renamed.fileURL.deletingLastPathComponent(), original.fileURL.deletingLastPathComponent())
        XCTAssertEqual(store.organization, organization)
        XCTAssertTrue(store.isFavorite(original.id))
        XCTAssertEqual(store.position(for: original.id)?.offset, 25)
        let cached = try await store.content.markdown(for: renamed)
        XCTAssertEqual(cached, renamedBody)
        let renamedMatches = try await store.searchEngine.matches(query: "贝叶斯笔记", documents: store.documents, revision: store.contentRevision)
        XCTAssertEqual(renamedMatches, [original.id])
        let oldNameMatches = try await store.searchEngine.matches(query: "lesson", documents: store.documents, revision: store.contentRevision)
        XCTAssertTrue(oldNameMatches.isEmpty)
        try await store.saveMarkdown("# 修改正文标题\n\n新的正文", for: renamed, originalMarkdown: renamedBody)
        XCTAssertEqual(store.document(id: original.id)?.title, "贝叶斯笔记")
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: store.libraryURL).first { $0.id == original.id }?.title, "贝叶斯笔记")
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("source/lessons/lesson.md").path))
        await store.flush()
        let reopened = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.document(id: original.id)?.fileURL, renamed.fileURL)
        XCTAssertEqual(reopened.document(id: original.id)?.title, "贝叶斯笔记")
        XCTAssertEqual(reopened.organization, organization)
        XCTAssertTrue(reopened.isFavorite(original.id))
        XCTAssertEqual(reopened.position(for: original.id)?.progress, 0.3)
    }

    @MainActor func testRenameRejectsInvalidFilenamesWithoutChanges() async throws {
        let (store, original) = try await importedLibrary()
        let manifestURL = original.rootURL.appendingPathComponent(".reader-collection.json")
        let manifest = try Data(contentsOf: manifestURL)
        let body = try Data(contentsOf: original.fileURL)
        for name in ["", "  ", "bad\nname", "bad\0name", ".", "..", ".hidden", "../escape", "bad/name", "bad\\name", "bad:name", String(repeating: "概", count: 100)] {
            do { try await store.renameDocument(original, to: name); XCTFail("Invalid or conflicting name accepted: \(name)") }
            catch { }
            XCTAssertEqual(store.document(id: original.id)?.record, original.record)
            XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
            XCTAssertEqual(try Data(contentsOf: original.fileURL), body)
            XCTAssertFalse(store.isUpdating)
        }
    }

    @MainActor func testCaseOnlyRenameWorksAndFilenameConflictsCannotOverwriteFiles() async throws {
        let (store, original) = try await importedLibrary()
        let body = try Data(contentsOf: original.fileURL)
        let other = try XCTUnwrap(store.documents.first { $0.id != original.id })
        let otherBody = try Data(contentsOf: other.fileURL)
        try await store.renameDocument(original, to: "LESSON")
        let renamed = try XCTUnwrap(store.document(id: original.id))
        XCTAssertEqual(renamed.fileURL.lastPathComponent, "LESSON.md")
        XCTAssertEqual(renamed.title, "LESSON")
        XCTAssertEqual(try Data(contentsOf: renamed.fileURL), body)
        for name in ["other", "OTHER.md"] {
            do { try await store.renameDocument(renamed, to: name); XCTFail("Overwrote another article") }
            catch { }
        }
        XCTAssertEqual(try Data(contentsOf: other.fileURL), otherBody)
        XCTAssertEqual(try Data(contentsOf: renamed.fileURL), body)
        XCTAssertEqual(store.document(id: original.id)?.record, renamed.record)
    }

    @MainActor func testStaleDraftAndExternalEditsCannotOverwriteNewerContent() async throws {
        let (store, original) = try await importedLibrary()
        let body = try LibraryDisk.readMarkdown(for: original)
        let newer = "# newer\n\nfirst saved draft"
        try await store.saveMarkdown(newer, for: original, originalMarkdown: body)
        do { try await store.saveMarkdown("# stale", for: original, originalMarkdown: body); XCTFail("Stale editor overwrote saved content") }
        catch { }
        do { try await store.renameDocument(original, to: "stale"); XCTFail("Stale rename accepted") }
        catch { }
        let current = try XCTUnwrap(store.document(id: original.id))
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: current), newer)
        let external = "# externally edited"
        try Data(external.utf8).write(to: current.fileURL, options: .atomic)
        do { try await store.saveMarkdown("# second", for: current, originalMarkdown: newer); XCTFail("External edit overwritten") }
        catch { }
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: current), external)
        XCTAssertFalse(store.isUpdating)
    }

    @MainActor func testFailedMetadataCommitRollsBackBothSaveAndRename() async throws {
        let (store, original) = try await importedLibrary()
        let body = try LibraryDisk.readMarkdown(for: original)
        let manifestURL = original.rootURL.appendingPathComponent(".reader-collection.json")
        let manifest = try Data(contentsOf: manifestURL)
        let revision = store.contentRevision
        // The nested article directory stays writable; only committing its manifest fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: original.rootURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: original.rootURL.path) }
        do { try await store.saveMarkdown("# changed", for: original, originalMarkdown: body); XCTFail("Expected metadata failure") }
        catch { }
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: original), body)
        do { try await store.renameDocument(original, to: "Changed"); XCTFail("Expected metadata failure") }
        catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.fileURL.deletingLastPathComponent().appendingPathComponent("Changed.md").path))
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: original), body)
        XCTAssertEqual(try Data(contentsOf: manifestURL), manifest)
        XCTAssertEqual(store.document(id: original.id)?.record, original.record)
        XCTAssertEqual(store.contentRevision, revision)
        XCTAssertFalse(store.isUpdating)
        XCTAssertFalse(store.isReadOnly)
    }

    @MainActor func testSizeLimitAndLinkedFilesCannotChangeOriginal() async throws {
        let (store, original) = try await importedLibrary()
        let body = try LibraryDisk.readMarkdown(for: original)
        do { try await store.saveMarkdown(String(repeating: "a", count: 5_000_001), for: original, originalMarkdown: body); XCTFail("Oversized document accepted") }
        catch { }
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: original), body)
        let source = temp.appendingPathComponent("source/lessons/lesson.md")
        try FileManager.default.removeItem(at: original.fileURL)
        try FileManager.default.createSymbolicLink(at: original.fileURL, withDestinationURL: source)
        do { try await store.saveMarkdown("# changed", for: original, originalMarkdown: body); XCTFail("Edited a symlink") }
        catch { }
        do { try await store.renameDocument(original, to: "Changed"); XCTFail("Renamed a symlink") }
        catch { }
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), body)
        XCTAssertEqual(store.document(id: original.id)?.record, original.record)
    }

    func testOldManifestRecordsRemainDecodable() throws {
        let id = UUID()
        let bytes = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "title": "旧文章", "relativePath": "a.md"])
        let record = try JSONDecoder().decode(DocumentRecord.self, from: bytes)
        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.revision)
        XCTAssertNil(record.usesCustomTitle)
    }
}
