import XCTest
@testable import StudyReader

final class LibraryLoadingTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func source(_ name: String, body: String = "正文") throws -> URL {
        let url = temp.appendingPathComponent("\(name).md")
        try Data("# \(name)\n\n\(body)".utf8).write(to: url)
        return url
    }
    private func imported(_ source: URL, root: URL) throws -> LibraryDocument {
        guard case .imported(let documents) = try LibraryDisk.importItem(at: source, into: root.appendingPathComponent("Collections")),
              let document = documents.first else { throw ReaderFailure(message: "Expected an imported document") }
        return document
    }

    func testMetadataLoadDefersBodyAccessAndValidatesOnOpen() throws {
        let root = temp.appendingPathComponent("App")
        let document = try imported(source("概率论"), root: root)
        try FileManager.default.removeItem(at: document.fileURL)
        let metadata = try LibraryDisk.loadMetadata(from: root.appendingPathComponent("Collections"))
        XCTAssertEqual(metadata.map(\.id), [document.id])
        XCTAssertEqual(metadata.first?.title, "概率论")
        XCTAssertThrowsError(try LibraryDisk.readMarkdown(for: metadata[0]))
        try FileManager.default.createSymbolicLink(at: document.fileURL, withDestinationURL: source("outside"))
        XCTAssertThrowsError(try LibraryDisk.readMarkdown(for: metadata[0]), "On-demand reads must retain the import boundary")
    }

    func testIncrementalImportKeepsTheSameNaturalOrderAsReload() throws {
        let source = temp.appendingPathComponent("lessons")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["10.md", "2.md", "1.md"] {
            try Data("# \(name)".utf8).write(to: source.appendingPathComponent(name))
        }
        let library = temp.appendingPathComponent("Collections")
        guard case .imported(let documents) = try LibraryDisk.importItem(at: source, into: library) else {
            XCTFail("Expected imported documents"); return
        }
        XCTAssertEqual(documents.map { $0.record.relativePath }, ["1.md", "2.md", "10.md"])
        XCTAssertEqual(documents.map(\.id), try LibraryDisk.loadMetadata(from: library).map(\.id))
    }

    @MainActor func testInitialLoadIsCoalescedAndEarlyFlushPreservesSavedState() async throws {
        let root = temp.appendingPathComponent("App")
        let document = try imported(source("概率论"), root: root)
        let stateFile = root.appendingPathComponent("reading-state.json")
        let saved = try JSONEncoder().encode(LocalReadingState(favorites: [document.id]))
        try saved.write(to: stateFile)
        let store = LibraryStore(rootURL: root, seedSamples: false)
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertFalse(store.canOrganize)
        await store.flush()
        XCTAssertEqual(try Data(contentsOf: stateFile), saved)
        async let first: Void = store.loadIfNeeded()
        async let second: Void = store.loadIfNeeded()
        _ = await (first, second)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
        XCTAssertTrue(store.canOrganize)
        XCTAssertEqual(store.documents.map(\.id), [document.id])
        XCTAssertTrue(store.isFavorite(document.id))
        XCTAssertEqual(store.contentRevision, 1)
        XCTAssertEqual(store.revision, 1, "Two windows should publish the initial snapshot only once")
    }

    func testBodyCacheEvictsLeastRecentAndBypassesOversizedBodies() async throws {
        let root = temp.appendingPathComponent("App")
        let a = try imported(source("A", body: "aaa"), root: root)
        let b = try imported(source("B", body: "bbb"), root: root)
        let c = try imported(source("C", body: "ccc"), root: root)
        let big = try imported(source("Big", body: String(repeating: "大", count: 500)), root: root)
        let cache = LibraryContent(maxBytes: 128, maxEntries: 2)
        let first = try await cache.markdown(for: a)
        _ = try await cache.markdown(for: b)
        _ = try await cache.markdown(for: a) // A is now the most recently used entry.
        _ = try await cache.markdown(for: c) // B must be evicted.
        try FileManager.default.removeItem(at: a.fileURL)
        try FileManager.default.removeItem(at: b.fileURL)
        let cached = try await cache.markdown(for: a)
        XCTAssertEqual(cached, first)
        do { _ = try await cache.markdown(for: b); XCTFail("Evicted body should be read from disk") }
        catch { }
        let bytesBefore = await cache.retainedBytes
        let oversized = try await cache.markdown(for: big)
        XCTAssertTrue(oversized.contains(String(repeating: "大", count: 500)))
        let bytesAfter = await cache.retainedBytes
        XCTAssertEqual(bytesAfter, bytesBefore, "One large article must not evict useful small entries or escape the budget")
        XCTAssertLessThanOrEqual(bytesAfter, 128)
        try FileManager.default.removeItem(at: big.fileURL)
        do { _ = try await cache.markdown(for: big); XCTFail("Oversized body should not be retained") }
        catch { }
    }

    @MainActor func testIncrementalAndDuplicateImportsNeverReopenExistingBodies() async throws {
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        let firstSource = try source("概率论")
        await store.importItems([firstSource])
        let first = try XCTUnwrap(store.documents.first)
        try FileManager.default.removeItem(at: first.fileURL)
        let revision = store.revision, contentRevision = store.contentRevision
        await store.importItems([firstSource])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.contentRevision, contentRevision)
        await store.importItems([try source("英语")])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertNotNil(store.document(id: first.id))
        XCTAssertEqual(store.revision, revision + 1, "Publish and rebuild once per import batch")
        XCTAssertEqual(store.contentRevision, contentRevision + 1)
        store.toggleFavorite(first.id)
        store.opened(first.id)
        await store.flush()
        XCTAssertEqual(store.contentRevision, contentRevision + 1, "Reading activity must not restart full-text searches")
    }

    @MainActor func testFailedIncrementalSavePreservesPackagesAndBlocksDuplicateImport() async throws {
        let root = temp.appendingPathComponent("App")
        let store = LibraryStore(rootURL: root, seedSamples: false)
        await store.importItems([try source("概率论")])
        let before = store.documents.map(\.id)
        let organizationFile = root.appendingPathComponent("library-organization.json")
        let savedOrganization = try Data(contentsOf: organizationFile)
        try FileManager.default.removeItem(at: organizationFile)
        try FileManager.default.createDirectory(at: organizationFile, withIntermediateDirectories: true)
        let incoming = try source("英语")
        await store.importItems([incoming])
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.documents.map(\.id), before)
        await store.importItems([incoming])
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: store.libraryURL).count, 2)
        try FileManager.default.removeItem(at: organizationFile)
        try savedOrganization.write(to: organizationFile)
        let recovered = LibraryStore(rootURL: root, seedSamples: false)
        await recovered.loadIfNeeded()
        XCTAssertNil(recovered.errorMessage)
        XCTAssertEqual(recovered.documents.count, 2)
    }
}
