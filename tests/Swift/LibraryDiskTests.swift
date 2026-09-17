import XCTest
import ImageIO
import WebKit
import UniformTypeIdentifiers
@testable import StudyReader

final class LibraryDiskTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    /// A real PNG, because the size table reads the file header rather than trusting the manifest.
    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 200, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ReaderFailure(message: "Could not build a test PNG")
        }
        pixels.removeAll()
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAttachmentSizesComeFromTheFilesAndFollowTheContentRevision() async throws {
        let collection = temp.appendingPathComponent("collection")
        let assets = collection.appendingPathComponent("资料图")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try writePNG(width: 1200, height: 800, to: assets.appendingPathComponent("图 1.png"))
        try writePNG(width: 64, height: 64, to: collection.appendingPathComponent("icon.PNG"))
        try Data("# not an image".utf8).write(to: collection.appendingPathComponent("lesson.md"))
        try Data([0, 1, 2, 3]).write(to: collection.appendingPathComponent("broken.png"))

        let sizes = LibraryImageSizes()
        let id = UUID()
        var table = await sizes.sizes(collection: id, root: collection, revision: 1)
        XCTAssertEqual(table["资料图/图 1.png".precomposedStringWithCanonicalMapping], [1200, 800])
        XCTAssertEqual(table["icon.PNG"], [64, 64], "The extension check is case insensitive")
        XCTAssertNil(table["lesson.md"])
        XCTAssertNil(table["broken.png"], "A file that is not a decodable image must not claim a box")

        // Replacing the file is only picked up once the library reports new content.
        try writePNG(width: 300, height: 100, to: assets.appendingPathComponent("图 1.png"))
        table = await sizes.sizes(collection: id, root: collection, revision: 1)
        XCTAssertEqual(table["资料图/图 1.png".precomposedStringWithCanonicalMapping], [1200, 800])
        table = await sizes.sizes(collection: id, root: collection, revision: 2)
        XCTAssertEqual(table["资料图/图 1.png".precomposedStringWithCanonicalMapping], [300, 100])
    }

    func testAttachmentSizeKeysMatchTheURLTheReaderResolves() async throws {
        let source = temp.appendingPathComponent("source")
        let assets = source.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try writePNG(width: 500, height: 250, to: assets.appendingPathComponent("图.png"))
        try Data("# 条件概率\n\n![图](assets/图.png)".utf8).write(to: source.appendingPathComponent("lesson.md"))
        let library = temp.appendingPathComponent("library")
        guard case .imported(let documents) = try LibraryDisk.importItem(at: source, into: library),
              let document = documents.first else { return XCTFail("Expected an imported folder") }

        let table = await LibraryImageSizes().sizes(collection: document.collection.id, root: document.rootURL, revision: 0)
        // What the page asks for: the document's base URL resolved against the Markdown source.
        let resolved = URL(string: "assets/图.png", relativeTo: URL(string: document.baseURL))!.absoluteString
        let path = resolved.components(separatedBy: "/").dropFirst(4).joined(separator: "/")
            .removingPercentEncoding!.precomposedStringWithCanonicalMapping
        XCTAssertEqual(table[path], [500, 250])
    }

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
        let first = try LibraryDisk.loadMetadata(from: library)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0].title, "lesson")
        XCTAssertEqual(first[0].record.title, "lesson")
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: first[0]), markdown)
        XCTAssertEqual(try Data(contentsOf: first[0].rootURL.appendingPathComponent("assets/a.png")), imageBytes)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("lesson.md"), encoding: .utf8), markdown)
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: library)[0].id, first[0].id)
        if case .duplicate = try LibraryDisk.importItem(at: source, into: library) {} else { XCTFail("Expected duplicate") }
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: library).count, 1)
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
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: library).count, 2)
    }

    func testFailedImportDoesNotLeavePartialCollection() throws {
        let source = temp.appendingPathComponent("invalid.md")
        let library = temp.appendingPathComponent("library")
        try Data([0xff, 0xfe, 0xff]).write(to: source)
        XCTAssertThrowsError(try LibraryDisk.importItem(at: source, into: library))
        XCTAssertEqual(try LibraryDisk.loadMetadata(from: library).count, 0)
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

    func testImportedDisplayNameComesFromFilenameIndependentlyOfHeading() throws {
        let input = "---\ntitle: hidden\n---\n```md\n# fake\n```\n# 实际标题\n正文"
        let source = temp.appendingPathComponent("文件名.markdown")
        try Data(input.utf8).write(to: source)
        let library = temp.appendingPathComponent("Collections")
        _ = try LibraryDisk.importItem(at: source, into: library)
        let document = try XCTUnwrap(try LibraryDisk.loadMetadata(from: library).first)
        XCTAssertEqual(document.title, "文件名")
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: document), input)
    }

    @MainActor func testSkippingTheMathMLTwinKeepsGeometryFormulaSourceAndFind() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("samples"))
        let relative = "probability/阅读验收样例.md"
        let content = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [])
        let document = LibraryDocument(record: DocumentRecord(id: UUID(), title: "Sample", relativePath: relative), collection: collection, rootURL: root)
        let reader = ReaderController()
        reader.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.display(document, markdown: content, position: nil,
                       preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false),
                       roots: [collection.id.uuidString: root])
        for _ in 0..<150 {
            if !reader.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(reader.isLoading, "Reader did not finish loading bundled resources")

        func height() async throws -> Double {
            try await reader.webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Double ?? 0
        }
        func set(_ assistive: Bool) async throws {
            _ = try await reader.webView.callAsyncJavaScript("window.Reader.assistive(on); return 1",
                                                             arguments: ["on": assistive], in: nil, in: .page)
            try await Task.sleep(for: .milliseconds(120))
        }

        // The tests run with VoiceOver off, so the twin starts skipped.
        let skipped = try await height()
        try await set(true)
        let rendered = try await height()
        XCTAssertGreaterThan(skipped, 100)
        XCTAssertEqual(skipped, rendered, accuracy: 0.5, "The MathML twin holds no space either way")

        // The LaTeX source stays in the DOM whichever way it is rendered, so copying a formula
        // and matching a saved excerpt keep working.
        try await set(false)
        let source = try await reader.webView.evaluateJavaScript(
            "document.querySelector('annotation[encoding=\"application/x-tex\"]')?.textContent?.length ?? 0") as? Int
        XCTAssertGreaterThan(source ?? 0, 0)

        // Find still locates ordinary body text with the twin skipped.
        let found = await withCheckedContinuation { continuation in
            let configuration = WKFindConfiguration()
            configuration.wraps = true
            reader.webView.find("概率", configuration: configuration) { continuation.resume(returning: $0.matchFound) }
        }
        XCTAssertTrue(found, "Body text must stay searchable while the MathML twin is skipped")
    }

    @MainActor func testBundledWebViewRendersMathAndLocalImage() async throws {
        let root = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("samples"))
        let relative = "probability/阅读验收样例.md"
        let content = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        let collection = CollectionManifest(id: UUID(), name: "Test", importedAt: Date(), fingerprint: "test", documents: [])
        let document = LibraryDocument(record: DocumentRecord(id: UUID(), title: "Sample", relativePath: relative), collection: collection, rootURL: root)
        let reader = ReaderController()
        #if os(iOS)
        reader.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        #else
        reader.webView.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        #endif
        reader.display(document, markdown: content, position: nil, preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: [collection.id.uuidString: root])
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

        // Saving an edit keeps the document ID but must replace cached typesetting and outline.
        reader.display(document, markdown: "# 保存后的文章\n\n## 新目录\n\n$P(A \\mid B)$\n", position: nil,
                       preferences: ReaderPreferences(fontSize: 18, theme: "light", foldAnswers: false), roots: [collection.id.uuidString: root])
        for _ in 0..<100 {
            if !reader.isLoading { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(reader.error)
        XCTAssertFalse(reader.isLoading)
        let savedTitle = try await reader.webView.evaluateJavaScript("document.querySelector('article h1')?.textContent") as? String
        XCTAssertEqual(savedTitle, "保存后的文章")
        XCTAssertEqual(reader.outline.map(\.title), ["保存后的文章", "新目录"])
    }
}
