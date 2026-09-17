import XCTest
@testable import StudyReader

final class ReadingProgressTests: XCTestCase {
    @MainActor private func waitForReader(_ reader: ReaderController) async throws {
        for _ in 0..<150 {
            if !reader.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.isLoading)
    }

    @MainActor private func checkpoint(_ reader: ReaderController, for id: UUID? = nil, cachedOnly: Bool = false) async {
        await withCheckedContinuation { continuation in
            reader.savePosition(for: id, cachedOnly: cachedOnly) { continuation.resume() }
        }
    }

    @MainActor func testProgressSurvivesEmptyColumnDetachAndSwitchingBetweenArticles() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        for title in ["A", "B"] {
            let source = temp.appendingPathComponent(title + ".md")
            let markdown = "# \(title)\n\n" + (0..<70).map { "## \(title) 第 \($0) 节\n\n这里是用于验证阅读进度的正文。" }.joined(separator: "\n\n")
            try Data(markdown.utf8).write(to: source)
            await store.importItems([source])
        }
        let a = try XCTUnwrap(store.documents.first { $0.title == "A" })
        let b = try XCTUnwrap(store.documents.first { $0.title == "B" })
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        reader.onPosition = { id, position in store.updatePosition(position, id: id) }
        let preferences = ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false)
        reader.display(a, markdown: try LibraryDisk.readMarkdown(for: a), position: nil, preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        _ = try await reader.webView.evaluateJavaScript("scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.67)")
        await reader.prepareToLeave()
        let saved = try XCTUnwrap(store.position(for: a.id))
        XCTAssertEqual(saved.progress, 0.67, accuracy: 0.015)
        let sessionValue = try await reader.webView.evaluateJavaScript("window.Reader.save().session") as? String
        let oldSession = try XCTUnwrap(sessionValue)

        // Entering an empty category removes the WebView. Delayed teardown saves must use
        // the checkpoint taken while the article still had its real size and scroll offset.
        reader.webView.frame = .zero
        _ = try await reader.webView.evaluateJavaScript("scrollTo(0, 0)")
        await checkpoint(reader, for: a.id, cachedOnly: true)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.001)
        reader.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        reader.display(a, markdown: try LibraryDisk.readMarkdown(for: a), position: store.position(for: a.id), preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        await checkpoint(reader)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)

        await reader.prepareToLeave()
        reader.display(b, markdown: try LibraryDisk.readMarkdown(for: b), position: nil, preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        // A disappearing old ReaderView must not act on B, which now owns the shared WebView.
        await checkpoint(reader, for: a.id, cachedOnly: true)
        _ = try await reader.webView.evaluateJavaScript("scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.3)")
        await reader.prepareToLeave()
        XCTAssertEqual(try XCTUnwrap(store.position(for: b.id)).progress, 0.3, accuracy: 0.015)
        reader.display(a, markdown: try LibraryDisk.readMarkdown(for: a), position: store.position(for: a.id), preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        await checkpoint(reader)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)

        // A queued event from A's previous render cannot overwrite the newly restored session.
        _ = try await reader.webView.callAsyncJavaScript("window.webkit.messageHandlers.reader.postMessage({event:'position',documentID:id,session:session,payload:{anchor:'line-0',excerpt:'A',offset:0,progress:0}})",
                                                        arguments: ["id": a.id.uuidString, "session": oldSession], in: nil, in: .page)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
        store.flush()
        let reopened = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(try XCTUnwrap(reopened.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(reopened.position(for: b.id)).progress, 0.3, accuracy: 0.015)

        // Zero is still valid when the reader deliberately returns to the top.
        _ = try await reader.webView.evaluateJavaScript("scrollTo(0, 0)")
        await checkpoint(reader)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, 0, accuracy: 0.001)
    }
}
