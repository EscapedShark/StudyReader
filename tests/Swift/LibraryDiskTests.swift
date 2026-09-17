import XCTest
@testable import StudyReader

final class LibraryDiskTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    func testImportPreservesOriginalsAttachmentsAndStableIDs() throws {
        let source = temp.appendingPathComponent("source")
        let assets = source.appendingPathComponent("assets")
        let library = temp.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let markdown = "# 条件概率\n\n![diagram](assets/a.png)\n\n$P(A)$"
        try Data(markdown.utf8).write(to: source.appendingPathComponent("lesson.md"))
        let imageBytes = Data([1, 2, 3])
        try imageBytes.write(to: assets.appendingPathComponent("a.png"))
        _ = try LibraryDisk.importItem(at: source, into: library)
        let first = try LibraryDisk.load(from: library)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].markdown, markdown)
        XCTAssertEqual(try Data(contentsOf: first[0].rootURL.appendingPathComponent("assets/a.png")), imageBytes)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("lesson.md"), encoding: .utf8), markdown)
        XCTAssertEqual(try LibraryDisk.load(from: library)[0].id, first[0].id)
        if case .duplicate = try LibraryDisk.importItem(at: source, into: library) {} else { XCTFail("Expected duplicate") }
        XCTAssertEqual(try LibraryDisk.load(from: library).count, 1)
    }

    func testChangedAttachmentDoesNotDisappearAsDuplicate() throws {
        let source = temp.appendingPathComponent("source")
        let library = temp.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("# Example\n![a](a.png)".utf8).write(to: source.appendingPathComponent("a.md"))
        let image = source.appendingPathComponent("a.png")
        try Data([1]).write(to: image)
        _ = try LibraryDisk.importItem(at: source, into: library)
        try Data([2]).write(to: image)
        _ = try LibraryDisk.importItem(at: source, into: library)
        XCTAssertEqual(try LibraryDisk.load(from: library).count, 2)
    }

    func testFailedImportDoesNotLeavePartialCollection() throws {
        let source = temp.appendingPathComponent("invalid.md")
        let library = temp.appendingPathComponent("library")
        try Data([0xff, 0xfe, 0xff]).write(to: source)
        XCTAssertThrowsError(try LibraryDisk.importItem(at: source, into: library))
        XCTAssertEqual(try LibraryDisk.load(from: library).count, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [])
    }

    func testAttachmentAccessCannotEscapeLibrary() throws {
        let root = temp.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertNil(LibraryDisk.containedURL(root: root, relativePath: "../secret.txt"))
        XCTAssertNil(LibraryDisk.containedURL(root: root, relativePath: "/etc/passwd"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: temp)
        XCTAssertNil(LibraryDisk.containedURL(root: root, relativePath: "outside/private.txt"))
        XCTAssertNotNil(LibraryDisk.containedURL(root: root, relativePath: "assets/图片.png"))
    }

    func testTitleIgnoresMetadataAndFencedExamples() {
        let input = "---\ntitle: hidden\n---\n```md\n# fake\n```\n# 实际标题\n正文"
        XCTAssertEqual(LibraryDisk.title(from: input, fallback: "文件名"), "实际标题")
    }

    @MainActor func testBundledWebViewRendersMathAndLocalImage() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("samples"))
        let relative = "probability/阅读验收样例.md"
        let content = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [])
        let document = LibraryDocument(record: DocumentRecord(id: UUID(), title: "Sample", relativePath: relative), collection: collection, rootURL: root, markdown: content)
        let reader = ReaderController()
        #if os(iOS)
        reader.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        #else
        reader.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        #endif
        reader.display(document, position: nil, preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: [collection.id.uuidString: root])
        for _ in 0..<150 {
            if !reader.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.isLoading, "Reader did not finish loading bundled resources")
        XCTAssertGreaterThan(reader.outline.count, 5)
        let mathCount = try await reader.webView.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
        XCTAssertGreaterThan(mathCount ?? 0, 20)
        let imageReady = try await reader.webView.evaluateJavaScript("document.querySelector('article img')?.naturalWidth > 0") as? Bool
        XCTAssertEqual(imageReady, true)
        let noPageOverflow = try await reader.webView.evaluateJavaScript("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1") as? Bool
        XCTAssertEqual(noPageOverflow, true, "Math or tables should scroll within their own region")
    }
}
