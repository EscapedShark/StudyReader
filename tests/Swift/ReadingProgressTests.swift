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
        reader.onPosition = { id, position, readAt in store.updatePosition(position, id: id, readAt: readAt) }
        let preferences = ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false)
        reader.display(a, markdown: try LibraryDisk.readMarkdown(for: a), position: nil, preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.67)")
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
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.3)")
        await reader.prepareToLeave()
        XCTAssertEqual(try XCTUnwrap(store.position(for: b.id)).progress, 0.3, accuracy: 0.015)
        reader.display(a, markdown: try LibraryDisk.readMarkdown(for: a), position: store.position(for: a.id), preferences: preferences, roots: store.roots)
        try await waitForReader(reader)
        await checkpoint(reader)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
        let restoredUpdate = store.progressUpdate(for: a.id)
        reader.preferences(ReaderPreferences(fontSize: 24, theme: "light", foldAnswers: false))
        try await Task.sleep(for: .milliseconds(400))
        await checkpoint(reader)
        XCTAssertEqual(store.progressUpdate(for: a.id), restoredUpdate, "Restoring and changing font size must not acquire a new reading timestamp")

        // A queued event from A's previous render cannot overwrite the newly restored session.
        _ = try await reader.webView.callAsyncJavaScript("window.webkit.messageHandlers.reader.postMessage({event:'position',documentID:id,session:session,payload:{anchor:'line-0',excerpt:'A',offset:0,progress:0}})",
                                                        arguments: ["id": a.id.uuidString, "session": oldSession], in: nil, contentWorld: .page)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
        store.flush()
        let reopened = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(try XCTUnwrap(reopened.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(reopened.position(for: b.id)).progress, 0.3, accuracy: 0.015)

        // Zero is still valid when the reader deliberately returns to the top.
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, 0)")
        await checkpoint(reader)
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, 0, accuracy: 0.001)
    }

    @MainActor func testSyncedAnchorSurvivesPhoneWidthAndPassiveCheckpointsCannotOverwriteRemoteProgress() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let cloud = temp.appendingPathComponent("Shared")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("跨屏阅读.md")
        let markdown = "# 概率论\n\n" + (0..<70).map {
            "## 第 \($0) 节\n\n" + String(repeating: "这里是一段验证不同屏幕宽度和字体大小的概率论正文。", count: 5)
        }.joined(separator: "\n\n")
        try Data(markdown.utf8).write(to: source)
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        await a.importItems([source])
        let wide = ReaderController()
        wide.webView.frame = CGRect(x: 0, y: 0, width: 920, height: 800)
        wide.onPosition = { id, position, readAt in a.updatePosition(position, id: id, readAt: readAt) }
        let document = try XCTUnwrap(a.documents.first)
        wide.display(document, markdown: markdown, position: nil,
            preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: a.roots)
        try await waitForReader(wide)
        _ = try await wide.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.67)")
        await wide.prepareToLeave()
        let saved = try XCTUnwrap(a.position(for: document.id))
        await a.connectSyncFolder(cloud, create: true)
        await b.connectSyncFolder(cloud, create: false)
        let phoneDocument = try XCTUnwrap(b.document(id: document.id))
        let narrow = ReaderController()
        narrow.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        narrow.onPosition = { id, position, readAt in b.updatePosition(position, id: id, readAt: readAt) }
        let preferences = ReaderPreferences(fontSize: 24, theme: "light", foldAnswers: false)
        let update = b.progressUpdate(for: document.id)
        narrow.display(phoneDocument, markdown: markdown, position: b.position(for: document.id), preferences: preferences,
            roots: b.roots, preferSavedPosition: true)
        try await waitForReader(narrow)
        let relativeOffset = try await narrow.webView.callAsyncJavaScript("const block = [...document.querySelectorAll('[data-anchor]')].find(el => el.dataset.anchor === anchor); const rect = block.getBoundingClientRect(); return -rect.top / rect.height;",
            arguments: ["anchor": saved.anchor], in: nil, contentWorld: .page) as? Double
        XCTAssertEqual(try XCTUnwrap(relativeOffset), saved.offset, accuracy: 0.03, "Restore the paragraph and its relative offset, not the other screen's absolute scroll distance")
        await checkpoint(narrow)
        XCTAssertEqual(b.progressUpdate(for: document.id), update, "Restoring a remote position does not make it a new local reading action")

        wide.resumeReading()
        _ = try await wide.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, 0)")
        await checkpoint(wide)
        XCTAssertEqual(a.position(for: document.id)?.progress, 0)
        await a.synchronize()
        let scrollBefore = try await narrow.webView.evaluateJavaScript("scrollY") as? Double
        await b.synchronize()
        XCTAssertEqual(b.position(for: document.id)?.progress, 0)
        let scrollAfter = try await narrow.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(scrollBefore, scrollAfter, "Receiving another device's position never jumps the active reader")
        await checkpoint(narrow)
        XCTAssertEqual(b.position(for: document.id)?.progress, 0, "The still-open page must not echo its old geometry over the new checkpoint")
        narrow.display(phoneDocument, markdown: markdown, position: b.position(for: document.id), preferences: preferences,
            roots: b.roots, preferSavedPosition: true)
        try await waitForReader(narrow)
        let resumed = try await narrow.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(try XCTUnwrap(resumed), 0, accuracy: 1)
        await checkpoint(narrow)
        XCTAssertEqual(b.progressUpdate(for: document.id), a.progressUpdate(for: document.id))
    }
}
