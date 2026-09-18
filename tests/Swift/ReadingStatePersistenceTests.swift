import XCTest
@testable import StudyReader

final class ReadingStatePersistenceTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    @MainActor private func store(writer: ReadingStateWriter = ReadingStateWriter()) async throws -> (LibraryStore, UUID) {
        let source = temp.appendingPathComponent("Article.md")
        try Data("# Article\ntext".utf8).write(to: source)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false, automaticSync: false, stateWriter: writer)
        await store.importItems([source])
        return (store, try XCTUnwrap(store.documents.first?.id))
    }

    @MainActor func testCleanFlushAndRestartDoNotRewriteState() async throws {
        let writer = ReadingStateWriter()
        let (store, id) = try await store(writer: writer)
        store.toggleFavorite(id)
        await store.flush()
        let count = await writer.writeCount
        let url = temp.appendingPathComponent("App/reading-state.json")
        let inode = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        for _ in 0..<8 { await store.flush() }
        let after = await writer.writeCount
        XCTAssertEqual(after, count)
        let reloaded = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false, automaticSync: false, stateWriter: writer)
        await reloaded.loadIfNeeded()
        await reloaded.flush()
        XCTAssertTrue(reloaded.isFavorite(id))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber, inode)
    }

    private actor WriteGate {
        var started = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !released else { return }
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    @MainActor func testSlowWriteLeavesMainActorResponsiveAndLatestSnapshotWins() async throws {
        let gate = WriteGate()
        let writer = ReadingStateWriter(beforeWrite: { await gate.wait() })
        let (store, id) = try await store(writer: writer)
        store.toggleFavorite(id)
        let first = Task { await store.flush() }
        let deadline = Date().addingTimeInterval(3)
        while !(await gate.started), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = await gate.started
        XCTAssertTrue(started)
        // This code runs on MainActor while disk persistence is still suspended.
        store.toggleFavorite(id)
        store.updatePosition(ReadingPosition(anchor: "line-2", excerpt: "text", offset: 0, progress: 0.6), id: id)
        let second = Task { await store.flush() }
        await gate.release()
        let results = await (first.value, second.value)
        XCTAssertTrue(results.0 && results.1)
        let stored = try JSONDecoder().decode(LocalReadingState.self, from: Data(contentsOf: temp.appendingPathComponent("App/reading-state.json")))
        XCTAssertFalse(stored.favorites.contains(id))
        XCTAssertEqual(stored.favoriteUpdates[id.uuidString]?.isFavorite, false)
        XCTAssertEqual(stored.positions[id.uuidString]?.progress, 0.6)
    }

    @MainActor func testFailedWriteRemainsDirtyAndCanRetry() async throws {
        let (store, id) = try await store()
        await store.flush()
        let url = temp.appendingPathComponent("App/reading-state.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        store.toggleFavorite(id)
        let failed = await store.flush()
        XCTAssertFalse(failed)
        XCTAssertNotNil(store.errorMessage)
        try FileManager.default.removeItem(at: url)
        let retried = await store.flush()
        XCTAssertTrue(retried)
        let saved = try JSONDecoder().decode(LocalReadingState.self, from: Data(contentsOf: url))
        XCTAssertTrue(saved.favorites.contains(id))
    }
}
