import XCTest
@testable import StudyReader

final class LibraryPackageTests: XCTestCase {
    private var temp: URL!
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }
    private func source(_ name: String, image: UInt8) throws -> URL {
        let root = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("课程"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("图片"), withIntermediateDirectories: true)
        try Data([image, 2, 3]).write(to: root.appendingPathComponent("图片/同名.png"))
        try Data("# \(name) 原文\r\n\r\n![示意图](../图片/同名.png)\r\n$P(A)$\r\n".utf8).write(to: root.appendingPathComponent("课程/同名.md"))
        try Data("# 其他文章".utf8).write(to: root.appendingPathComponent("课程/其他.md"))
        return root
    }
    private func write(_ package: PreparedLibraryPackage, name: String) throws -> URL {
        let destination = temp.appendingPathComponent(name)
        try package.fileWrapper().write(to: destination, options: .atomic, originalContentsURL: nil)
        return destination
    }

    @MainActor func testFolderRoundTripPreservesExactBytesRelativeImagesOrderAndCollidingNames() async throws {
        let a = LibraryStore(rootURL: temp.appendingPathComponent("AppA"), seedSamples: false, automaticSync: false)
        await a.importItems([try source("A", image: 11), try source("B", image: 22)])
        let docs = a.documents.filter { $0.title == "同名" }.sorted { $0.collection.name > $1.collection.name }
        XCTAssertEqual(docs.count, 2)
        let folder = try a.createFolder(named: "复习资料")
        try a.moveDocuments(docs.map(\.id), to: folder)
        let package = try await a.exportPackage(documentIDs: a.orderedDocuments(in: folder).map(\.id), name: "复习资料")
        let destination = try write(package, name: "exported")
        let manifest = try XCTUnwrap(LibraryPackageManifest.read(from: destination))
        XCTAssertEqual(manifest.documentPaths.count, 2)
        XCTAssertEqual(package.files.keys.filter { $0.hasSuffix(".md") }.count, 2, "Do not export unrelated articles from the source collections")
        let b = LibraryStore(rootURL: temp.appendingPathComponent("AppB"), seedSamples: false, automaticSync: false)
        await b.importItems([destination])
        XCTAssertNil(b.errorMessage)
        let importedFolder = try XCTUnwrap(b.collections.first)
        XCTAssertEqual(importedFolder.name, "复习资料")
        let imported = b.orderedDocuments(in: importedFolder.id)
        XCTAssertEqual(imported.count, 2)
        for (original, restored) in zip(docs, imported) {
            XCTAssertEqual(try Data(contentsOf: original.fileURL), try Data(contentsOf: restored.fileURL))
            let image = restored.fileURL.deletingLastPathComponent().appendingPathComponent("../图片/同名.png").standardizedFileURL
            XCTAssertEqual(try Data(contentsOf: image), try Data(contentsOf: original.rootURL.appendingPathComponent("图片/同名.png")))
        }
        await b.importItems([destination])
        XCTAssertEqual(b.documents.count, 2, "The same package must remain deduplicated")
        await b.flush()
        let reopened = LibraryStore(rootURL: temp.appendingPathComponent("AppB"), seedSamples: false, automaticSync: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.orderedDocuments(in: importedFolder.id).map(\.id), imported.map(\.id))
        await a.flush(); await reopened.flush()
    }

    @MainActor func testSingleArticleAndEmptyFolderCanBeExportedAndReimported() async throws {
        let a = LibraryStore(rootURL: temp.appendingPathComponent("AppA"), seedSamples: false, automaticSync: false)
        await a.importItems([try source("source", image: 7)])
        let doc = try XCTUnwrap(a.documents.first { $0.title == "同名" })
        let single = try await a.exportPackage(documentIDs: [doc.id], name: doc.title)
        XCTAssertEqual(single.files.keys.filter { $0.hasSuffix(".md") }.count, 1)
        XCTAssertEqual(single.files.keys.filter { $0.hasSuffix(".png") }.count, 1)
        let singleURL = try write(single, name: "single")
        guard case .imported(let docs) = try LibraryDisk.importItem(at: singleURL, into: temp.appendingPathComponent("SingleLibrary")) else {
            return XCTFail("Expected one imported article")
        }
        XCTAssertEqual(docs.count, 1)
        let empty = try await a.exportPackage(documentIDs: [], name: "待学习")
        let emptyURL = try write(empty, name: "empty")
        let b = LibraryStore(rootURL: temp.appendingPathComponent("AppB"), seedSamples: false, automaticSync: false)
        await b.importItems([emptyURL])
        XCTAssertNil(b.errorMessage)
        XCTAssertEqual(b.collections.first?.name, "待学习")
        XCTAssertEqual(b.collections.first?.documentIDs, [])
        await a.flush(); await b.flush()
    }

    func testIncompleteOrEscapingManifestFailsBeforeImportingFiles() throws {
        let root = try source("source", image: 7)
        let missing = LibraryPackageManifest(name: "不完整", documentPaths: ["不存在.md"])
        let manifestURL = root.appendingPathComponent(LibraryPackageManifest.filename)
        try JSONEncoder().encode(missing).write(to: manifestURL)
        let library = temp.appendingPathComponent("Collections")
        XCTAssertThrowsError(try LibraryDisk.importItem(at: root, into: library))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
        let escaping = LibraryPackageManifest(name: "越界", documentPaths: ["../outside.md"])
        try JSONEncoder().encode(escaping).write(to: manifestURL)
        XCTAssertThrowsError(try LibraryDisk.importItem(at: root, into: library))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testExportRejectsMissingAndLinkedAttachmentsWithoutChangingOriginals() throws {
        let root = try source("source", image: 9)
        let library = temp.appendingPathComponent("Collections")
        guard case .imported(let docs) = try LibraryDisk.importItem(at: root, into: library),
              let doc = docs.first(where: { $0.title == "同名" }) else { return XCTFail("Missing fixture") }
        let original = try Data(contentsOf: doc.fileURL)
        let image = doc.rootURL.appendingPathComponent("图片/同名.png")
        try FileManager.default.removeItem(at: image)
        try FileManager.default.createSymbolicLink(at: image, withDestinationURL: root.appendingPathComponent("图片/同名.png"))
        XCTAssertThrowsError(try LibraryPackage.prepare(documents: [doc], name: "export"))
        XCTAssertEqual(try Data(contentsOf: doc.fileURL), original)
        try FileManager.default.removeItem(at: doc.fileURL)
        XCTAssertThrowsError(try LibraryPackage.prepare(documents: [doc], name: "export"))
    }
}
