#if os(macOS)
import AppKit
import SwiftUI

/// AppKit owns the complete drag session, including unselected rows, insertion indicators and
/// folder highlighting. SwiftUI remains responsible for navigation and the library model.
struct MacLibraryList: NSViewRepresentable {
    struct Row: Equatable {
        var id: String
        var title: String
        var symbol: String? = nil
        var count: Int? = nil
        var documentID: UUID? = nil
        var folderID: UUID? = nil
        var isHeader = false
        var isFavorite = false
        var progress = 0.0
        var searchHit: LibrarySearchHit? = nil
        func withSearchHit(_ hit: LibrarySearchHit?) -> Row {
            var row = self
            row.searchHit = hit
            return row
        }
    }
    enum DropMode { case folders, reorder, none }
    enum Destination: Equatable {
        case folder(UUID)
        case insertion(Int, visibleIDs: [UUID])
        case folderInsertion(Int, visibleIDs: [UUID])
    }

    var rows: [Row]
    @Binding var selection: String?
    var contextID: String
    var isSidebar = false
    var canDrag = false
    var dropMode: DropMode = .none
    var acceptsDrop: ([UUID], Destination) -> Bool = { _, _ in false }
    var performDrop: ([UUID], Destination) -> Bool = { _, _ in false }
    var menu: (String?) -> NSMenu? = { _ in nil }
    var activate: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var parent: MacLibraryList
        private(set) var table: LibraryTableView!
        private var updatingSelection = false
        private var dragContext: String?
        private var dragOrder: [UUID]?
        private var selectionEvent: Int?

        init(_ parent: MacLibraryList) { self.parent = parent }

        func makeScrollView() -> NSScrollView {
            let scroll = NSScrollView()
            scroll.borderType = .noBorder
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let table = LibraryTableView()
            self.table = table
            table.headerView = nil
            table.style = parent.isSidebar ? .sourceList : .inset
            table.backgroundColor = .clear
            table.focusRingType = .none
            table.allowsMultipleSelection = false
            table.allowsEmptySelection = true
            table.intercellSpacing = NSSize(width: 0, height: 4)
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.autoresizingMask = [.width]
            table.delegate = self
            table.dataSource = self
            table.target = self
            table.action = #selector(activateRow)
            table.registerForDraggedTypes([DocumentDrag.pasteboardType, FolderDrag.pasteboardType])
            table.setDraggingSourceOperationMask(.move, forLocal: true)
            table.setDraggingSourceOperationMask([], forLocal: false)
            table.setAccessibilityLabel(parent.isSidebar ? "资料夹" : "文章列表")
            table.menuForRow = { [weak self] index in
                guard let self else { return nil }
                let id = self.parent.rows.indices.contains(index) ? self.parent.rows[index].id : nil
                return self.parent.menu(id)
            }
            scroll.documentView = table
            table.reloadData()
            update(parent)
            return scroll
        }

        func update(_ value: MacLibraryList) {
            let previous = parent
            parent = value
            updatingSelection = true
            defer { updatingSelection = false }
            if table.numberOfRows != value.rows.count || previous.rows.map(\.id) != value.rows.map(\.id) {
                table.reloadData()
            } else {
                let changed = IndexSet(value.rows.indices.filter { value.rows[$0] != previous.rows[$0] })
                if !changed.isEmpty {
                    table.noteHeightOfRows(withIndexesChanged: changed)
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                }
            }
            let index = value.rows.firstIndex { $0.id == value.selection && !$0.isHeader }
            let indexes = index.map { IndexSet(integer: $0) } ?? []
            if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { parent.rows[row].isHeader }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !parent.rows[row].isHeader }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            parent.rows[row].isHeader ? 28 : (parent.isSidebar ? 30 : (parent.rows[row].searchHit == nil ? 56 : 108))
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection else { return }
            selectionEvent = NSApp.currentEvent?.eventNumber
            let row = table.selectedRow
            let id = parent.rows.indices.contains(row) ? parent.rows[row].id : nil
            if parent.selection != id { parent.selection = id }
        }
        @objc private func activateRow() {
            // Selecting another row already invokes the binding. A second click on the current
            // result must also navigate, without scheduling the same jump twice for one event.
            let event = NSApp.currentEvent?.eventNumber
            let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
            guard event == nil || selectionEvent != event, parent.rows.indices.contains(row) else { return }
            parent.activate?(parent.rows[row].id)
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("library-row")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? LibraryCellView ?? LibraryCellView()
            cell.identifier = identifier
            cell.configure(parent.rows[row], sidebar: parent.isSidebar)
            return cell
        }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            guard parent.canDrag, parent.rows.indices.contains(row) else { return nil }
            if parent.isSidebar, let id = parent.rows[row].folderID {
                dragContext = parent.contextID
                dragOrder = parent.rows.compactMap(\.folderID)
                return FolderDrag.pasteboardItem(for: id)
            }
            guard let id = parent.rows[row].documentID else { return nil }
            dragContext = parent.contextID
            dragOrder = parent.rows.compactMap(\.documentID)
            return DocumentDrag.pasteboardItem(for: id)
        }
        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            dragContext = nil
            dragOrder = nil
        }

        /// Both validation and commit use the same destination policy. Reordering is local to
        /// this visible list; folders accept a move from any article list in this app.
        func destination(for info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> Destination? {
            switch parent.dropMode {
            case .none: return nil
            case .folders:
                if info.draggingPasteboard.availableType(from: [FolderDrag.pasteboardType]) != nil {
                    guard let source = info.draggingSource as? NSTableView, source === table,
                          dragContext == parent.contextID, let order = dragOrder,
                          order == parent.rows.compactMap(\.folderID),
                          let firstFolderRow = parent.rows.firstIndex(where: { $0.folderID != nil }),
                          row >= firstFolderRow else { return nil }
                    // Convert the table insertion gap to an index within user folders. Built-in
                    // sections remain fixed and cannot become drop targets for folder reordering.
                    let gap = min(row, parent.rows.count)
                    return .folderInsertion(parent.rows.prefix(gap).compactMap(\.folderID).count, visibleIDs: order)
                }
                let target = operation == .on ? row : table.row(at: table.convert(info.draggingLocation, from: nil))
                guard parent.rows.indices.contains(target), let id = parent.rows[target].folderID else { return nil }
                return .folder(id)
            case .reorder:
                guard info.draggingPasteboard.availableType(from: [FolderDrag.pasteboardType]) == nil else { return nil }
                guard let source = info.draggingSource as? NSTableView, source === table,
                      dragContext == parent.contextID, let order = dragOrder,
                      order == parent.rows.compactMap(\.documentID) else { return nil }
                return .insertion(min(max(0, row), parent.rows.count), visibleIDs: order)
            }
        }
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingSource != nil, info.draggingSourceOperationMask.contains(.move),
                  let target = destination(for: info, row: row, operation: operation),
                  let ids = try? payload(for: target, from: info.draggingPasteboard),
                  parent.acceptsDrop(ids, target) else { return [] }
            switch target {
            case .folder(let id):
                if let index = parent.rows.firstIndex(where: { $0.folderID == id }) { tableView.setDropRow(index, dropOperation: .on) }
            case .insertion(let index, _): tableView.setDropRow(index, dropOperation: .above)
            case .folderInsertion(let index, _):
                let folderRows = parent.rows.indices.filter { parent.rows[$0].folderID != nil }
                tableView.setDropRow(index < folderRows.count ? folderRows[index] : parent.rows.count, dropOperation: .above)
            }
            return .move
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
            guard info.draggingSource != nil, info.draggingSourceOperationMask.contains(.move),
                  let target = destination(for: info, row: row, operation: operation),
                  let ids = try? payload(for: target, from: info.draggingPasteboard),
                  parent.acceptsDrop(ids, target) else { return false }
            return parent.performDrop(ids, target)
        }

        private func payload(for destination: Destination, from pasteboard: NSPasteboard) throws -> [UUID] {
            if case .folderInsertion = destination { return try FolderDrag.read(pasteboard) }
            return try DocumentDrag.read(pasteboard)
        }
    }
}

final class LibraryTableView: NSTableView {
    var menuForRow: ((Int) -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? {
        menuForRow?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

/// Non-editable AppKit controls leave mouse tracking to NSTableView instead of a NavigationLink.
private final class LibraryCellView: NSTableCellView {
    private let title = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private let accessory = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let snippet = NSTextField(wrappingLabelWithString: "")
    private var titleLeading: NSLayoutConstraint!
    private var titleTrailing: NSLayoutConstraint!
    private var titleCenter: NSLayoutConstraint!
    private var titleTop: NSLayoutConstraint!
    private var snippetConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        snippet.maximumNumberOfLines = 3
        snippet.lineBreakMode = .byTruncatingTail
        snippet.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        accessory.alignment = .right
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .mini
        for view in [title, icon, accessory, progress, snippet] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = title
        imageView = icon
        titleLeading = title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        titleTrailing = title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTop = title.topAnchor.constraint(equalTo: topAnchor, constant: 8)
        snippetConstraints = [
            snippet.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            snippet.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10)
        ]
        NSLayoutConstraint.activate([
            titleLeading, titleTrailing, titleCenter,
            snippet.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            snippet.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18), icon.heightAnchor.constraint(equalToConstant: 18),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: 30),
            progress.leadingAnchor.constraint(equalTo: title.leadingAnchor), progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            progress.widthAnchor.constraint(equalToConstant: 100), progress.heightAnchor.constraint(equalToConstant: 3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ row: MacLibraryList.Row, sidebar: Bool) {
        title.font = .systemFont(ofSize: row.isHeader ? 11 : 13, weight: sidebar ? .regular : .semibold)
        title.textColor = row.isHeader ? .secondaryLabelColor : .labelColor
        title.attributedStringValue = highlighted(row.searchHit?.title ?? LibrarySearchText(row.title, query: ""),
                                                  font: title.font!, color: title.textColor!)
        title.maximumNumberOfLines = sidebar || row.searchHit != nil ? 1 : 2
        titleCenter.isActive = row.searchHit == nil
        titleTop.isActive = row.searchHit != nil
        for constraint in snippetConstraints { constraint.isActive = row.searchHit != nil }
        snippet.isHidden = row.searchHit == nil
        snippet.attributedStringValue = highlighted(row.searchHit?.snippet ?? LibrarySearchText("标题匹配", query: ""),
                                                    font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        icon.image = row.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.contentTintColor = .controlAccentColor
        icon.isHidden = row.symbol == nil
        titleLeading.constant = row.symbol == nil ? 10 : 34
        accessory.stringValue = row.count.map(String.init) ?? (row.isFavorite ? "★" : "")
        accessory.font = .systemFont(ofSize: 11)
        accessory.textColor = row.isFavorite ? .systemOrange : .secondaryLabelColor
        accessory.isHidden = row.count == nil && !row.isFavorite
        titleTrailing.constant = accessory.isHidden ? -10 : -42
        progress.isHidden = sidebar || row.progress <= 0.02
        progress.doubleValue = min(1, max(0, row.progress))
    }
    private func highlighted(_ value: LibrarySearchText, font: NSFont, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: value.text, attributes: [.font: font, .foregroundColor: color])
        for range in value.highlights where NSMaxRange(range) <= result.length {
            result.addAttributes([.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35),
                                  .foregroundColor: NSColor.labelColor], range: range)
        }
        return result
    }
}

/// NSMenuItem's target is weak; keeping the closure on the item ties its lifetime to the menu.
final class LibraryMenuItem: NSMenuItem {
    private let actionBody: () -> Void
    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        actionBody = action
        super.init(title: title, action: #selector(activate), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { actionBody() }
}
#endif
