#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import StudyReader

/// Supplies drag metadata to the real NSTableView data-source callbacks without synthesizing
/// mouse input or using the user's clipboard. UI gesture verification is a separate check.
@MainActor private final class DragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSourceOperationMask: NSDragOperation = .move
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation = NSPoint.zero
    var draggedImageLocation = NSPoint.zero
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: Any?, writer: NSPasteboardWriting) {
        draggingSource = source
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("StudyReaderTests.\(UUID().uuidString)"))
        super.init()
        draggingPasteboard.writeObjects([writer])
    }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    func resetSpringLoading() { }
}

@MainActor final class MacLibraryDragTests: XCTestCase {
    private func rows(_ documents: [LibraryDocument]) -> [MacLibraryList.Row] {
        documents.map { .init(id: $0.id.uuidString, title: $0.title, documentID: $0.id) }
    }
    private func store(at root: URL) async throws -> LibraryStore {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["A", "B", "C"] {
            try Data("# \(name)\n\n$P(A)$".utf8).write(to: source.appendingPathComponent("\(name).md"))
        }
        let store = LibraryStore(rootURL: root.appendingPathComponent("App"), seedSamples: false)
        await store.importItems([source])
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.documents.count, 3)
        return store
    }
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testDragTypeIsDeclaredToTheSystemAsData() throws {
        let declarations = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        for typeIdentifier in [DocumentDrag.typeIdentifier, FolderDrag.typeIdentifier] {
            let declaration = try XCTUnwrap(declarations.first { $0["UTTypeIdentifier"] as? String == typeIdentifier })
            XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], [UTType.data.identifier])
            XCTAssertTrue(try XCTUnwrap(UTType(typeIdentifier)).conforms(to: .data))
        }
    }

    func testUnselectedArticleUsesTheNativeTableDragSource() throws {
        let ids = [UUID(), UUID()]
        let list = MacLibraryList(rows: ids.map { .init(id: $0.uuidString, title: "Article", documentID: $0) },
                                  selection: .constant(ids[0].uuidString), contextID: "all", canDrag: true)
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertTrue(table.dataSource === coordinator)
        XCTAssertTrue(table.registeredDraggedTypes.contains(DocumentDrag.pasteboardType))
        XCTAssertEqual(table.selectedRow, 0)
        let writer = try XCTUnwrap(table.dataSource?.tableView?(table, pasteboardWriterForRow: 1))
        let info = DragInfo(source: table, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(try DocumentDrag.read(info.draggingPasteboard), [ids[1]])
    }

    func testNativeInsertionDropPersistsOrderAndPreservesSelectedDocument() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(at: root)
        let ids = store.documents.map(\.id)
        var selected: String? = ids[0].uuidString
        var list = MacLibraryList(rows: rows(store.documents), selection: Binding(get: { selected }, set: { selected = $0 }),
                                  contextID: "all", canDrag: true, dropMode: .reorder,
                                  acceptsDrop: { _, _ in true }, performDrop: { ids, target in
            guard case .insertion(let index, let visible) = target else { return false }
            do { try store.reorderDocuments(ids, visibleIDs: visible, at: index, folderID: nil); return true }
            catch { XCTFail(error.localizedDescription); return false }
        })
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let writer = try XCTUnwrap(table.dataSource?.tableView?(table, pasteboardWriterForRow: 0))
        let info = DragInfo(source: table, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 3, proposedDropOperation: .above), .move)
        XCTAssertEqual(table.dataSource?.tableView?(table, acceptDrop: info, row: 3, dropOperation: .above), true)
        XCTAssertEqual(store.orderedDocuments(in: nil).map(\.id), [ids[1], ids[2], ids[0]])
        list.rows = rows(store.orderedDocuments(in: nil))
        coordinator.update(list)
        XCTAssertEqual(selected, ids[0].uuidString)
        XCTAssertEqual(table.selectedRow, 2)
        let reopened = LibraryStore(rootURL: root.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.orderedDocuments(in: nil).map(\.id), [ids[1], ids[2], ids[0]])
    }

    func testNativeDropMovesIntoAnEmptySidebarFolderAndSurvivesReload() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(at: root)
        let document = try XCTUnwrap(store.documents.first)
        let original = try Data(contentsOf: document.fileURL)
        let folderID = try store.createFolder(named: "目标")
        let source = MacLibraryList(rows: rows(store.documents), selection: .constant(nil), contextID: "all", canDrag: true).makeCoordinator()
        let sourceScroll = source.makeScrollView()
        let writer = try XCTUnwrap(source.table.dataSource?.tableView?(source.table, pasteboardWriterForRow: 0))
        let info = DragInfo(source: sourceScroll.documentView, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        let target = MacLibraryList(rows: [.init(id: folderID.uuidString, title: "目标", count: 0, folderID: folderID)],
                                    selection: .constant(nil), contextID: "sidebar", isSidebar: true, dropMode: .folders,
                                    acceptsDrop: { _, _ in true }, performDrop: { ids, destination in
            guard case .folder(let id) = destination else { return false }
            do { try store.moveDocuments(ids, to: id); return true }
            catch { XCTFail(error.localizedDescription); return false }
        }).makeCoordinator()
        let targetScroll = target.makeScrollView()
        let table = try XCTUnwrap(targetScroll.documentView as? NSTableView)
        XCTAssertEqual(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on), .move)
        XCTAssertEqual(table.dataSource?.tableView?(table, acceptDrop: info, row: 0, dropOperation: .on), true)
        let reopened = LibraryStore(rootURL: root.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.orderedDocuments(in: folderID).map(\.id), [document.id])
        XCTAssertEqual(reopened.orderedDocuments(in: document.collection.id).count, 2)
        XCTAssertEqual(try Data(contentsOf: document.fileURL), original)
    }

    func testSidebarRejectsNonFolderRowsAndMalformedPayloads() throws {
        let folder = UUID()
        let coordinator = MacLibraryList(rows: [.init(id: "all", title: "全部资料"),
                                                .init(id: folder.uuidString, title: "目标", folderID: folder)],
                                          selection: .constant(nil), contextID: "sidebar", isSidebar: true, dropMode: .folders,
                                          acceptsDrop: { _, _ in true }, performDrop: { _, _ in XCTFail("Rejected drag committed"); return true }).makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let info = DragInfo(source: NSTableView(), writer: DocumentDrag.pasteboardItem(for: UUID()))
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 0, proposedDropOperation: .on), [])
        let malformed = NSPasteboardItem()
        malformed.setData(Data("not-a-document".utf8), forType: DocumentDrag.pasteboardType)
        let invalid = DragInfo(source: NSTableView(), writer: malformed)
        defer { invalid.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(coordinator.tableView(table, validateDrop: invalid, proposedRow: 1, proposedDropOperation: .on), [])
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: invalid, row: 1, dropOperation: .on))
        info.draggingSource = nil
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .on), [])
    }

    func testReorderRejectsAChangedFilterOrOrderDuringTheDrag() throws {
        let ids = [UUID(), UUID()]
        var list = MacLibraryList(rows: ids.map { .init(id: $0.uuidString, title: "Article", documentID: $0) },
                                  selection: .constant(nil), contextID: "all", canDrag: true, dropMode: .reorder,
                                  acceptsDrop: { _, _ in true }, performDrop: { _, _ in XCTFail("Stale drag committed"); return true })
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 0))
        let info = DragInfo(source: table, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        list.contextID = "favorites"
        coordinator.update(list)
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 2, proposedDropOperation: .above), [])
        list.contextID = "all"
        list.rows.reverse()
        coordinator.update(list)
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: info, row: 2, dropOperation: .above))
    }

    func testRecentListAllowsDraggingOutButNotManualReordering() throws {
        let id = UUID()
        let list = MacLibraryList(rows: [.init(id: id.uuidString, title: "Article", documentID: id)],
                                  selection: .constant(nil), contextID: "recent", canDrag: true, dropMode: .none,
                                  acceptsDrop: { _, _ in true })
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 0))
        let info = DragInfo(source: table, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(try DocumentDrag.read(info.draggingPasteboard), [id])
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 1, proposedDropOperation: .above), [])
    }

    func testNativeFolderDragReordersWithoutMovingArticlesOrChangingSelection() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try await store(at: root)
        _ = try store.createFolder(named: "B")
        _ = try store.createFolder(named: "C")
        let order = store.collections.map(\.id)
        let memberships = store.collections.map(\.documentIDs)
        let builtins: [MacLibraryList.Row] = [.init(id: "all", title: "全部资料"), .init(id: "recent", title: "最近阅读"),
                                            .init(id: "favorites", title: "收藏"), .init(id: "heading", title: "资料夹", isHeader: true)]
        var selected: String? = order[0].uuidString
        var list = MacLibraryList(rows: builtins + store.collections.map { .init(id: $0.id.uuidString, title: $0.name, folderID: $0.id) },
                                  selection: Binding(get: { selected }, set: { selected = $0 }), contextID: "sidebar",
                                  isSidebar: true, canDrag: true, dropMode: .folders,
                                  acceptsDrop: { _, _ in true }, performDrop: { ids, destination in
            guard case .folderInsertion(let index, let visible) = destination else { XCTFail("Folder was treated as an article"); return false }
            do { try store.reorderFolders(ids, visibleIDs: visible, at: index); return true }
            catch { XCTFail(error.localizedDescription); return false }
        })
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 3))
        let writer = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 6))
        let info = DragInfo(source: table, writer: writer)
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(try FolderDrag.read(info.draggingPasteboard), [order[2]])
        XCTAssertThrowsError(try DocumentDrag.read(info.draggingPasteboard))
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 2, proposedDropOperation: .above), [])
        XCTAssertEqual(coordinator.tableView(table, validateDrop: info, proposedRow: 4, proposedDropOperation: .on), .move)
        XCTAssertTrue(coordinator.tableView(table, acceptDrop: info, row: 4, dropOperation: .above))
        let expected = [order[2], order[0], order[1]]
        XCTAssertEqual(store.collections.map(\.id), expected)
        XCTAssertEqual(order.map { store.folder(matching: $0.uuidString)?.documentIDs ?? [] }, memberships)
        list.rows = builtins + store.collections.map { .init(id: $0.id.uuidString, title: $0.name, folderID: $0.id) }
        coordinator.update(list)
        XCTAssertEqual(selected, order[0].uuidString)
        XCTAssertEqual(table.selectedRow, 5)
        // A drag started before another reorder cannot commit against the new order.
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: info, row: 7, dropOperation: .above))
        let reopened = LibraryStore(rootURL: root.appendingPathComponent("App"), seedSamples: false)
        await reopened.loadIfNeeded()
        XCTAssertEqual(reopened.collections.map(\.id), expected)
    }

    func testFolderDragCannotBecomeArticleReorderOrCrossWindowFolderMove() throws {
        let id = UUID()
        let list = MacLibraryList(rows: [.init(id: id.uuidString, title: "Article", documentID: id)],
                                  selection: .constant(nil), contextID: "all", canDrag: true, dropMode: .reorder,
                                  acceptsDrop: { _, _ in true })
        let coordinator = list.makeCoordinator()
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? NSTableView)
        _ = coordinator.tableView(table, pasteboardWriterForRow: 0)
        let info = DragInfo(source: table, writer: FolderDrag.pasteboardItem(for: id))
        defer { info.draggingPasteboard.releaseGlobally() }
        XCTAssertFalse(coordinator.tableView(table, acceptDrop: info, row: 1, dropOperation: .above))
        let sidebar = MacLibraryList(rows: [.init(id: id.uuidString, title: "Folder", folderID: id)],
                                     selection: .constant(nil), contextID: "sidebar", isSidebar: true, canDrag: true, dropMode: .folders,
                                     acceptsDrop: { _, _ in true }).makeCoordinator()
        let sidebarScroll = sidebar.makeScrollView()
        let sidebarTable = try XCTUnwrap(sidebarScroll.documentView as? NSTableView)
        _ = sidebar.tableView(sidebarTable, pasteboardWriterForRow: 0)
        XCTAssertFalse(sidebar.tableView(sidebarTable, acceptDrop: info, row: 1, dropOperation: .above))
    }
}
#endif
