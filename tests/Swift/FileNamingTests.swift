import XCTest
@testable import StudyReader

final class FileNamingTests: XCTestCase {
    @MainActor func testLegacyHeadingTitlesAndAliasesMigrateFromPathsWithoutReadingBodies() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("真实文件名.md")
        try Data("# 正文标题\n\n内容".utf8).write(to: source)
        let store = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([source])
        let original = try XCTUnwrap(store.documents.first)
        store.toggleFavorite(original.id)
        store.updatePosition(ReadingPosition(anchor: "line-2", excerpt: "内容", offset: 0, progress: 0.6), id: original.id)
        store.flush()
        let metadataURL = original.rootURL.appendingPathComponent(".reader-collection.json")
        // Missing bodies do not prevent correcting cached heading-based names at startup.
        try FileManager.default.removeItem(at: original.fileURL)
        for alias in [nil, true] as [Bool?] {
            let record = DocumentRecord(id: original.id, title: "旧标题或别名", relativePath: original.record.relativePath,
                                        revision: UUID(), usesCustomTitle: alias)
            let manifest = CollectionManifest(id: original.collection.id, name: original.collection.name, importedAt: original.collection.importedAt,
                                              fingerprint: original.collection.fingerprint, documents: [record])
            try JSONEncoder().encode(manifest).write(to: metadataURL, options: .atomic)
            let reopened = LibraryStore(rootURL: temp.appendingPathComponent("App"), seedSamples: false)
            await reopened.loadIfNeeded()
            let migrated = try XCTUnwrap(reopened.document(id: original.id))
            XCTAssertNil(reopened.errorMessage)
            XCTAssertEqual(migrated.title, "真实文件名")
            XCTAssertEqual(migrated.record.title, "真实文件名")
            XCTAssertNil(migrated.record.usesCustomTitle)
            XCTAssertEqual(migrated.record.revision, record.revision)
            XCTAssertEqual(migrated.fileURL, original.fileURL)
            XCTAssertEqual(reopened.organization, store.organization)
            XCTAssertTrue(reopened.isFavorite(original.id))
            XCTAssertEqual(reopened.position(for: original.id)?.progress, 0.6)
            let metadata = try Data(contentsOf: metadataURL)
            XCTAssertEqual(try LibraryDisk.loadMetadata(from: store.libraryURL).first?.record, migrated.record)
            XCTAssertEqual(try Data(contentsOf: metadataURL), metadata)
        }
    }

    @MainActor func testRenamePreservesExactMarkdownBytesAndExistingExtension() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let bodies = ["\u{FEFF}---\r\ntitle: 元数据\r\n---\r\n# 原标题\r\n\r\n正文 $P(A)$\r\n",
                      "资料标题\n=======\n\n正文\n", "```md\n# 代码标题\n```\n\n只有正文，没有标题"]
        for (index, body) in bodies.enumerated() {
            let source = temp.appendingPathComponent("原名称\(index).markdown")
            let bytes = Data(body.utf8)
            try bytes.write(to: source)
            let store = LibraryStore(rootURL: temp.appendingPathComponent("App\(index)"), seedSamples: false)
            await store.importItems([source])
            let document = try XCTUnwrap(store.documents.first)
            try await store.renameDocument(document, to: "新名称.markdown")
            let renamed = try XCTUnwrap(store.document(id: document.id))
            XCTAssertEqual(renamed.title, "新名称")
            XCTAssertEqual(renamed.fileURL.lastPathComponent, "新名称.markdown")
            XCTAssertEqual(try Data(contentsOf: renamed.fileURL), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
}
