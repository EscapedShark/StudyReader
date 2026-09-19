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

    @MainActor func testCodeHighlightingUsesReadableThemesAndKeepsLongLinesInsideCodeBlocks() async throws {
        let record = DocumentRecord(id: UUID(), title: "代码高亮", relativePath: "code.md")
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [record])
        let document = LibraryDocument(record: record, collection: collection, rootURL: FileManager.default.temporaryDirectory)
        let source = "# 中文注释\ndef average(scores):\n    return sum(scores) / len(scores)\n\nprint(\"平均分\", average([86, 92, 95]))\n" +
            "message = \"" + String(repeating: "这是一段较长的代码", count: 20) + "\"\n"
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 920, height: 700)
        reader.display(document, markdown: "# 代码高亮\n\n```python\n" + source + "```\n\n公式 $x^2$。", position: nil,
            preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: [:])
        try await waitForReader(reader)

        var originalHTML: String?
        var themeColors: [String: String] = [:]
        for width in [920.0, 390.0] {
            reader.webView.frame.size.width = width
            for theme in ["light", "dark", "system"] {
                let result = try await reader.webView.callAsyncJavaScript(#"""
                    await window.Reader.preferences({ fontSize: 18, theme, foldAnswers: false });
                    const code = document.querySelector('pre code'), pre = code.parentElement;
                    const color = element => getComputedStyle(element).color;
                    const luminance = color => {
                        const rgb = color.match(/[\d.]+/g).slice(0, 3).map(n => Number(n) / 255)
                            .map(c => c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
                        return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
                    };
                    const background = luminance(getComputedStyle(pre).backgroundColor);
                    const tokens = [...code.querySelectorAll('span[class*="hljs-"]')];
                    const contrasts = [code, ...tokens].map(element => {
                        const foreground = luminance(color(element));
                        return (Math.max(foreground, background) + 0.05) / (Math.min(foreground, background) + 0.05);
                    });
                    pre.scrollLeft = 100;
                    return { text: code.textContent, html: code.innerHTML, tokens: tokens.length,
                        minContrast: Math.min(...contrasts), keyword: color(code.querySelector('.hljs-keyword')),
                        distinctColors: new Set(tokens.map(color)).size,
                        overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth + 1,
                        codeScrolls: pre.scrollLeft > 0, math: document.querySelectorAll('.katex').length };
                    """#, arguments: ["theme": theme], in: nil, contentWorld: .page) as? [String: Any]
                let values = try XCTUnwrap(result)
                XCTAssertEqual(values["text"] as? String, source)
                XCTAssertGreaterThan(try XCTUnwrap(values["tokens"] as? Int), 10)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["distinctColors"] as? Int), 5)
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(values["minContrast"] as? Double), 4.5)
                XCTAssertEqual(values["overflow"] as? Bool, false)
                XCTAssertEqual(values["codeScrolls"] as? Bool, true)
                XCTAssertEqual(values["math"] as? Int, 1)
                if let originalHTML { XCTAssertEqual(values["html"] as? String, originalHTML) }
                originalHTML = values["html"] as? String
                themeColors[theme] = values["keyword"] as? String
            }
        }
        XCTAssertNotEqual(themeColors["light"], themeColors["dark"])
    }

    #if os(macOS)
    @MainActor func testPageWidthReflowsWithoutLosingTheParagraphAndFitsResizedWindows() async throws {
        let record = DocumentRecord(id: UUID(), title: "页面宽度", relativePath: "width.md")
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [record])
        let document = LibraryDocument(record: record, collection: collection, rootURL: FileManager.default.temporaryDirectory)
        let markdown = "# 页面宽度\n\n" + (0..<60).map {
            "## 第 \($0) 节\n\n" + String(repeating: "这是一段用于验证页面宽度变化后仍保持原阅读段落的正文。", count: 14)
        }.joined(separator: "\n\n")
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 1600, height: 700)
        var preferences = ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false)
        reader.display(document, markdown: markdown, position: nil, preferences: preferences, roots: [:])
        try await waitForReader(reader)

        func layout() async throws -> [String: Any] {
            var result: [String: Any]?
            for _ in 0..<100 {
                result = try await reader.webView.evaluateJavaScript("""
                    (() => {
                        const saved = window.Reader.save();
                        if (!saved) return null;
                        const root = document.documentElement;
                        return {width: document.querySelector('article').getBoundingClientRect().width,
                            viewport: root.clientWidth, overflow: root.scrollWidth > root.clientWidth + 1,
                            anchor: saved.position.anchor, offset: saved.position.offset,
                            sequence: saved.activity?.sequence ?? 0};
                    })()
                    """) as? [String: Any]
                if result != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            return try XCTUnwrap(result, "Page width restoration did not settle")
        }

        let initial = try await layout()
        XCTAssertEqual(try XCTUnwrap(initial["width"] as? Double), 840, accuracy: 1)
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); document.querySelectorAll('p')[25].scrollIntoView()")
        let before = try await layout()
        XCTAssertGreaterThan(try XCTUnwrap(before["sequence"] as? Int), 0)

        for width in [ReaderPageWidth.wide, .full, .standard] {
            preferences.pageWidth = width
            reader.preferences(preferences)
            let after = try await layout()
            // A persistent macOS scrollbar occupies part of the 1600-point WebView.
            // Full width fills the document viewport, which can therefore be narrower.
            let viewport = try XCTUnwrap(after["viewport"] as? Double)
            let expected = width == .full ? viewport : width == .wide ? 1120.0 : 840.0
            XCTAssertEqual(try XCTUnwrap(after["width"] as? Double), expected, accuracy: 1)
            XCTAssertEqual(after["anchor"] as? String, before["anchor"] as? String)
            XCTAssertEqual(try XCTUnwrap(after["offset"] as? Double), try XCTUnwrap(before["offset"] as? Double), accuracy: 0.01)
            XCTAssertEqual(after["sequence"] as? Int, before["sequence"] as? Int, "Reflow must not count as reading activity")
            XCTAssertEqual(after["overflow"] as? Bool, false)
        }

        preferences.pageWidth = .full
        reader.preferences(preferences)
        _ = try await layout()
        reader.reloadReader()
        try await waitForReader(reader)
        let reloaded = try await layout()
        XCTAssertEqual(try XCTUnwrap(reloaded["width"] as? Double), try XCTUnwrap(reloaded["viewport"] as? Double), accuracy: 1,
                       "Recovery must retain full width within the actual viewport")

        for windowWidth in [480.0, 2000.0] {
            reader.webView.frame.size.width = windowWidth
            try await Task.sleep(for: .milliseconds(120))
            let resized = try await layout()
            XCTAssertEqual(try XCTUnwrap(resized["width"] as? Double), try XCTUnwrap(resized["viewport"] as? Double), accuracy: 1)
            XCTAssertEqual(resized["overflow"] as? Bool, false)
        }
    }
    #endif

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
        await store.flush()
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
    @MainActor func testTerminatedReaderReloadsLatestPositionAndRejectsOldSession() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("Recovery.md")
        let markdown = "# Recovery\n\n" + (0..<70).map { "## Section \($0)\n\n正文用于恢复位置。" }.joined(separator: "\n\n")
        try Data(markdown.utf8).write(to: source)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false, automaticSync: false)
        await store.importItems([source])
        let document = try XCTUnwrap(store.documents.first)
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        reader.onPosition = { id, position, readAt in store.updatePosition(position, id: id, readAt: readAt) }
        reader.display(document, markdown: markdown, position: nil,
            preferences: ReaderPreferences(fontSize: 22, theme: "dark", foldAnswers: false), roots: store.roots)
        try await waitForReader(reader)
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.67)")
        await checkpoint(reader)
        let update = try XCTUnwrap(store.progressUpdate(for: document.id))
        let oldSession = try XCTUnwrap(reader.currentSession)
        // Exercise the public WebKit delegate event, then load the real bundled reader again.
        reader.webViewWebContentProcessDidTerminate(reader.webView)
        XCTAssertNotEqual(reader.currentSession, oldSession)
        XCTAssertTrue(reader.isLoading)
        try await waitForReader(reader)
        let restored = try await reader.webView.evaluateJavaScript("window.Reader.save().position.progress") as? Double
        XCTAssertEqual(try XCTUnwrap(restored), update.position.progress, accuracy: 0.02)
        let theme = try await reader.webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String
        XCTAssertEqual(theme, "dark")
        XCTAssertEqual(store.progressUpdate(for: document.id), update, "Automatic recovery is not a new reading action")
        _ = try await reader.webView.callAsyncJavaScript("window.webkit.messageHandlers.reader.postMessage({event:'position',documentID:id,session:session,payload:{anchor:'line-0',excerpt:'wrong',offset:0,progress:0},activity:{sequence:999,readAt:Date.now(),position:{anchor:'line-0',excerpt:'wrong',offset:0,progress:0}}})",
            arguments: ["id": document.id.uuidString, "session": oldSession], in: nil, contentWorld: .page)
        XCTAssertEqual(store.progressUpdate(for: document.id), update)
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, 0)")
        await checkpoint(reader)
        XCTAssertEqual(store.position(for: document.id)?.progress, 0)
        await store.flush()
    }

    @MainActor func testSearchNavigationQueuesUntilReadyUnfoldsTheMatchAndDoesNotReplayAfterRecovery() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("Search.md")
        let markdown = "---\ntitle: ignored\n---\n# 练习\n\n" +
            (0..<35).map { "## 第 \($0) 节\n\n背景材料与公式。" }.joined(separator: "\n\n") +
            "\n\n## 答案\n\n这里的 **Café** 是需要定位的关键词。\n\n## 后续资料\n\n" +
            String(repeating: "下一段内容。\n\n", count: 15)
        try Data(markdown.utf8).write(to: source)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false, automaticSync: false)
        await store.importItems([source])
        let document = try XCTUnwrap(store.documents.first)
        let results = try await store.searchEngine.search(query: "cafe", documents: store.documents, revision: store.contentRevision)
        let target = try XCTUnwrap(results.hits[document.id]?.target)
        XCTAssertNil(store.progressUpdate(for: document.id), "Searching the body is not reading activity")
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        reader.onPosition = { id, position, date in store.updatePosition(position, id: id, readAt: date) }
        // The result can be clicked while ReaderView is still loading the Markdown body.
        reader.revealSearch(target, in: document.id)
        reader.display(document, markdown: markdown, position: nil,
            preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: true), roots: store.roots)
        try await waitForReader(reader)
        for _ in 0..<80 {
            if store.position(for: document.id)?.progress ?? 0 > 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let details = try await reader.webView.evaluateJavaScript("(() => { const mark = document.querySelector('mark.search-highlight'); return {text:mark?.textContent,open:mark?.closest('details')?.open,line:Number(mark?.closest('[data-source-start]')?.dataset.sourceStart),top:mark?.getBoundingClientRect().top}; })()") as? [String: Any]
        XCTAssertEqual(details?["text"] as? String, "Café")
        XCTAssertEqual(details?["open"] as? Bool, true)
        XCTAssertEqual(details?["line"] as? Int, target.sourceLine)
        XCTAssertGreaterThan(try XCTUnwrap(details?["top"] as? Double), 0)
        XCTAssertLessThan(try XCTUnwrap(details?["top"] as? Double), 650)
        XCTAssertGreaterThan(store.position(for: document.id)?.progress ?? 0, 0.5)

        // Clicking an already selected result must jump again without re-rendering its article.
        let session = reader.currentSession
        _ = try await reader.webView.evaluateJavaScript("scrollTo(0,0)")
        reader.revealSearch(target, in: document.id)
        try await Task.sleep(for: .milliseconds(350))
        let repeatedScroll = try await reader.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertGreaterThan(repeatedScroll ?? 0, 1000)
        XCTAssertEqual(reader.currentSession, session)
        reader.clearSearch()
        let marks = try await reader.webView.evaluateJavaScript("document.querySelectorAll('mark.search-highlight').length") as? Int
        XCTAssertEqual(marks, 0)

        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel'));scrollTo(0,0)")
        await checkpoint(reader)
        reader.webViewWebContentProcessDidTerminate(reader.webView)
        try await waitForReader(reader)
        let restored = try await reader.webView.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(try XCTUnwrap(restored), 0, accuracy: 1)
        XCTAssertNil(reader.error)
    }

    @MainActor func testClearingPendingSearchBeforeBodyLoadPreservesTheSavedPosition() async throws {
        let reader = ReaderController()
        let root = FileManager.default.temporaryDirectory
        let record = DocumentRecord(id: UUID(), title: "Cancelled", relativePath: "Cancelled.md")
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [record])
        let document = LibraryDocument(record: record, collection: collection, rootURL: root)
        let markdown = (0..<60).map { "第 \($0) 段关键词。" }.joined(separator: "\n\n")
        reader.revealSearch(ReaderSearchTarget(query: "关键词", matchedText: "关键词", sourceLine: 80), in: document.id)
        reader.clearSearch()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 500, height: 650)
        reader.display(document, markdown: markdown,
            position: ReadingPosition(anchor: "line-20", excerpt: "第 10 段关键词。", offset: 0, progress: 0.2),
            preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: [:])
        try await waitForReader(reader)
        let savedTop = try await reader.webView.evaluateJavaScript("document.querySelector('[data-anchor=\"line-20\"]').getBoundingClientRect().top") as? Double
        XCTAssertEqual(try XCTUnwrap(savedTop), 0, accuracy: 1)
        let matches = try await reader.webView.evaluateJavaScript("document.querySelectorAll('.search-target').length") as? Int
        XCTAssertEqual(matches, 0)
    }

    @MainActor func testRepeatedWebProcessTerminationStopsRetryLoopAndAllowsManualRetry() async throws {
        let reader = ReaderController()
        // No real process kill is needed to validate the delegate's retry budget.
        for _ in 0..<4 { reader.webViewWebContentProcessDidTerminate(reader.webView) }
        XCTAssertTrue(reader.canRetry)
        XCTAssertFalse(reader.isLoading)
        XCTAssertNotNil(reader.error)
        reader.retryLoading()
        XCTAssertFalse(reader.canRetry)
        XCTAssertNil(reader.error)
    }

}
