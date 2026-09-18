import XCTest
@testable import StudyReader

final class ReadingProgressSyncTests: XCTestCase {
    private var temp: URL!
    private var cloud: URL { temp.appendingPathComponent("Shared") }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func position(_ progress: Double) -> ReadingPosition {
        ReadingPosition(anchor: "line-12", excerpt: "用于同步的正文", offset: 0.25, progress: progress)
    }

    @MainActor private func pair(automatic: Bool = false) async throws -> (LibraryStore, LibraryStore, UUID) {
        let source = temp.appendingPathComponent("概率论.md")
        try Data("# 概率论\n\n用于同步的正文\n".utf8).write(to: source)
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: automatic)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: automatic)
        await a.importItems([source])
        await a.connectSyncFolder(cloud, create: true)
        await b.connectSyncFolder(cloud, create: false)
        XCTAssertNil(a.syncIssue)
        XCTAssertNil(b.syncIssue)
        return (a, b, try XCTUnwrap(a.documents.first?.id))
    }

    @MainActor func testLatestReadingWinsAcrossOfflineRestartAndCanMoveBackToZero() async throws {
        let (a, b, id) = try await pair()
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        let articleURL = try XCTUnwrap(b.document(id: id)).fileURL
        let original = try Data(contentsOf: articleURL)
        let eventsBefore = try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path).sorted()
        a.updatePosition(position(0.8), id: id, readAt: Date(timeIntervalSince1970: 1000))
        await a.synchronize()
        await b.synchronize()
        XCTAssertEqual(b.position(for: id), position(0.8))

        // Both read offline from the 80% checkpoint. The later reader deliberately rereads an
        // earlier section; uploading the older 90% checkpoint afterwards must not undo that.
        a.updatePosition(position(0.9), id: id, readAt: Date(timeIntervalSince1970: 2000))
        await a.flush()
        b.updatePosition(position(0.25), id: id, readAt: Date(timeIntervalSince1970: 3000))
        await b.synchronize()
        let restarted = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        defer { restarted.disconnectSyncFolder() }
        await restarted.loadIfNeeded()
        XCTAssertEqual(restarted.position(for: id), position(0.9))
        await restarted.synchronize()
        await b.synchronize()
        XCTAssertEqual(restarted.position(for: id), position(0.25))
        XCTAssertEqual(b.position(for: id), position(0.25))
        XCTAssertEqual(restarted.progressUpdate(for: id)?.updatedAt, Date(timeIntervalSince1970: 3000))
        restarted.updatePosition(position(0.95), id: id, readAt: Date(timeIntervalSince1970: 2500))
        XCTAssertEqual(restarted.position(for: id), position(0.25), "A delayed older WebKit action cannot be retimestamped after a remote update")

        restarted.updatePosition(position(0), id: id, readAt: Date(timeIntervalSince1970: 4000))
        await restarted.synchronize()
        await b.synchronize()
        XCTAssertEqual(b.position(for: id)?.progress, 0)
        XCTAssertEqual(try Data(contentsOf: articleURL), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path).sorted(), eventsBefore,
                       "Reading does not create article edits or rewrite article files")

        // After convergence, checks should not touch either device's snapshot again.
        await restarted.synchronize()
        await b.synchronize()
        let files = try FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("Reading"), includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        let dates = try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        await restarted.synchronize()
        await b.synchronize()
        XCTAssertEqual(try files.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }, dates)
    }

    @MainActor func testReadingMetadataCanArriveBeforeTheArticle() async throws {
        let source = temp.appendingPathComponent("尚未下载.md")
        try Data("# 稍后到达的正文".utf8).write(to: source)
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        await a.importItems([source])
        let id = try XCTUnwrap(a.documents.first?.id)
        let header = try SyncFolderIO.connect(at: cloud, create: true, localRoot: temp.appendingPathComponent("A"))
        a.updatePosition(position(0.65), id: id)
        let snapshot = ReadingProgressSnapshot(library: header.id, device: a.state.readingDeviceID, updates: a.state.progressUpdates)
        _ = try ReadingProgressSync.exchange(snapshot, in: cloud)
        await b.connectSyncFolder(cloud, create: false)
        XCTAssertTrue(b.documents.isEmpty)
        XCTAssertNil(b.position(for: id))
        XCTAssertEqual(b.progressUpdate(for: id)?.position.progress, 0.65)
        await a.connectSyncFolder(cloud, create: false)
        await b.synchronize()
        XCTAssertEqual(b.documents.count, 1)
        XCTAssertEqual(b.position(for: id)?.progress, 0.65)
    }

    @MainActor func testUnavailableAndInvalidCloudProgressPreservesLocalReadingAndDoesNotBlockContent() async throws {
        let (a, b, id) = try await pair()
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        a.updatePosition(position(0.6), id: id)
        await a.flush()
        let unavailable = temp.appendingPathComponent("Unavailable")
        try FileManager.default.moveItem(at: cloud, to: unavailable)
        await a.synchronize()
        XCTAssertNotNil(a.syncIssue)
        XCTAssertEqual(a.position(for: id)?.progress, 0.6)
        try FileManager.default.moveItem(at: unavailable, to: cloud)
        await a.synchronize()
        await b.synchronize()
        XCTAssertEqual(b.position(for: id)?.progress, 0.6)

        let remoteDevice = UUID()
        let bad = ReadingProgressSnapshot(library: try XCTUnwrap(a.syncConnection?.libraryID), device: remoteDevice,
            updates: [id.uuidString: ReadingProgressUpdate(device: remoteDevice, updatedAt: Date(), position: position(5))])
        try SyncFolderIO.encoder.encode(bad).write(to: cloud.appendingPathComponent("Reading/\(remoteDevice.uuidString).json"))
        try await a.renameDocument(try XCTUnwrap(a.document(id: id)), to: "正文仍可同步")
        await a.synchronize()
        await b.synchronize()
        XCTAssertNotNil(b.syncIssue)
        XCTAssertEqual(b.position(for: id)?.progress, 0.6)
        XCTAssertEqual(b.document(id: id)?.title, "正文仍可同步")
    }

    @MainActor func testReadingAutomaticallyReachesOtherConnectedDevice() async throws {
        let (a, b, id) = try await pair(automatic: true)
        a.updatePosition(position(0.73), id: id)
        let deadline = Date().addingTimeInterval(12)
        while b.position(for: id)?.progress != 0.73, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(b.position(for: id)?.progress, 0.73)
        a.syncSceneChanged(isActive: false)
        b.syncSceneChanged(isActive: false)
        while a.isSyncing || b.isSyncing { try await Task.sleep(for: .milliseconds(100)) }
        a.disconnectSyncFolder()
        b.disconnectSyncFolder()
    }

    func testLegacyLocalProgressMigratesWithoutUsingConnectionTime() throws {
        let id = UUID()
        let old: [String: Any] = ["favorites": [], "positions": [id.uuidString: ["anchor": "line-12", "excerpt": "旧文章", "offset": 0.2, "progress": 0.72]],
                                  "lastOpened": [id.uuidString: 1000.0]]
        let state = try JSONDecoder().decode(LocalReadingState.self, from: JSONSerialization.data(withJSONObject: old))
        let update = try XCTUnwrap(state.progressUpdates[id.uuidString])
        XCTAssertEqual(update.updatedAt, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(update.position, state.positions[id.uuidString])
        let reopened = try JSONDecoder().decode(LocalReadingState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened.readingDeviceID, state.readingDeviceID)
        XCTAssertEqual(reopened.progressUpdates, state.progressUpdates)
    }

    func testEqualTimestampConvergesInEitherArrivalOrderAndWrongLibraryIsRejected() throws {
        let header = try SyncFolderIO.connect(at: cloud, create: true, localRoot: temp.appendingPathComponent("A"))
        let doc = UUID(), deviceA = UUID(), deviceB = UUID()
        let first = ReadingProgressSnapshot(library: header.id, device: deviceA,
            updates: [doc.uuidString: ReadingProgressUpdate(device: deviceA, updatedAt: Date(timeIntervalSince1970: 1000), position: position(0.7))])
        let second = ReadingProgressSnapshot(library: header.id, device: deviceB,
            updates: [doc.uuidString: ReadingProgressUpdate(device: deviceB, updatedAt: Date(timeIntervalSince1970: 1000), position: position(0.3))])
        _ = try ReadingProgressSync.exchange(first, in: cloud)
        let resultB = try ReadingProgressSync.exchange(second, in: cloud)
        let resultA = try ReadingProgressSync.exchange(first, in: cloud)
        XCTAssertEqual(resultA.updates, resultB.updates)
        XCTAssertEqual(try ReadingProgressSync.exchange(second, in: cloud).updates, resultA.updates)
        var wrong = first
        wrong.library = UUID()
        XCTAssertThrowsError(try ReadingProgressSync.exchange(wrong, in: cloud))
    }
}
