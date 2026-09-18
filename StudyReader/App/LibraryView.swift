import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    /// One reader is kept for the whole session. Rebuilding it per article would reload the
    /// offline typesetting bundle and fonts every time the selection changes.
    @StateObject private var reader: ReaderController
    @StateObject private var searchModel = LibrarySearchModel()
    @State private var filter: String? = "all"
    @StateObject private var navigation: LibraryNavigation
    @State private var search = ""
    @State private var searchRetry = 0
    @State private var showSearchIssues = false
    @State private var showImporter = false
    @State private var showPackageExport = false
    @State private var preparedPackage: PreparedLibraryPackage?
    @State private var importFolder = false
    @State private var importTargetID: UUID?
    @State private var showNewFolder = false
    @State private var showSyncSettings = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?
    @State private var documentToDelete: LibraryDocument?
    @State private var documentToRename: LibraryDocument?
    @State private var folderToRename: LibraryFolder?
    @State private var folderToDelete: LibraryFolder?
    @State private var targetedFolderID: UUID?
    #if os(iOS)
    @State private var folderEditMode: EditMode = .inactive
    #endif
    @FocusState private var folderNameFocused: Bool

    @MainActor init(navigation: LibraryNavigation? = nil, reader: ReaderController? = nil) {
        _navigation = StateObject(wrappedValue: navigation ?? LibraryNavigation())
        _reader = StateObject(wrappedValue: reader ?? ReaderController())
    }

    private var selectedID: UUID? { navigation.selectedID }
    private var selectedFolderID: UUID? { library.folder(matching: filter)?.id }
    private var title: String {
        switch filter {
        case "favorites": return "收藏"
        case "recent": return "最近阅读"
        case "all", nil: return "全部资料"
        default: return library.folder(matching: filter)?.name ?? "资料"
        }
    }
    private struct SearchRequest: Equatable { var query: String; var revision: Int; var retry: Int }
    private var searchRequest: SearchRequest { SearchRequest(query: search, revision: library.contentRevision, retry: searchRetry) }
    private var searchPending: Bool { !search.isEmpty && (searchModel.isSearching || !searchModel.isCurrent(query: search, revision: library.contentRevision)) }
    private var visibleDocuments: [LibraryDocument] {
        guard !searchPending else { return [] }
        return library.visibleDocuments(filter: filter, matching: search.isEmpty ? nil : searchModel.matchedIDs,
                                        searchToken: search.isEmpty ? nil : searchModel.resultToken)
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $navigation.compactColumn) {
            sidebar
        } content: {
            documentList
        } detail: {
            if let document = library.document(id: selectedID) {
                ReaderView(document: document, controller: reader)
            } else {
                ContentUnavailableView("从一篇资料开始", systemImage: "book.pages",
                                       description: Text("选择左侧文章，安静地读一会儿。\n支持 Markdown、数学公式和本地图片。"))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await library.loadIfNeeded()
            #if os(macOS)
            if selectedID == nil { updateSelection(reset: true) }
            #endif
        }
        .task(id: searchRequest) {
            await searchModel.search(query: search, documents: library.documents, revision: library.contentRevision, using: library.searchEngine)
        }
        .onChange(of: searchRequest) { _, _ in reader.clearSearch() }
        .sheet(isPresented: $showSearchIssues) { searchIssuesView }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importFolder ? [.folder] : [UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "markdown") ?? .plainText, .plainText],
                      allowsMultipleSelection: !importFolder) { result in
            switch result {
            case .success(let urls):
                let destination = importTargetID
                Task { await library.importItems(urls, intoFolderID: destination) }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showPackageExport, document: preparedPackage.map { LibraryExportDocument(package: $0) },
                      contentType: .folder, defaultFilename: preparedPackage?.name ?? "资料包") { result in
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
            preparedPackage = nil
        }
        .onChange(of: showPackageExport) { _, shown in if !shown { preparedPackage = nil } }
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        .sheet(isPresented: $showSyncSettings) { SyncSettingsView() }
        .sheet(item: $documentToRename) { document in RenameDocumentSheet(document: document) }
        .sheet(item: $folderToRename) { folder in RenameFolderSheet(folder: folder) }
        .confirmationDialog("删除文章？", isPresented: Binding(
            get: { documentToDelete != nil }, set: { if !$0 { documentToDelete = nil } }
        ), titleVisibility: .visible, presenting: documentToDelete) { document in
            Button("删除文章", role: .destructive) { delete(document.id) }
            Button("取消", role: .cancel) { documentToDelete = nil }
        } message: { document in
            Text("将删除书架中的「\(document.title)」及其收藏、阅读记录。导入前的原始文件不受影响。")
        }
        .confirmationDialog("删除资料夹？", isPresented: Binding(
            get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }
        ), titleVisibility: .visible, presenting: folderToDelete) { folder in
            Button(folder.documentIDs.isEmpty ? "删除资料夹" : "删除资料夹及 \(folder.documentIDs.count) 篇文章", role: .destructive) { deleteFolder(folder) }
                .disabled(!library.canOrganize)
            Button("取消", role: .cancel) { folderToDelete = nil }
        } message: { folder in
            Text("将删除「\(folder.name)」" + (folder.documentIDs.isEmpty ? "这个空资料夹。" : "及其中全部 \(folder.documentIDs.count) 篇文章、收藏和阅读记录。")
                + "导入前的原始文件不受影响。" + (library.syncConnection == nil ? "" : "删除也会同步到其他设备。"))
        }
        .alert("操作未完成", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("知道了") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .safeAreaInset(edge: .bottom) {
            if library.isImporting || library.isDeleting || library.isExporting {
                HStack { ProgressView().controlSize(.small); Text(library.isDeleting ? "正在删除资料…" : library.isExporting ? "正在准备资料包…" : "正在导入资料…") }.font(.callout).padding(10).frame(maxWidth: .infinity).background(.bar)
            } else if let notice = library.notice {
                HStack { Text(notice); Spacer(); Button("关闭", systemImage: "xmark") { library.notice = nil }.labelStyle(.iconOnly) }
                    .font(.callout).padding(10).background(.bar)
            }
        }
        .onChange(of: filter) { _, _ in updateSelection(reset: false, cancelPending: true) }
        // Comparing the library's revision keeps the check off the article list itself, which the
        // reader would otherwise rebuild on every scroll report.
        .onChange(of: library.revision) { _, _ in
            if let filter, UUID(uuidString: filter) != nil, library.folder(matching: filter) == nil { self.filter = "all" }
            updateSelection(reset: false)
        }
        .onChange(of: searchModel.resultRevision) { _, _ in updateSelection(reset: false) }
    }

    private var sidebar: some View {
        sidebarList
        .navigationTitle("学习书架")
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        .safeAreaInset(edge: .bottom) {
            Button { showSyncSettings = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: library.syncConnection == nil ? "internaldrive" : (library.syncIssue == nil ? "icloud" : "icloud.slash"))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(library.syncConnection == nil ? "本地资料" : "同步资料库") · \(library.documents.count) 篇")
                        Text(library.syncConnection == nil ? "设置 iCloud Drive 同步" : library.syncStatus)
                            .font(.caption2)
                    }
                    Spacer(minLength: 0)
                    if library.isSyncing { ProgressView().controlSize(.mini) }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding()
                .help("打开资料库同步设置")
                .accessibilityIdentifier("library-sync-settings")
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新建资料夹", systemImage: "folder.badge.plus", action: beginNewFolder)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!library.canOrganize)
                    .help("新建资料夹（⇧⌘N）")
                #if !os(macOS)
                // macOS shares a toolbar across columns; the article list already has this menu.
                importMenu
                Button(folderEditMode.isEditing ? "完成排序" : "资料夹排序", systemImage: "arrow.up.arrow.down") {
                    withAnimation { folderEditMode = folderEditMode.isEditing ? .inactive : .active }
                }.disabled(!library.canOrganize || library.collections.count < 2)
                #endif
            }
        }
        .contextMenu { Button("新建资料夹…", action: beginNewFolder).disabled(!library.canOrganize) }
    }

    @ViewBuilder private var sidebarList: some View {
        #if os(macOS)
        MacLibraryList(rows: [
            .init(id: "all", title: "全部资料", symbol: "books.vertical"),
            .init(id: "recent", title: "最近阅读", symbol: "clock"),
            .init(id: "favorites", title: "收藏", symbol: "star"),
            .init(id: "folder-heading", title: "资料夹", isHeader: true)
        ] + library.collections.map { .init(id: $0.id.uuidString, title: $0.name, symbol: "folder", count: $0.documentIDs.count, folderID: $0.id) },
            selection: $filter, contextID: "sidebar", isSidebar: true, canDrag: library.canOrganize,
            dropMode: library.canOrganize ? .folders : .none,
            acceptsDrop: { ids, target in
                guard library.canOrganize else { return false }
                switch target {
                case .folder(let folderID):
                    guard ids.allSatisfy({ library.document(id: $0) != nil }),
                          let folder = library.folder(matching: folderID.uuidString) else { return false }
                    return ids.contains { !folder.documentIDs.contains($0) }
                case .folderInsertion(_, let visibleIDs):
                    return library.collections.map(\.id) == visibleIDs && ids.allSatisfy(visibleIDs.contains)
                case .insertion: return false
                }
            }, performDrop: { ids, target in
                switch target {
                case .folder(let folderID): return move(ids, to: folderID)
                case .folderInsertion(let index, let visibleIDs): return reorderFolders(ids, visibleIDs: visibleIDs, at: index)
                case .insertion: return false
                }
            }, menu: { rowID in
                let menu = NSMenu()
                menu.autoenablesItems = false
                if let folder = library.folder(matching: rowID) {
                    let renameItem = LibraryMenuItem("重命名…", enabled: library.canOrganize) { folderToRename = folder }
                    renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "重命名资料夹")
                    menu.addItem(renameItem)
                    menu.addItem(LibraryMenuItem("导出资料夹及附件…", enabled: library.canOrganize) { exportFolder(folder) })
                    menu.addItem(.separator())
                    menu.addItem(LibraryMenuItem("上移", enabled: library.canOrganize && library.collections.first?.id != folder.id) { shiftFolder(folder.id, down: false) })
                    menu.addItem(LibraryMenuItem("下移", enabled: library.canOrganize && library.collections.last?.id != folder.id) { shiftFolder(folder.id, down: true) })
                    menu.addItem(.separator())
                    let deleteItem = LibraryMenuItem("删除资料夹…", enabled: library.canOrganize) { folderToDelete = folder }
                    deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除资料夹")
                    menu.addItem(deleteItem)
                    menu.addItem(.separator())
                }
                menu.addItem(LibraryMenuItem("新建资料夹…", enabled: library.canOrganize, action: beginNewFolder))
                return menu
            })
        #else
        List(selection: $filter) {
            Section {
                Label("全部资料", systemImage: "books.vertical").tag("all")
                Label("最近阅读", systemImage: "clock").tag("recent")
                Label("收藏", systemImage: "star").tag("favorites")
            }
            Section("资料夹") {
                ForEach(library.collections) { folder in folderRow(folder) }
                    .onMove { indexes, destination in
                        let order = library.collections.map(\.id)
                        guard indexes.allSatisfy(order.indices.contains) else { return }
                        reorderFolders(indexes.map { order[$0] }, visibleIDs: order, at: destination)
                    }
                    .moveDisabled(!library.canOrganize)
            }
        }
        .environment(\.editMode, $folderEditMode)
        #endif
    }

    private func folderRow(_ folder: LibraryFolder) -> some View {
        HStack {
            Label(folder.name, systemImage: targetedFolderID == folder.id ? "folder.fill" : "folder")
            Spacer()
            Text("\(folder.documentIDs.count)").foregroundStyle(.secondary).font(.caption)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(targetedFolderID == folder.id ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .tag(folder.id.uuidString)
        .onDrop(of: [DocumentDrag.typeIdentifier], isTargeted: Binding(
            get: { targetedFolderID == folder.id },
            set: { value in
                if value { targetedFolderID = folder.id }
                else if targetedFolderID == folder.id { targetedFolderID = nil }
            }
        )) { providers in receiveMove(providers, to: folder.id) }
        .help("上下拖动资料夹排序；把文章拖到这里可移动到「\(folder.name)」")
        .contextMenu {
            Button("重命名…", systemImage: "pencil") { folderToRename = folder }
                .disabled(!library.canOrganize)
            Button("导出资料夹及附件…", systemImage: "square.and.arrow.up") { exportFolder(folder) }
                .disabled(!library.canOrganize)
            Divider()
            Button("上移", systemImage: "arrow.up") { shiftFolder(folder.id, down: false) }
                .disabled(!library.canOrganize || library.collections.first?.id == folder.id)
            Button("下移", systemImage: "arrow.down") { shiftFolder(folder.id, down: true) }
                .disabled(!library.canOrganize || library.collections.last?.id == folder.id)
            Divider()
            Button("删除资料夹…", systemImage: "trash", role: .destructive) { folderToDelete = folder }
                .disabled(!library.canOrganize)
        }
    }

    private var documentList: some View {
        documentRows
        .navigationTitle(title)
        .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 360)
        .searchable(text: $search, prompt: "搜索标题或正文")
        .overlay {
            if library.isLoading || searchPending {
                ProgressView(library.isLoading ? "正在打开资料库…" : "正在搜索…")
            } else if !search.isEmpty, let error = searchModel.error {
                ContentUnavailableView("搜索未完成", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
            } else if visibleDocuments.isEmpty {
                ContentUnavailableView(search.isEmpty ? "还没有资料" : "没有找到匹配内容",
                                       systemImage: search.isEmpty ? "doc.badge.plus" : "magnifyingglass",
                                       description: Text(search.isEmpty ? "导入 Markdown，或把文章拖到左侧资料夹。" : "试试正文里的关键词。"))
            }
        }
        .toolbar { ToolbarItem { importMenu } }
        .safeAreaInset(edge: .top) {
            if !search.isEmpty, !searchPending, !searchModel.issues.isEmpty {
                Button { showSearchIssues = true } label: {
                    Label("\(searchModel.issues.count) 篇正文未能搜索 · 查看", systemImage: "exclamationmark.triangle")
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).padding(12).background(.bar)
            }
        }
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Text(filter == "recent" ? "按阅读时间排列 · 拖到资料夹可移动" : "上下拖动排序 · 拖到左侧资料夹可移动")
                .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity).background(.bar)
        }
        #endif
    }

    @ViewBuilder private var documentRows: some View {
        #if os(macOS)
        MacLibraryList(rows: visibleDocuments.map {
            .init(id: $0.id.uuidString, title: $0.title, documentID: $0.id,
                  isFavorite: library.isFavorite($0.id), progress: library.position(for: $0.id)?.progress ?? 0)
                  .withSearchHit(search.isEmpty ? nil : searchModel.hits[$0.id])
        }, selection: Binding(get: { selectedID?.uuidString }, set: { selectDocument($0.flatMap(UUID.init(uuidString:)), fromSearchResult: true) }),
            contextID: filter ?? "all", canDrag: library.canOrganize && !searchPending,
            dropMode: library.canOrganize && !searchPending && filter != "recent" ? .reorder : .none,
            acceptsDrop: { ids, target in
                guard library.canOrganize, !searchPending, filter != "recent",
                      case .insertion(_, let visibleIDs) = target else { return false }
                return ids.allSatisfy(visibleIDs.contains)
            }, performDrop: { ids, target in
                guard case .insertion(let index, let visibleIDs) = target else { return false }
                do {
                    try library.reorderDocuments(ids, visibleIDs: visibleIDs, at: index, folderID: selectedFolderID)
                    return true
                } catch { library.errorMessage = error.localizedDescription; return false }
            }, menu: documentMenu, activate: { selectDocument(UUID(uuidString: $0), fromSearchResult: true) })
        #else
        List {
            ForEach(visibleDocuments) { document in
                Button {
                    selectDocument(document.id, fromSearchResult: true)
                } label: {
                    HStack {
                        DocumentRow(title: document.title,
                                    isFavorite: library.isFavorite(document.id),
                                    progress: library.position(for: document.id)?.progress ?? 0,
                                    searchHit: search.isEmpty ? nil : searchModel.hits[document.id])
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(selectedID == document.id ? Color.accentColor.opacity(0.12) : nil)
                .accessibilityHint("打开文章")
                .onDrag { DocumentDrag.provider(for: document.id, title: document.title) }
                .contextMenu { documentActions(document) }
            }
            .onInsert(of: filter == "recent" || !library.canOrganize || searchPending ? [] : [DocumentDrag.typeIdentifier]) { index, providers in
                receiveReorder(providers, at: index)
            }
        }
        #endif
    }

    private var searchIssuesView: some View {
        NavigationStack {
            List {
                Text("以下文件的正文暂时无法读取，其余文章的搜索结果仍可使用。恢复文件后可重新搜索。")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(searchModel.issues) { issue in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(issue.title).font(.headline)
                        Text(issue.path).font(.caption).foregroundStyle(.secondary)
                        Text(issue.message).font(.callout).textSelection(.enabled)
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle("无法搜索的文件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showSearchIssues = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("重新搜索") { showSearchIssues = false; searchRetry &+= 1 }
                }
            }
        }.frame(minWidth: 320, idealWidth: 480, minHeight: 300, idealHeight: 420)
    }

    #if os(macOS)
    private func documentMenu(_ rowID: String?) -> NSMenu? {
        guard let id = rowID.flatMap(UUID.init(uuidString:)), let document = library.document(id: id) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let renameItem = LibraryMenuItem("重命名…", enabled: library.canOrganize) { documentToRename = document }
        renameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "重命名")
        menu.addItem(renameItem)
        menu.addItem(LibraryMenuItem("导出文章及附件…", enabled: library.canOrganize) { exportDocuments([id], name: document.title) })
        menu.addItem(LibraryMenuItem(library.isFavorite(id) ? "取消收藏" : "收藏") { library.toggleFavorite(id) })
        let moveMenu = NSMenu()
        moveMenu.autoenablesItems = false
        for folder in library.collections {
            moveMenu.addItem(LibraryMenuItem(folder.name, enabled: library.canOrganize && !folder.documentIDs.contains(id)) { move([id], to: folder.id) })
        }
        let moveItem = NSMenuItem(title: "移到资料夹", action: nil, keyEquivalent: "")
        moveItem.submenu = moveMenu
        moveItem.isEnabled = library.canOrganize
        menu.addItem(moveItem)
        if filter != "recent" {
            menu.addItem(.separator())
            menu.addItem(LibraryMenuItem("上移", enabled: library.canOrganize && visibleDocuments.first?.id != id) { shift(id, down: false) })
            menu.addItem(LibraryMenuItem("下移", enabled: library.canOrganize && visibleDocuments.last?.id != id) { shift(id, down: true) })
        }
        menu.addItem(.separator())
        let deleteItem = LibraryMenuItem("删除文章…", enabled: library.canOrganize) { documentToDelete = document }
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "删除文章")
        menu.addItem(deleteItem)
        return menu
    }
    #endif

    @ViewBuilder private func documentActions(_ document: LibraryDocument) -> some View {
        Button("重命名…", systemImage: "pencil") { documentToRename = document }
            .disabled(!library.canOrganize)
        Button("导出文章及附件…", systemImage: "square.and.arrow.up") { exportDocuments([document.id], name: document.title) }
            .disabled(!library.canOrganize)
        Button(library.isFavorite(document.id) ? "取消收藏" : "收藏") { library.toggleFavorite(document.id) }
        Menu("移到资料夹") {
            ForEach(library.collections) { folder in
                Button(folder.name) { move([document.id], to: folder.id) }
                    .disabled(folder.documentIDs.contains(document.id))
            }
        }.disabled(!library.canOrganize)
        if filter != "recent" {
            Divider()
            Button("上移", systemImage: "arrow.up") { shift(document.id, down: false) }
                .disabled(!library.canOrganize || visibleDocuments.first?.id == document.id)
            Button("下移", systemImage: "arrow.down") { shift(document.id, down: true) }
                .disabled(!library.canOrganize || visibleDocuments.last?.id == document.id)
        }
        Divider()
        Button("删除文章", systemImage: "trash", role: .destructive) { documentToDelete = document }
            .disabled(!library.canOrganize)
    }

    private var importMenu: some View {
        Menu {
            Button("新建资料夹…", systemImage: "folder.badge.plus", action: beginNewFolder)
            Divider()
            Button(selectedFolderID == nil ? "导入 Markdown 文件" : "导入 Markdown 到当前资料夹", systemImage: "doc.badge.plus") {
                importFolder = false
                importTargetID = selectedFolderID
                showImporter = true
            }
            Button("导入资料文件夹／资料包", systemImage: "folder.badge.plus") {
                importFolder = true
                importTargetID = nil
                showImporter = true
            }
            Divider()
            Button("资料库同步…", systemImage: "icloud") { showSyncSettings = true }
        } label: { Label("添加资料", systemImage: "plus") }
        .disabled(!library.canOrganize)
        .help("新建资料夹或导入资料")
    }

    private func exportFolder(_ folder: LibraryFolder) {
        exportDocuments(folder.documentIDs, name: folder.name)
    }
    private func exportDocuments(_ ids: [UUID], name: String) {
        Task {
            do {
                preparedPackage = try await library.exportPackage(documentIDs: ids, name: name)
                showPackageExport = true
            } catch { library.errorMessage = error.localizedDescription }
        }
    }

    private var newFolderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建资料夹").font(.headline)
            TextField("资料夹名称", text: $newFolderName)
                .textFieldStyle(.roundedBorder).focused($folderNameFocused)
                .onSubmit(createFolder)
                .accessibilityIdentifier("new-folder-name")
            if let error = newFolderError { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { showNewFolder = false }.keyboardShortcut(.cancelAction)
                Button("创建", action: createFolder).keyboardShortcut(.defaultAction)
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !library.canOrganize)
            }
        }.padding(24).frame(minWidth: 280, idealWidth: 360, maxWidth: 400)
            .onAppear { folderNameFocused = true }
    }

    private func beginNewFolder() {
        newFolderName = ""
        newFolderError = nil
        showNewFolder = true
    }
    private func createFolder() {
        do {
            let id = try library.createFolder(named: newFolderName)
            search = ""
            filter = id.uuidString
            showNewFolder = false
        } catch { newFolderError = error.localizedDescription }
    }
    private func updateSelection(reset: Bool, cancelPending: Bool = false) {
        guard !searchPending else { return }
        guard reset || selectedID == nil || !visibleDocuments.contains(where: { $0.id == selectedID }) else {
            if cancelPending { selectDocument(selectedID) }
            return
        }
        #if os(macOS)
        selectDocument(visibleDocuments.first?.id)
        #else
        selectDocument(nil)
        #endif
    }
    private func selectDocument(_ id: UUID?, fromSearchResult: Bool = false) {
        let target = fromSearchResult && !search.isEmpty && !searchPending
            ? id.flatMap { searchModel.hits[$0]?.target } : nil
        let selectedSearchRequest = searchRequest
        let isCurrentArticle = id == selectedID
        navigation.select(id, opensReader: fromSearchResult, prepare: {
            await reader.prepareToLeave()
            await library.flush()
        }, activate: {
            if isCurrentArticle, id != nil { reader.resumeReading() }
            if !isCurrentArticle || fromSearchResult { reader.clearSearch() }
            if fromSearchResult, selectedSearchRequest == searchRequest, let target, let id {
                reader.revealSearch(target, in: id)
            }
        })
    }
    @discardableResult private func move(_ ids: [UUID], to folderID: UUID) -> Bool {
        do {
            try library.moveDocuments(ids, to: folderID)
            let name = library.collections.first { $0.id == folderID }?.name ?? "资料夹"
            library.notice = "已将 \(ids.count) 篇文章移到「\(name)」"
            return true
        } catch { library.errorMessage = error.localizedDescription; return false }
    }
    private func receiveMove(_ providers: [NSItemProvider], to folderID: UUID) -> Bool {
        guard library.canOrganize, providers.contains(where: { $0.hasItemConformingToTypeIdentifier(DocumentDrag.typeIdentifier) }) else { return false }
        Task { @MainActor in
            do { move(try await DocumentDrag.read(providers), to: folderID) }
            catch { library.errorMessage = error.localizedDescription }
        }
        return true
    }
    private func receiveReorder(_ providers: [NSItemProvider], at index: Int) {
        guard library.canOrganize, filter != "recent" else { return }
        let ids = visibleDocuments.map(\.id)
        let folderID = selectedFolderID
        Task { @MainActor in
            do { try library.reorderDocuments(try await DocumentDrag.read(providers), visibleIDs: ids, at: index, folderID: folderID) }
            catch { library.errorMessage = error.localizedDescription }
        }
    }
    private func shift(_ id: UUID, down: Bool) {
        let ids = visibleDocuments.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        do { try library.reorderDocuments([id], visibleIDs: ids, at: down ? index + 2 : index - 1, folderID: selectedFolderID) }
        catch { library.errorMessage = error.localizedDescription }
    }
    @discardableResult private func reorderFolders(_ ids: [UUID], visibleIDs: [UUID], at index: Int) -> Bool {
        do {
            try library.reorderFolders(ids, visibleIDs: visibleIDs, at: index)
            return true
        } catch { library.errorMessage = error.localizedDescription; return false }
    }
    private func shiftFolder(_ id: UUID, down: Bool) {
        let ids = library.collections.map(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        reorderFolders([id], visibleIDs: ids, at: down ? index + 2 : index - 1)
    }
    private func delete(_ id: UUID) {
        documentToDelete = nil
        Task { @MainActor in
            do { try await library.deleteDocument(id) }
            catch { library.errorMessage = error.localizedDescription }
        }
    }
    private func deleteFolder(_ folder: LibraryFolder) {
        folderToDelete = nil
        Task { @MainActor in
            do {
                if let selectedID, folder.documentIDs.contains(selectedID) { await reader.prepareToLeave() }
                try await library.deleteFolder(folder.id, expected: folder)
            } catch {
                reader.resumeReading()
                library.errorMessage = error.localizedDescription
            }
        }
    }
}

/// Plain values only, so an unrelated store update redraws a row just when its own text moved.
private struct DocumentRow: View {
    let title: String
    let isFavorite: Bool
    let progress: Double
    var searchHit: LibrarySearchHit? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                SearchHighlightedText(value: searchHit?.title ?? LibrarySearchText(title, query: ""))
                    .font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                if isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption)
                }
            }
            if let hit = searchHit {
                if let snippet = hit.snippet {
                    SearchHighlightedText(value: snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                } else { Text("标题匹配").font(.caption).foregroundStyle(.secondary) }
            }
            if progress > 0.02 {
                ProgressView(value: progress).tint(.secondary).frame(maxWidth: 120)
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}

private struct SearchHighlightedText: View {
    let value: LibrarySearchText
    private var attributed: AttributedString {
        var text = AttributedString(value.text)
        for range in value.highlights {
            guard let sourceRange = Range(range, in: value.text),
                  let lower = AttributedString.Index(sourceRange.lowerBound, within: text),
                  let upper = AttributedString.Index(sourceRange.upperBound, within: text) else { continue }
            text[lower..<upper].backgroundColor = .yellow.opacity(0.35)
            text[lower..<upper].foregroundColor = .primary
        }
        return text
    }
    var body: some View { Text(attributed) }
}
