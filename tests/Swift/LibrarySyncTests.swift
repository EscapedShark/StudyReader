import XCTest
@testable import StudyReader

final class LibrarySyncTests: XCTestCase {
    private var temp: URL!
    private var cloud: URL!
    private var header: SyncLibraryHeader!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cloud = temp.appendingPathComponent("iCloud Library")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        header = try SyncFolderIO.connect(at: cloud, create: true, localRoot: temp.appendingPathComponent("A"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temp) }

    private func source(_ name: String = "source", body: String = "# 概率论\n\n![图片](../images/a.png)\n\n$$P(A|B)$$") throws -> URL {
        let folder = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("lessons"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("images"), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: folder.appendingPathComponent("lessons/第一课.md"))
        try Data("# 正文第二课\nsecond".utf8).write(to: folder.appendingPathComponent("lessons/第二课.md"))
        try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("images/a.png"))
        return folder
    }

    private final class Replica {
        let root: URL
        var engine: LibrarySyncEngine
        var library: URL { root.appendingPathComponent("Collections") }
        var organizationURL: URL { root.appendingPathComponent("library-organization.json") }
        init(root: URL, libraryID: UUID) throws {
            self.root = root
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            engine = try LibrarySyncEngine(root: root, libraryID: libraryID)
        }
        func docs() throws -> [LibraryDocument] { try LibraryDisk.loadMetadata(from: library) }
        func organization() throws -> LibraryOrganization { try LibraryOrganization.load(from: organizationURL, documents: docs()) }
        func importSource(_ source: URL) throws { _ = try LibraryDisk.importItem(at: source, into: library); _ = try organization() }
        func prepare() async throws { try await engine.prepare(documents: docs(), organization: organization()) }
        func sync(_ cloud: URL) async throws {
            if await engine.needsBootstrap() { _ = try await engine.exchange(with: cloud) }
            try await prepare()
            let result = try await engine.exchange(with: cloud)
            _ = try await engine.install(result.projection, documents: docs(), organization: organization())
        }
        func article(_ id: UUID) throws -> LibraryDocument { try XCTUnwrap(docs().first { $0.id == id }) }
        func edit(_ id: UUID, body: String) throws {
            let doc = try article(id)
            _ = try LibraryDisk.saveMarkdown(body, for: doc, originalMarkdown: LibraryDisk.readMarkdown(for: doc))
        }
    }

    private func replica(_ name: String) throws -> Replica { try Replica(root: temp.appendingPathComponent(name), libraryID: header.id) }
    private func syncedPair() async throws -> (Replica, Replica, UUID) {
        let a = try replica("A"), b = try replica("B")
        try a.importSource(source())
        let id = try XCTUnwrap(a.docs().first { $0.title == "第一课" }?.id)
        try await a.sync(cloud)
        try await b.sync(cloud)
        return (a, b, id)
    }

    func testImportIncludesImagesFoldersOrderAndLeavesOfflineCopies() async throws {
        let a = try replica("A"), b = try replica("B")
        try a.importSource(source())
        var organization = try a.organization()
        let empty = try organization.createFolder(named: "英语")
        try organization.reorderFolders([empty], visibleIDs: organization.folders.map(\.id), at: 0)
        organization.documentOrder.reverse()
        organization.folders[1].documentIDs.reverse()
        try organization.save(to: a.organizationURL)
        try Data("private reading state".utf8).write(to: a.root.appendingPathComponent("reading-state.json"))
        try await a.sync(cloud)
        try await b.sync(cloud)
        XCTAssertEqual(Set(try a.docs().map(\.id)), Set(try b.docs().map(\.id)))
        XCTAssertEqual(try b.organization(), organization)
        for doc in try b.docs() {
            XCTAssertEqual(try LibraryDisk.readMarkdown(for: doc), try LibraryDisk.readMarkdown(for: a.article(doc.id)))
            XCTAssertEqual(try Data(contentsOf: doc.rootURL.appendingPathComponent("images/a.png")), Data([0, 1, 2, 3]))
        }
        let eventNames = try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path)
        try await a.sync(cloud)
        try await b.sync(cloud)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path), eventNames, "Idle checks must not append duplicate edits")
        let offline = cloud.deletingLastPathComponent().appendingPathComponent("offline")
        try FileManager.default.moveItem(at: cloud, to: offline)
        XCTAssertFalse(try LibraryDisk.readMarkdown(for: XCTUnwrap(b.docs().first)).isEmpty)
        XCTAssertEqual(try b.organization(), organization)
        XCTAssertFalse(FileManager.default.fileExists(atPath: offline.appendingPathComponent("reading-state.json").path))
    }

    func testConcurrentEditsKeepOneStableConflictCopyAndItCanBeDeleted() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# 来自 Mac\nalpha")
        try b.edit(id, body: "# 来自 iPhone\nbeta")
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        try await b.sync(cloud)
        let docs = try a.docs()
        XCTAssertEqual(docs.count, 3)
        let conflict = try XCTUnwrap(docs.first { $0.title.contains("冲突副本") })
        let texts = try [a.article(id), conflict].map { try LibraryDisk.readMarkdown(for: $0) }
        XCTAssertEqual(Set(texts), Set(["# 来自 Mac\nalpha", "# 来自 iPhone\nbeta"]))
        XCTAssertEqual(Set(try a.docs().map(\.id)), Set(try b.docs().map(\.id)))
        try a.edit(id, body: "# 合并后的原文")
        try await a.sync(cloud)
        try await b.sync(cloud)
        XCTAssertNotNil(try b.docs().first { $0.id == conflict.id }, "Editing the original must not discard a recovered version")
        _ = try LibraryDisk.deleteDocument(try a.article(conflict.id))
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertFalse(try b.docs().contains { $0.title.contains("冲突副本") })
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), "# 合并后的原文")
    }

    func testRenameAndUnrelatedEditMergeWithoutChangingMarkdownHeading() async throws {
        let (a, b, id) = try await syncedPair()
        let other = try XCTUnwrap(b.docs().first { $0.id != id })
        let original = try LibraryDisk.readMarkdown(for: a.article(id))
        _ = try LibraryDisk.renameDocument(try a.article(id), to: "贝叶斯笔记")
        try b.edit(other.id, body: "# 手机上的新内容")
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertEqual(try b.article(id).title, "贝叶斯笔记")
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), original)
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: a.article(other.id)), "# 手机上的新内容")
        XCTAssertEqual(try a.docs().count, 2)
    }

    func testConcurrentDeletionPreservesUnseenEditAsRecovery() async throws {
        let (a, b, id) = try await syncedPair()
        _ = try LibraryDisk.deleteDocument(try a.article(id))
        try b.edit(id, body: "# 离线写的内容不能丢失")
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertNil(try a.docs().first { $0.id == id })
        let recovered = try XCTUnwrap(a.docs().first { $0.title.contains("冲突副本") })
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: recovered), "# 离线写的内容不能丢失")
        XCTAssertEqual(Set(try a.docs().map(\.id)), Set(try b.docs().map(\.id)))
    }

    func testRecoveryBytesAreIndependentOfUnrelatedMetadataArrival() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# Mac edit")
        try b.edit(id, body: "# Phone edit")
        try await a.prepare()
        try await b.prepare()
        let aCache = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: a.root.appendingPathComponent("sync-state.json")))
        let bCache = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: b.root.appendingPathComponent("sync-state.json")))
        let events = Dictionary((aCache.events + bCache.events).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        let movedFolder = UUID()
        let move = SyncEvent(id: UUID(), device: UUID(), clock: 10, folderNames: [movedFolder.uuidString: "另一资料夹"], memberships: [id.uuidString: movedFolder])
        let withoutMove = try SyncModel.project(Array(events))
        let withMove = try SyncModel.project(Array(events) + [move])
        XCTAssertEqual(withoutMove.recoveries, withMove.recoveries, "Concurrent receivers must write exactly the same immutable recovery event")
        XCTAssertTrue(withMove.organization.folders.contains { $0.name == "冲突资料" })
        let recoveredFolder = SyncModel.stableID("conflict-folder")
        let rename = SyncEvent(id: UUID(), device: UUID(), clock: 11, folderNames: [recoveredFolder.uuidString: "待整理"])
        let renamed = try SyncModel.project(Array(events) + withoutMove.recoveries + [move, rename])
        XCTAssertEqual(renamed.organization.folders.first { $0.id == recoveredFolder }?.name, "待整理")
    }

    func testIdenticalConcurrentBodiesDoNotCreateUnnecessaryConflictCopies() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# 两端输入相同内容")
        try b.edit(id, body: "# 两端输入相同内容")
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertEqual(try a.docs().count, 2)
        XCTAssertEqual(try b.docs().count, 2)
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: a.article(id)), "# 两端输入相同内容")
    }

    func testIndependentFolderChangesAndConcurrentImportsAreNotOverwritten() async throws {
        let (a, b, id) = try await syncedPair()
        var initial = try a.organization()
        let folder = try initial.createFolder(named: "英语")
        try initial.save(to: a.organizationURL)
        try await a.sync(cloud)
        try await b.sync(cloud)
        var aOrg = try a.organization(), bOrg = try b.organization()
        let originalFolder = aOrg.folders[0].id
        try aOrg.renameFolder(originalFolder, to: "概率论资料")
        try aOrg.reorderFolders([folder], visibleIDs: aOrg.folders.map(\.id), at: 0)
        try bOrg.moveDocuments([id], to: folder)
        try aOrg.save(to: a.organizationURL)
        try bOrg.save(to: b.organizationURL)
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertEqual(try a.organization(), try b.organization())
        XCTAssertEqual(try b.organization().folders.first?.id, folder)
        XCTAssertEqual(try b.organization().folders.first { $0.id == originalFolder }?.name, "概率论资料")
        XCTAssertTrue(try b.organization().folders.first { $0.id == folder }!.documentIDs.contains(id))
        try a.importSource(source("mac-import", body: "# Mac new"))
        try b.importSource(source("phone-import", body: "# Phone new"))
        try await a.prepare()
        try await b.prepare()
        try await a.sync(cloud)
        try await b.sync(cloud)
        try await a.sync(cloud)
        XCTAssertEqual(try a.docs().count, 6)
        XCTAssertEqual(Set(try a.docs().map(\.id)), Set(try b.docs().map(\.id)))
    }

    func testPendingBlobDoesNotReplaceOrPruneLocalLibrary() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# 需要下载的新正文")
        try await a.sync(cloud)
        let events = try SyncFolderIO.eventURLs(at: cloud).values.map { try JSONDecoder().decode(SyncEvent.self, from: Data(contentsOf: $0)) }
        let latest = try XCTUnwrap(events.sorted(by: SyncEvent.precedes).last?.articles.first?.article)
        let body = try XCTUnwrap(latest.files.first { $0.path == latest.record.relativePath })
        let blob = cloud.appendingPathComponent("Files/" + body.blob)
        let held = temp.appendingPathComponent("held-blob")
        try FileManager.default.moveItem(at: blob, to: held)
        let oldBody = try LibraryDisk.readMarkdown(for: b.article(id))
        do { try await b.sync(cloud); XCTFail("Installed incomplete content") }
        catch is SyncPending { }
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), oldBody)
        XCTAssertEqual(try b.docs().count, 2)
        try FileManager.default.moveItem(at: held, to: blob)
        try await b.sync(cloud)
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), "# 需要下载的新正文")
    }

    func testOfflineOutboxSurvivesProcessRestart() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# 重启前的离线草稿")
        try await a.prepare()
        let offline = temp.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: cloud, to: offline)
        do { _ = try await a.engine.exchange(with: cloud); XCTFail("Expected unavailable folder") } catch { }
        a.engine = try LibrarySyncEngine(root: a.root, libraryID: header.id)
        try FileManager.default.moveItem(at: offline, to: cloud)
        try await a.sync(cloud)
        try await b.sync(cloud)
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), "# 重启前的离线草稿")
    }

    func testBatchedImportKeepsVersionParentsAndSharesImmutableImageStorage() async throws {
        let a = try replica("BatchA"), b = try replica("BatchB")
        a.engine = try LibrarySyncEngine(root: a.root, libraryID: header.id, eventBatchLimit: 900)
        try a.importSource(source())
        try await a.sync(cloud)
        let cache = try JSONDecoder().decode(SyncCache.self, from: Data(contentsOf: a.root.appendingPathComponent("sync-state.json")))
        XCTAssertGreaterThanOrEqual(cache.events.count, 2)
        for event in cache.events {
            for change in event.articles { XCTAssertEqual(cache.baseline.heads[change.id.uuidString], [event.id]) }
        }
        try await b.sync(cloud)
        let docs = try b.docs()
        XCTAssertEqual(docs.count, 2)
        let images = docs.map { $0.rootURL.appendingPathComponent("images/a.png") }
        let inodes = try images.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }
        XCTAssertEqual(inodes[0], inodes[1], "Shared package images must not consume one full copy per article")
        for doc in docs { try a.edit(doc.id, body: "# 分批导入后编辑 \(doc.id)") }
        try await a.sync(cloud)
        try await b.sync(cloud)
        for doc in try b.docs() { XCTAssertTrue(try LibraryDisk.readMarkdown(for: doc).contains("分批导入后编辑")) }
    }

    func testMissingParentAndUnsafePathsCannotRemoveArticles() throws {
        let id = UUID(), missing = UUID()
        let tombstone = SyncEvent(id: UUID(), device: UUID(), clock: 2, articles: [.init(id: id, parents: [missing], article: nil)])
        XCTAssertThrowsError(try SyncModel.project([tombstone])) { XCTAssertTrue($0 is SyncPending) }
        let article = SyncArticle(record: .init(id: id, title: "escape", relativePath: "../escape.md"), packageName: "test", importedAt: Date(), sourceFingerprint: "test", files: [])
        let bad = SyncEvent(id: UUID(), device: UUID(), clock: 1, articles: [.init(id: id, parents: [], article: article)])
        XCTAssertThrowsError(try SyncModel.project([bad]))
        XCTAssertFalse(SyncModel.validBlob("../anything.md"))
        XCTAssertFalse(SyncModel.validPath("images/../../outside.png"))
        XCTAssertFalse(SyncModel.validPath("images/link/../a.png"))
    }

    func testCorruptDownloadedBytesLeaveOriginalLibraryIntact() async throws {
        let (a, b, id) = try await syncedPair()
        try a.edit(id, body: "# expected bytes")
        try await a.sync(cloud)
        let events = try SyncFolderIO.eventURLs(at: cloud).values.map { try JSONDecoder().decode(SyncEvent.self, from: Data(contentsOf: $0)) }
        let article = try XCTUnwrap(events.sorted(by: SyncEvent.precedes).last?.articles.first?.article)
        let file = try XCTUnwrap(article.files.first { $0.path == article.record.relativePath })
        try Data(repeating: 65, count: file.bytes).write(to: cloud.appendingPathComponent("Files/" + file.blob))
        let previous = try LibraryDisk.readMarkdown(for: b.article(id))
        do { try await b.sync(cloud); XCTFail("Accepted corrupt cloud data") } catch { }
        XCTAssertEqual(try LibraryDisk.readMarkdown(for: b.article(id)), previous)
    }

    func testInterruptedInstallationRollsForwardAtEveryFileBoundary() throws {
        for completed in 0...SyncInstaller.targets.count {
            let root = temp.appendingPathComponent("recovery-\(completed)")
            let name = ".sync-install-\(UUID().uuidString)"
            let staging = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for (index, target) in SyncInstaller.targets.enumerated() {
                let destination = root.appendingPathComponent(target)
                try Data("old-\(target)".utf8).write(to: destination)
                let incoming = staging.appendingPathComponent(target)
                try Data("new-\(target)".utf8).write(to: incoming)
                if index < completed {
                    try FileManager.default.moveItem(at: destination, to: staging.appendingPathComponent("previous-" + target))
                    try FileManager.default.moveItem(at: incoming, to: destination)
                }
            }
            try JSONSerialization.data(withJSONObject: ["directory": name]).write(to: root.appendingPathComponent(".sync-transaction.json"))
            try SyncInstaller.recover(in: root)
            for target in SyncInstaller.targets { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(target)), Data("new-\(target)".utf8)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
            try SyncInstaller.recover(in: root)
        }
    }

    @MainActor func testStoreConnectionDeduplicatesAndPreservesProgressBackupAndDisconnect() async throws {
        let source = try source()
        let a = LibraryStore(rootURL: temp.appendingPathComponent("StoreA"), seedSamples: false, automaticSync: false)
        let bRoot = temp.appendingPathComponent("StoreB")
        let b = LibraryStore(rootURL: bRoot, seedSamples: false, automaticSync: false)
        await a.importItems([source])
        await b.importItems([source])
        let oldID = try XCTUnwrap(b.documents.first { $0.title == "第一课" }?.id)
        b.toggleFavorite(oldID)
        b.updatePosition(ReadingPosition(anchor: "a", excerpt: "test", offset: 10, progress: 0.72), id: oldID)
        b.flush()
        await a.connectSyncFolder(cloud, create: false)
        XCTAssertNil(a.syncIssue)
        await b.connectSyncFolder(cloud, create: false)
        XCTAssertNil(b.syncIssue)
        XCTAssertEqual(b.documents.count, 2)
        XCTAssertEqual(Set(a.documents.map(\.id)), Set(b.documents.map(\.id)))
        let newID = try XCTUnwrap(a.documents.first { $0.title == "第一课" }?.id)
        XCTAssertTrue(b.isFavorite(newID))
        XCTAssertEqual(b.position(for: newID)?.progress, 0.72)
        XCTAssertNil(a.position(for: newID), "This phase must not upload local reading state")
        let backups = try FileManager.default.contentsOfDirectory(at: bRoot.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backups[0].appendingPathComponent("reading-state.json").path))
        let renamed = try XCTUnwrap(a.document(id: newID))
        try await a.renameDocument(renamed, to: "新文件名")
        await a.synchronize()
        await b.synchronize()
        XCTAssertEqual(b.document(id: newID)?.title, "新文件名")
        XCTAssertEqual(b.position(for: newID)?.progress, 0.72)
        let restored = LibraryStore(rootURL: bRoot, seedSamples: false, automaticSync: false)
        await restored.loadIfNeeded()
        XCTAssertEqual(restored.syncConnection?.libraryID, header.id)
        XCTAssertEqual(restored.position(for: newID)?.progress, 0.72)
        restored.disconnectSyncFolder()
        XCTAssertNil(restored.syncConnection)
        XCTAssertEqual(restored.documents.count, 2)
        XCTAssertEqual(restored.position(for: newID)?.progress, 0.72)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloud.appendingPathComponent(SyncFolderIO.headerName).path))
        b.disconnectSyncFolder()
        a.disconnectSyncFolder()
    }

    @MainActor func testAutomaticChangesReachOtherConnectedReplica() async throws {
        let a = LibraryStore(rootURL: temp.appendingPathComponent("AutomaticA"), seedSamples: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("AutomaticB"), seedSamples: false)
        await a.importItems([try source()])
        await a.connectSyncFolder(cloud, create: false)
        await b.connectSyncFolder(cloud, create: false)
        XCTAssertNil(a.syncIssue)
        XCTAssertNil(b.syncIssue)
        let id = try a.createFolder(named: "自动更新的资料夹")
        let deadline = Date().addingTimeInterval(12)
        while !b.collections.contains(where: { $0.id == id }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(b.collections.first { $0.id == id }?.name, "自动更新的资料夹", "A local mutation and file-presenter notification should synchronize without pressing Refresh")
        a.syncSceneChanged(isActive: false)
        b.syncSceneChanged(isActive: false)
        while a.isSyncing || b.isSyncing { try await Task.sleep(for: .milliseconds(100)) }
        a.disconnectSyncFolder()
        b.disconnectSyncFolder()
    }

    func testCreationRejectsNonEmptyFolderAndLinkedStorage() throws {
        let occupied = temp.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        let original = occupied.appendingPathComponent("keep.md")
        try Data("keep".utf8).write(to: original)
        XCTAssertThrowsError(try SyncFolderIO.connect(at: occupied, create: true, localRoot: temp.appendingPathComponent("local")))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")
        XCTAssertThrowsError(try SyncFolderIO.connect(at: cloud, create: true, localRoot: temp.appendingPathComponent("local")))
        let link = cloud.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: occupied)
        XCTAssertThrowsError(try SyncFolderIO.child("linked/keep.md", in: cloud))
    }
}
