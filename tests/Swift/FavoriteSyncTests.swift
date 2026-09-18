import XCTest
@testable import StudyReader

final class FavoriteSyncTests: XCTestCase {
    private var temp: URL!
    private var cloud: URL { temp.appendingPathComponent("Shared") }
    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }
    private func source() throws -> URL {
        let url = temp.appendingPathComponent("概率论.md")
        try Data("# 概率论\n原文".utf8).write(to: url)
        return url
    }
    @MainActor private func pair() async throws -> (LibraryStore, LibraryStore, UUID) {
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        await a.importItems([try source()])
        await a.connectSyncFolder(cloud, create: true)
        await b.connectSyncFolder(cloud, create: false)
        return (a, b, try XCTUnwrap(a.documents.first?.id))
    }

    @MainActor func testAddRemoveOfflineRestartAndIdleSyncPreserveContentAndDoNotRewriteState() async throws {
        let (a, b, id) = try await pair()
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        let events = try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path).sorted()
        let article = try XCTUnwrap(b.document(id: id)).fileURL
        let original = try Data(contentsOf: article)
        a.toggleFavorite(id)
        await a.synchronize()
        await b.synchronize()
        XCTAssertTrue(b.isFavorite(id))
        XCTAssertEqual(b.visibleDocuments(filter: "favorites").map(\.id), [id])
        await b.flush()
        // B goes offline with the old addition. A's removal must win after B restarts.
        a.toggleFavorite(id)
        await a.synchronize()
        let restarted = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        defer { restarted.disconnectSyncFolder() }
        await restarted.loadIfNeeded()
        XCTAssertTrue(restarted.isFavorite(id))
        await restarted.synchronize()
        await a.synchronize()
        XCTAssertFalse(restarted.isFavorite(id))
        XCTAssertFalse(a.isFavorite(id))
        XCTAssertTrue(restarted.visibleDocuments(filter: "favorites").isEmpty)
        XCTAssertEqual(try Data(contentsOf: article), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("Changes").path).sorted(), events)
        let localState = temp.appendingPathComponent("A/reading-state.json")
        let inode = try FileManager.default.attributesOfItem(atPath: localState.path)[.systemFileNumber] as? NSNumber
        let snapshots = try FileManager.default.contentsOfDirectory(at: cloud.appendingPathComponent("Favorites"), includingPropertiesForKeys: nil)
        let dates = try snapshots.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        for _ in 0..<3 { await a.synchronize(); await restarted.synchronize() }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: localState.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(try snapshots.map { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }, dates)
        restarted.toggleFavorite(id)
        await restarted.synchronize()
        await a.synchronize()
        XCTAssertTrue(a.isFavorite(id), "A new intentional favorite after the removal must win")
    }

    @MainActor func testDuplicateImportAliasesCarryFavoriteToCanonicalDocument() async throws {
        let file = try source()
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        await a.importItems([file]); await b.importItems([file])
        let canonical = try XCTUnwrap(a.documents.first?.id), local = try XCTUnwrap(b.documents.first?.id)
        XCTAssertNotEqual(canonical, local)
        b.toggleFavorite(local)
        await a.connectSyncFolder(cloud, create: true)
        await b.connectSyncFolder(cloud, create: false)
        await a.synchronize()
        XCTAssertEqual(b.documents.map(\.id), [canonical])
        XCTAssertTrue(a.isFavorite(canonical))
        XCTAssertTrue(b.isFavorite(canonical))
        XCTAssertNil(b.state.favoriteUpdates[local.uuidString])
    }

    @MainActor func testFavoriteBeforeContentAndCorruptSnapshotDoNotLoseLocalData() async throws {
        let a = LibraryStore(rootURL: temp.appendingPathComponent("A"), seedSamples: false, automaticSync: false)
        let b = LibraryStore(rootURL: temp.appendingPathComponent("B"), seedSamples: false, automaticSync: false)
        defer { a.disconnectSyncFolder(); b.disconnectSyncFolder() }
        await a.importItems([try source()])
        let id = try XCTUnwrap(a.documents.first?.id)
        a.toggleFavorite(id)
        let header = try SyncFolderIO.connect(at: cloud, create: true, localRoot: temp.appendingPathComponent("A"))
        _ = try FavoriteSync.exchange(FavoriteSnapshot(library: header.id, device: a.state.readingDeviceID, updates: a.state.favoriteUpdates), in: cloud)
        await b.connectSyncFolder(cloud, create: false)
        XCTAssertTrue(b.documents.isEmpty)
        XCTAssertEqual(b.state.favoriteUpdates[id.uuidString]?.isFavorite, true)
        await a.connectSyncFolder(cloud, create: false)
        await b.synchronize()
        XCTAssertTrue(b.isFavorite(id))
        try Data("broken".utf8).write(to: cloud.appendingPathComponent("Favorites/\(UUID().uuidString).json"))
        try await a.renameDocument(try XCTUnwrap(a.document(id: id)), to: "修改后的文件名")
        await a.synchronize(); await b.synchronize()
        XCTAssertNotNil(b.syncIssue)
        XCTAssertTrue(b.isFavorite(id))
        XCTAssertEqual(b.document(id: id)?.title, "修改后的文件名")
    }

    func testLegacyFavoritesAndEqualTimestampsConvergeWithoutResurrectingRemoval() throws {
        let id = UUID(), deviceA = UUID(), deviceB = UUID()
        let legacy = try JSONDecoder().decode(LocalReadingState.self, from: JSONSerialization.data(withJSONObject: ["favorites": [id.uuidString]]))
        XCTAssertEqual(legacy.favoriteUpdates[id.uuidString]?.updatedAt, .distantPast)
        let added = FavoriteUpdate(device: deviceA, updatedAt: Date(timeIntervalSince1970: 1000), isFavorite: true)
        let removed = FavoriteUpdate(device: deviceB, updatedAt: Date(timeIntervalSince1970: 1000), isFavorite: false)
        var first = [id.uuidString: added], second = [id.uuidString: removed]
        FavoriteSnapshot.merge([id.uuidString: removed], into: &first)
        FavoriteSnapshot.merge([id.uuidString: added], into: &second)
        XCTAssertEqual(first, second)
        var current = [id.uuidString: removed]
        FavoriteSnapshot.merge(legacy.favoriteUpdates, into: &current)
        XCTAssertEqual(current[id.uuidString], removed)
    }
}
