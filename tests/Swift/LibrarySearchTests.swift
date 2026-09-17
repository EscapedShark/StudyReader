import XCTest
@testable import StudyReader

/// A provider that deliberately ignores task cancellation, so completions can arrive out of order.
private actor ControlledSearch: LibrarySearching {
    private var pending: [String: CheckedContinuation<Set<UUID>, Error>] = [:]
    private var started: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls = 0
    func matches(query: String, documents: [LibraryDocument], revision: Int) async throws -> Set<UUID> {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[query] = continuation
            started.insert(query)
            waiters.removeValue(forKey: query)?.resume()
        }
    }
    func waitForStart(_ query: String) async {
        if started.contains(query) { return }
        await withCheckedContinuation { waiters[query] = $0 }
    }
    func complete(_ query: String, with result: Result<Set<UUID>, Error>) {
        pending.removeValue(forKey: query)?.resume(with: result)
    }
}

final class LibrarySearchTests: XCTestCase {
    func testSearchMatchesLocalizedTitlesAndBodiesAndInvalidatesOnImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("lesson.md")
        try Data("# Café\n\n贝叶斯公式与 Conditional Probability".utf8).write(to: source)
        let library = root.appendingPathComponent("Collections")
        guard case .imported(let documents) = try LibraryDisk.importItem(at: source, into: library) else {
            XCTFail("Expected imported documents"); return
        }
        let id = documents[0].id
        let engine = LibrarySearchEngine()
        for query in ["cafe", "贝叶斯", "conditional probability"] {
            let result = try await engine.matches(query: query, documents: documents, revision: 1)
            XCTAssertEqual(result, [id])
        }
        let miss = try await engine.matches(query: "新增内容", documents: documents, revision: 1)
        XCTAssertTrue(miss.isEmpty)
        try Data("# Café\n\n新增内容".utf8).write(to: documents[0].fileURL)
        let cachedMiss = try await engine.matches(query: "新增内容", documents: documents, revision: 1)
        XCTAssertTrue(cachedMiss.isEmpty, "Unchanged corpus revisions reuse their search result")
        let refreshed = try await engine.matches(query: "新增内容", documents: documents, revision: 2)
        XCTAssertEqual(refreshed, [id])
        try FileManager.default.removeItem(at: documents[0].fileURL)
        let cachedBody = try await engine.matches(query: "新增内容", documents: documents, revision: 2)
        XCTAssertEqual(cachedBody, [id], "A cache hit must not reopen Markdown")
        let titleOnly = try await engine.matches(query: "LESSON", documents: documents, revision: 2)
        XCTAssertEqual(titleOnly, [id], "Matching filenames should not read the body")
    }

    @MainActor func testLateSuccessCannotReplaceNewerSearch() async {
        let engine = ControlledSearch(), model = LibrarySearchModel()
        let old = Task { await model.search(query: "旧", documents: [], revision: 1, using: engine, debounceNanoseconds: 0) }
        await engine.waitForStart("旧")
        let new = Task { await model.search(query: "新", documents: [], revision: 1, using: engine, debounceNanoseconds: 0) }
        await engine.waitForStart("新")
        let expected = UUID()
        await engine.complete("新", with: .success([expected]))
        await new.value
        let resultToken = model.resultToken
        await engine.complete("旧", with: .success([UUID()]))
        await old.value
        XCTAssertEqual(model.matchedIDs, [expected])
        XCTAssertEqual(model.resultToken, resultToken)
        XCTAssertTrue(model.isCurrent(query: "新", revision: 1))
        XCTAssertFalse(model.isSearching)
    }

    @MainActor func testLateErrorCannotReplaceClearedSearch() async {
        let engine = ControlledSearch(), model = LibrarySearchModel()
        let old = Task { await model.search(query: "旧", documents: [], revision: 1, using: engine, debounceNanoseconds: 0) }
        await engine.waitForStart("旧")
        await model.search(query: "", documents: [], revision: 1, using: engine)
        await engine.complete("旧", with: .failure(ReaderFailure(message: "Outdated failure")))
        await old.value
        XCTAssertNil(model.error)
        XCTAssertTrue(model.matchedIDs.isEmpty)
        XCTAssertTrue(model.isCurrent(query: "", revision: 1))
        XCTAssertFalse(model.isSearching)
    }

    @MainActor func testCancelledDebounceDoesNotStartDiskSearch() async {
        let engine = ControlledSearch(), model = LibrarySearchModel()
        let task = Task { await model.search(query: "取消", documents: [], revision: 1, using: engine) }
        task.cancel()
        await task.value
        let calls = await engine.calls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isSearching)
    }
}
