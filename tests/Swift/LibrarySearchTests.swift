import XCTest
@testable import StudyReader

/// A provider that deliberately ignores task cancellation, so completions can arrive out of order.
private actor ControlledSearch: LibrarySearching {
    private var pending: [String: CheckedContinuation<LibrarySearchResults, Error>] = [:]
    private var started: Set<String> = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var calls = 0
    func search(query: String, documents: [LibraryDocument], revision: Int) async throws -> LibrarySearchResults {
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
        completeResults(query, with: result.map { ids in
            LibrarySearchResults(hits: Dictionary(uniqueKeysWithValues: ids.map {
                ($0, LibrarySearchHit(documentID: $0, title: LibrarySearchText("", query: ""), snippet: nil, target: nil))
            }))
        })
    }
    func completeResults(_ query: String, with result: Result<LibrarySearchResults, Error>) {
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
        XCTAssertEqual(titleOnly, [id], "A readable title remains searchable even if its body is missing")
    }

    private func fixture(_ root: URL, name: String, body: String?) throws -> LibraryDocument {
        let record = DocumentRecord(id: UUID(), title: name, relativePath: name + ".md")
        if let body { try Data(body.utf8).write(to: root.appendingPathComponent(record.relativePath)) }
        let collection = CollectionManifest(id: UUID(), name: name, importedAt: Date(), fingerprint: "test", documents: [record])
        return LibraryDocument(record: record, collection: collection, rootURL: root)
    }

    @MainActor func testMissingAndInvalidFilesPreserveGoodResultsAndRetryWithoutRevisionChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try fixture(root, name: "完整", body: "# 课程\n\n这里讨论贝叶斯公式。")
        let missing = try fixture(root, name: "遗失", body: nil)
        let invalid = try fixture(root, name: "编码错误", body: nil)
        try Data([0xff, 0xfe, 0xff]).write(to: invalid.fileURL)
        let engine = LibrarySearchEngine(), model = LibrarySearchModel()
        let documents = [missing, good, invalid]
        await model.search(query: "贝叶斯", documents: documents, revision: 1, using: engine, debounceNanoseconds: 0)
        XCTAssertEqual(model.matchedIDs, [good.id])
        XCTAssertEqual(model.issues.map(\.id), [missing.id, invalid.id])
        XCTAssertTrue(model.issues.allSatisfy { !$0.message.isEmpty && !$0.path.isEmpty })
        XCTAssertNil(model.error)
        XCTAssertEqual(model.hits[good.id]?.target?.sourceLine, 2)
        try Data("恢复的贝叶斯笔记".utf8).write(to: missing.fileURL)
        try Data("修复的贝叶斯笔记".utf8).write(to: invalid.fileURL)
        await model.search(query: "贝叶斯", documents: documents, revision: 1, using: engine, debounceNanoseconds: 0)
        XCTAssertEqual(model.matchedIDs, Set(documents.map(\.id)))
        XCTAssertTrue(model.issues.isEmpty)
        await model.search(query: "", documents: documents, revision: 1, using: engine)
        XCTAssertTrue(model.hits.isEmpty)
        XCTAssertTrue(model.issues.isEmpty)
    }

    func testSingleUnreadableFileReturnsAnIssueInsteadOfThrowing() async throws {
        let missing = try fixture(FileManager.default.temporaryDirectory, name: UUID().uuidString, body: nil)
        let result = try await LibrarySearchEngine().search(query: "内容", documents: [missing], revision: 1)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertEqual(result.issues.map(\.id), [missing.id])
    }

    func testSnippetsUseUnicodeRangesAndSourceLinesAfterFrontMatter() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "\u{FEFF}---\r\ntitle: metadata-only\r\n---\r\n# 例题\r\n\r\n" + String(repeating: "背景资料。", count: 100) + "\r\n\r\n👩🏽‍💻 Café 与 conﬁguration 的推导。"
        let document = try fixture(root, name: "Café 笔记", body: body)
        let engine = LibrarySearchEngine()
        for (query, spelling) in [("cafe", "Café"), ("confi", "conﬁ")] {
            let result = try await engine.search(query: query, documents: [document], revision: 1)
            let hit = try XCTUnwrap(result.hits[document.id])
            XCTAssertEqual(hit.target?.sourceLine, 4)
            XCTAssertEqual(hit.target?.matchedText, spelling)
            let snippet = try XCTUnwrap(hit.snippet)
            XCTAssertLessThan(snippet.text.count, 250)
            XCTAssertTrue(snippet.highlights.contains { (snippet.text as NSString).substring(with: $0) == spelling })
            if query == "cafe" { XCTAssertEqual(hit.title.highlights, [NSRange(location: 0, length: 4)]) }
        }
        let prefix = try await engine.search(query: "conf", documents: [document], revision: 1)
        XCTAssertTrue(prefix.hits.isEmpty, "Do not narrow a longer query using the previous query's results")
        let metadata = try await engine.search(query: "metadata-only", documents: [document], revision: 1)
        XCTAssertTrue(metadata.hits.isEmpty, "Hidden front matter is not a paragraph the reader can navigate to")
    }

    @MainActor func testLatePartialFailureCannotReplaceNewerResults() async {
        let engine = ControlledSearch(), model = LibrarySearchModel()
        let old = Task { await model.search(query: "旧", documents: [], revision: 1, using: engine, debounceNanoseconds: 0) }
        await engine.waitForStart("旧")
        await model.search(query: "", documents: [], revision: 1, using: engine)
        await engine.completeResults("旧", with: .success(LibrarySearchResults(issues: [
            LibrarySearchIssue(id: UUID(), title: "旧错误", path: "old.md", message: "文件不存在")
        ])))
        await old.value
        XCTAssertTrue(model.issues.isEmpty)
        XCTAssertTrue(model.hits.isEmpty)
    }

    func testSnippetStaysInTheMatchingParagraphAndMissingTitleStillReportsItsBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let good = try fixture(root, name: "正常资料", body: "$$x^2$$\n\n### 矩阵\n\n$$A=B$$")
        let missing = try fixture(root, name: "矩阵笔记", body: nil)
        let result = try await LibrarySearchEngine().search(query: "矩阵", documents: [good, missing], revision: 1)
        XCTAssertEqual(result.hits[good.id]?.snippet?.text, "### 矩阵")
        XCTAssertEqual(result.hits[good.id]?.target?.sourceLine, 2)
        XCTAssertNotNil(result.hits[missing.id])
        XCTAssertNil(result.hits[missing.id]?.target)
        XCTAssertEqual(result.issues.map(\.id), [missing.id])
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
