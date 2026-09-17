import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    /// One reader is kept for the whole session. Rebuilding it per article would reload the
    /// offline typesetting bundle and fonts every time the selection changes.
    @StateObject private var reader = ReaderController()
    @State private var filter: String? = "all"
    @State private var selectedID: UUID?
    @State private var search = ""
    @State private var showImporter = false
    @State private var importFolder = false
    @State private var importTargetID: UUID?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?
    @State private var targetedFolderID: UUID?
    @FocusState private var folderNameFocused: Bool

    private var selectedFolderID: UUID? { library.folder(matching: filter)?.id }
    private var title: String {
        switch filter {
        case "favorites": return "收藏"
        case "recent": return "最近阅读"
        case "all", nil: return "全部资料"
        default: return library.folder(matching: filter)?.name ?? "资料"
        }
    }
    private var visibleDocuments: [LibraryDocument] { library.visibleDocuments(filter: filter, search: search) }

    var body: some View {
        NavigationSplitView {
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
        .sheet(isPresented: $showNewFolder) { newFolderSheet }
        .alert("操作未完成", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("知道了") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .safeAreaInset(edge: .bottom) {
            if library.isImporting {
                HStack { ProgressView().controlSize(.small); Text("正在导入资料…") }.font(.callout).padding(10).frame(maxWidth: .infinity).background(.bar)
            } else if let notice = library.notice {
                HStack { Text(notice); Spacer(); Button("关闭", systemImage: "xmark") { library.notice = nil }.labelStyle(.iconOnly) }
                    .font(.callout).padding(10).background(.bar)
            }
        }
        #if os(macOS)
        .onAppear { if selectedID == nil { selectedID = visibleDocuments.first?.id } }
        #endif
        .onChange(of: filter) { _, _ in updateSelection(reset: true) }
        // Comparing the library's revision keeps the check off the article list itself, which the
        // reader would otherwise rebuild on every scroll report.
        .onChange(of: library.revision) { _, _ in updateSelection(reset: false) }
        .onChange(of: search) { _, _ in updateSelection(reset: false) }
    }

    private var sidebar: some View {
        List(selection: $filter) {
            Section {
                Label("全部资料", systemImage: "books.vertical").tag("all")
                Label("最近阅读", systemImage: "clock").tag("recent")
                Label("收藏", systemImage: "star").tag("favorites")
            }
            Section("资料夹") {
                ForEach(library.collections) { folder in folderRow(folder) }
            }
        }
        .navigationTitle("学习书架")
        .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive")
                Text("本地资料 · \(library.documents.count) 篇")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding()
        }
        .toolbar {
            ToolbarItemGroup {
                Button("新建资料夹", systemImage: "folder.badge.plus", action: beginNewFolder)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!library.canOrganize)
                    .help("新建资料夹（⇧⌘N）")
                importMenu
            }
        }
        .contextMenu { Button("新建资料夹…", action: beginNewFolder).disabled(!library.canOrganize) }
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
        .help("把文章拖到这里，移动到「\(folder.name)」")
    }

    private var documentList: some View {
        List(selection: $selectedID) {
            ForEach(visibleDocuments) { document in
                NavigationLink(value: document.id) {
                    DocumentRow(title: document.title,
                                folderName: library.folderName(for: document.id),
                                isFavorite: library.isFavorite(document.id),
                                progress: library.position(for: document.id)?.progress ?? 0)
                }
                .onDrag { DocumentDrag.provider(for: document.id, title: document.title) }
                .contextMenu { documentActions(document) }
            }
            .onInsert(of: filter == "recent" || !library.canOrganize ? [] : [DocumentDrag.typeIdentifier]) { index, providers in
                receiveReorder(providers, at: index)
            }
        }
        .navigationTitle(title)
        .navigationSplitViewColumnWidth(min: 230, ideal: 290, max: 360)
        .searchable(text: $search, prompt: "搜索标题或正文")
        .overlay {
            if visibleDocuments.isEmpty {
                ContentUnavailableView(search.isEmpty ? "还没有资料" : "没有找到匹配内容",
                                       systemImage: search.isEmpty ? "doc.badge.plus" : "magnifyingglass",
                                       description: Text(search.isEmpty ? "导入 Markdown，或把文章拖到左侧资料夹。" : "试试正文里的关键词。"))
            }
        }
        .toolbar { ToolbarItem { importMenu } }
        #if os(macOS)
        .safeAreaInset(edge: .bottom) {
            Text(filter == "recent" ? "按阅读时间排列 · 拖到资料夹可移动" : "上下拖动排序 · 拖到左侧资料夹可移动")
                .font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity).background(.bar)
        }
        #endif
    }

    @ViewBuilder private func documentActions(_ document: LibraryDocument) -> some View {
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
            Button("导入资料文件夹", systemImage: "folder.badge.plus") {
                importFolder = true
                importTargetID = nil
                showImporter = true
            }
        } label: { Label("添加资料", systemImage: "plus") }
        .disabled(!library.canOrganize)
        .help("新建资料夹或导入资料")
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
    private func updateSelection(reset: Bool) {
        guard reset || (selectedID != nil && !visibleDocuments.contains { $0.id == selectedID }) else { return }
        #if os(macOS)
        selectedID = visibleDocuments.first?.id
        #else
        selectedID = nil
        #endif
    }
    private func move(_ ids: [UUID], to folderID: UUID) {
        do {
            try library.moveDocuments(ids, to: folderID)
            let name = library.collections.first { $0.id == folderID }?.name ?? "资料夹"
            library.notice = "已将 \(ids.count) 篇文章移到「\(name)」"
        } catch { library.errorMessage = error.localizedDescription }
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
}

/// Plain values only, so an unrelated store update redraws a row just when its own text moved.
private struct DocumentRow: View {
    let title: String
    let folderName: String
    let isFavorite: Bool
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(title).font(.headline).lineLimit(2)
                Spacer(minLength: 4)
                if isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption)
                }
            }
            Text(folderName).font(.caption).foregroundStyle(.secondary)
            if progress > 0.02 {
                ProgressView(value: progress).tint(.secondary).frame(maxWidth: 120)
            }
        }.padding(.vertical, 7).contentShape(Rectangle())
    }
}
