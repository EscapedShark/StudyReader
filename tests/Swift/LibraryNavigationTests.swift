import XCTest
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import StudyReader

@MainActor final class LibraryNavigationTests: XCTestCase {
    private final class Checkpoint {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func finish() { continuation?.resume(); continuation = nil }
    }

    private func waitForCheckpoint(_ checkpoint: Checkpoint) async {
        for _ in 0..<100 {
            if checkpoint.continuation != nil { return }
            await Task.yield()
        }
        XCTFail("The outgoing article's checkpoint did not start")
    }

    func testPhoneOpensTheSelectedArticleOnlyAfterItsCheckpointCompletes() async throws {
        let navigation = LibraryNavigation(), id = UUID(), checkpoint = Checkpoint()
        navigation.compactColumn = .content
        var activations = 0
        let task = try XCTUnwrap(navigation.select(id, opensReader: true,
            prepare: { await checkpoint.wait() }, activate: { activations += 1 }))
        await waitForCheckpoint(checkpoint)
        XCTAssertNil(navigation.selectedID)
        XCTAssertEqual(navigation.compactColumn, .content, "Do not push an empty detail during the save")
        XCTAssertEqual(activations, 0)
        checkpoint.finish()
        await task.value
        XCTAssertEqual(navigation.selectedID, id)
        XCTAssertEqual(navigation.compactColumn, .detail)
        XCTAssertEqual(activations, 1)
    }

    func testReturningToListThenOpeningTheSameArticlePushesTheReaderAgain() async {
        let navigation = LibraryNavigation(), id = UUID()
        await navigation.select(id, opensReader: true, prepare: {}, activate: {})?.value
        navigation.compactColumn = .content
        var resumes = 0
        let task = navigation.select(id, opensReader: true,
            prepare: { XCTFail("Reopening the current article needs no outgoing save") },
            activate: { resumes += 1 })
        XCTAssertNil(task)
        XCTAssertEqual(navigation.selectedID, id)
        XCTAssertEqual(navigation.compactColumn, .detail)
        XCTAssertEqual(resumes, 1)
    }

    func testRapidArticleChoicesIgnoreAnOlderCheckpointThatFinishesLast() async throws {
        let navigation = LibraryNavigation(), first = UUID(), last = UUID()
        let slow = Checkpoint()
        let firstTask = try XCTUnwrap(navigation.select(first, opensReader: true,
            prepare: { await slow.wait() }, activate: { XCTFail("An obsolete search jump must not activate") }))
        await waitForCheckpoint(slow)
        await navigation.select(last, opensReader: true, prepare: {}, activate: {})?.value
        slow.finish()
        await firstTask.value
        XCTAssertEqual(navigation.selectedID, last)
        XCTAssertEqual(navigation.compactColumn, .detail)
    }

    func testChangingToAnEmptyFolderCancelsThePendingArticleOpen() async throws {
        let navigation = LibraryNavigation(), checkpoint = Checkpoint()
        navigation.compactColumn = .content
        let task = try XCTUnwrap(navigation.select(UUID(), opensReader: true,
            prepare: { await checkpoint.wait() }, activate: { XCTFail("The cancelled article must not activate") }))
        await waitForCheckpoint(checkpoint)
        navigation.select(nil, prepare: {}, activate: {})
        checkpoint.finish()
        await task.value
        XCTAssertNil(navigation.selectedID)
        XCTAssertEqual(navigation.compactColumn, .content)
    }

    func testBackgroundSelectionDoesNotPushThePhoneAndDeletionReturnsToList() async {
        let navigation = LibraryNavigation(), id = UUID()
        navigation.compactColumn = .content
        await navigation.select(id, prepare: {}, activate: {})?.value
        XCTAssertEqual(navigation.compactColumn, .content)
        navigation.select(id, prepare: {}, activate: {})
        XCTAssertEqual(navigation.compactColumn, .content)
        navigation.select(id, opensReader: true, prepare: {}, activate: {})
        await navigation.select(nil, prepare: {}, activate: {})?.value
        XCTAssertNil(navigation.selectedID)
        XCTAssertEqual(navigation.compactColumn, .content)
    }

    #if os(iOS)
    func testCompactSplitViewDisplaysTheReaderAfterBackReopenAndArticleSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = LibraryStore(rootURL: root.appendingPathComponent("Library"), seedSamples: false, automaticSync: false)
        for name in ["A", "B"] {
            let source = root.appendingPathComponent(name + ".md")
            let body = "# \(name)\n\n" + (0..<60).map { "## 第 \($0) 段\n\n这是验证手机导航与阅读位置的正文。" }.joined(separator: "\n\n")
            try Data(body.utf8).write(to: source)
            await store.importItems([source])
        }
        store.notice = nil
        let a = try XCTUnwrap(store.documents.first { $0.title == "A" })
        let b = try XCTUnwrap(store.documents.first { $0.title == "B" })
        let navigation = LibraryNavigation(), reader = ReaderController()
        navigation.compactColumn = .content
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LibraryView(navigation: navigation, reader: reader).environmentObject(store))
        host.traitOverrides.horizontalSizeClass = .compact
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }

        func readerIsVisible() -> Bool {
            guard reader.webView.window === window,
                  reader.webView.convert(reader.webView.bounds, to: window).intersects(window.bounds) else { return false }
            var ancestor: UIView? = reader.webView
            while let view = ancestor {
                if view.isHidden || view.alpha < 0.01 { return false }
                ancestor = view.superview
            }
            return true
        }
        func waitUntil(_ predicate: () -> Bool) async throws {
            for _ in 0..<150 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("The compact reader did not reach the expected visible state")
        }
        func open(_ id: UUID) async throws {
            await navigation.select(id, opensReader: true, prepare: {
                await reader.prepareToLeave()
                await store.flush()
            }, activate: { reader.resumeReading() })?.value
            try await waitUntil { reader.currentDocumentID == id.uuidString && !reader.isLoading && readerIsVisible() }
            XCTAssertNil(reader.error)
        }

        // Exercise the real SwiftUI container and ReaderView loading/lifecycle, using the same
        // committed navigation state as the row button. This is not a synthesized touch test.
        try await Task.sleep(for: .milliseconds(300))
        try await open(a.id)
        _ = try await reader.webView.evaluateJavaScript("dispatchEvent(new WheelEvent('wheel')); scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * 0.67)")
        await reader.prepareToLeave()
        let saved = try XCTUnwrap(store.position(for: a.id))
        XCTAssertEqual(saved.progress, 0.67, accuracy: 0.02)

        navigation.compactColumn = .content
        try await waitUntil { !readerIsVisible() }
        try await open(a.id)
        await reader.prepareToLeave()
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)

        navigation.compactColumn = .content
        try await waitUntil { !readerIsVisible() }
        try await open(b.id)
        navigation.compactColumn = .content
        try await waitUntil { !readerIsVisible() }
        try await open(a.id)
        await reader.prepareToLeave()
        XCTAssertEqual(try XCTUnwrap(store.position(for: a.id)).progress, saved.progress, accuracy: 0.02)
    }
    #endif
}
