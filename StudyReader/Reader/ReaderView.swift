import SwiftUI
import UniformTypeIdentifiers

struct ReaderView: View {
    let document: LibraryDocument
    /// Owned by the shelf so switching articles reuses the already-loaded typesetting page.
    @ObservedObject var controller: ReaderController
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("reader.fontSize") private var fontSize = 18.0
    @AppStorage("reader.theme") private var theme = "system"
    @AppStorage("reader.foldAnswers") private var foldAnswers = false
    @State private var showOutline = false
    @State private var showPreferences = false
    @State private var showFind = false
    @State private var findText = ""
    @State private var showExport = false
    @State private var exportPackage: PreparedLibraryPackage?
    @State private var editDraft: EditDraft?
    @State private var markdown: String?
    @State private var imageSizes: [String: [Int]] = [:]
    @State private var loadedRecord: DocumentRecord?
    @State private var loadedSession: String?
    @State private var displayedProgressID: UUID?
    @State private var loadingError: String?
    private struct EditDraft: Identifiable {
        let id = UUID()
        let document: LibraryDocument
        let markdown: String
    }
    private struct LoadKey: Equatable { var record: DocumentRecord; var root: URL }
    private var hasLoadedDocument: Bool { loadedRecord == document.record }
    /// The shelf pins its import and notice bar to the bottom safe area. Reading past that inset
    /// would slide the article under the bar, so the page only fills the home-indicator strip
    /// while no bar is there.
    private var shelfBannerShown: Bool { library.isImporting || library.isExporting || library.isDeleting || library.notice != nil }

    private var preferences: ReaderPreferences { ReaderPreferences(fontSize: fontSize, theme: theme, foldAnswers: foldAnswers) }
    var body: some View {
        VStack(spacing: 0) {
            if hasLoadedDocument, library.isRemoteProgress(for: document.id),
               let update = library.progressUpdate(for: document.id), update.id != displayedProgressID {
                HStack {
                    Label("另一台设备更新了阅读位置", systemImage: "icloud")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("接着读") { if let markdown { display(markdown, preferSavedPosition: true) } }
                        .disabled(controller.isLoading)
                    Button("忽略", systemImage: "xmark") { displayedProgressID = update.id }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }.padding(12).background(.bar)
            }
            if showFind {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("在文章中查找", text: $findText).textFieldStyle(.plain).onSubmit { controller.find(findText) }
                    if controller.findFailed { Text("未找到").font(.caption).foregroundStyle(.secondary) }
                    Button("下一个") { controller.find(findText) }
                    Button("关闭", systemImage: "xmark") { showFind = false; findText = ""; controller.find("") }.labelStyle(.iconOnly)
                }.padding(12).background(.bar)
            }
            ReaderWebView(controller: controller)
                .ignoresSafeArea(.container, edges: shelfBannerShown ? [] : .bottom)
                .opacity(hasLoadedDocument ? 1 : 0)
                .overlay {
                    if let error = loadingError {
                        ContentUnavailableView("文章暂时无法读取", systemImage: "doc.badge.ellipsis", description: Text(error))
                    } else if !hasLoadedDocument || controller.isLoading {
                        ProgressView(hasLoadedDocument ? "正在排版…" : "正在打开文章…")
                            .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        }
        .navigationTitle(document.title)
        .toolbar {
            ToolbarItemGroup {
                Button("文章目录", systemImage: "list.bullet.indent") { showOutline = true }
                    .popover(isPresented: $showOutline) { outlineView }
                Button(library.isFavorite(document.id) ? "取消收藏" : "收藏",
                       systemImage: library.isFavorite(document.id) ? "star.fill" : "star") { library.toggleFavorite(document.id) }
                Button("阅读设置", systemImage: "textformat.size") { showPreferences = true }
                    .popover(isPresented: $showPreferences) { preferencesView }
                Menu {
                    Button("编辑当前文章", systemImage: "square.and.pencil") {
                        if let markdown { editDraft = EditDraft(document: document, markdown: markdown) }
                    }
                    .disabled(!hasLoadedDocument || markdown == nil || !library.canOrganize)
                    Divider()
                    Button("在文章中查找", systemImage: "magnifyingglass") { showFind.toggle() }
                    Button("导出本文 Markdown", systemImage: "square.and.arrow.up") { exportPackage = nil; showExport = true }
                        .disabled(!hasLoadedDocument || markdown == nil)
                    Button("导出本文及附件…", systemImage: "folder.badge.arrow.up") {
                        Task {
                            do {
                                exportPackage = try await library.exportPackage(documentIDs: [document.id], name: document.title)
                                showExport = true
                            } catch { library.errorMessage = error.localizedDescription }
                        }
                    }.disabled(!hasLoadedDocument || !library.canOrganize)
                } label: { Label("更多", systemImage: "ellipsis.circle") }
            }
        }
        .task(id: LoadKey(record: document.record, root: document.rootURL)) {
            controller.onPosition = { id, position, readAt in library.updatePosition(position, id: id, readAt: readAt) }
            markdown = nil
            loadedRecord = nil
            loadingError = nil
            do {
                // The attachment sizes are read from the file headers while the body loads, so the
                // first layout already reserves each image's box.
                async let sizes = library.imageSizes(for: document)
                let content = try await library.content.markdown(for: document)
                try Task.checkCancellation()
                let measuredSizes = await sizes
                try Task.checkCancellation()
                imageSizes = measuredSizes
                markdown = content
                loadedRecord = document.record
                display(content, preferSavedPosition: library.isRemoteProgress(for: document.id))
                library.opened(document.id)
            } catch is CancellationError {
                // Another article now owns the shared reader.
            } catch { if !Task.isCancelled { loadingError = error.localizedDescription } }
        }
        .onChange(of: document.id) { _, _ in
            showOutline = false
            showFind = false
            findText = ""
            controller.find("")
        }
        .onChange(of: controller.currentSession) { _, session in
            if hasLoadedDocument, controller.currentDocumentID == document.id.uuidString { loadedSession = session }
        }
        .onDisappear {
            controller.savePosition(for: document.id, session: loadedSession, suspend: true, cachedOnly: true) { library.saveForLifecycle() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { controller.resumeReading() }
            else {
                controller.savePosition(for: document.id, session: loadedSession, suspend: phase == .background,
                    cachedOnly: phase == .background) { library.saveForLifecycle() }
            }
        }
        .onChange(of: fontSize) { _, _ in controller.preferences(preferences) }
        .onChange(of: theme) { _, _ in controller.preferences(preferences) }
        .onChange(of: foldAnswers) { _, _ in controller.preferences(preferences) }
        .onChange(of: findText) { _, value in controller.find(value) }
        .fileExporter(isPresented: $showExport, document: exportPackage.map { LibraryExportDocument(package: $0) } ?? LibraryExportDocument(markdown: markdown ?? ""),
                      contentType: exportPackage == nil ? .plainText : .folder,
                      defaultFilename: exportPackage?.name ?? document.fileURL.lastPathComponent) { result in
            if case .failure(let error) = result { library.errorMessage = error.localizedDescription }
            exportPackage = nil
        }
        .onChange(of: showExport) { _, shown in if !shown { exportPackage = nil } }
        .sheet(item: $editDraft) { draft in
            ArticleEditor(document: draft.document, markdown: draft.markdown)
        }
        .alert("阅读组件提示", isPresented: Binding(get: { controller.error != nil }, set: { if !$0 { controller.error = nil } })) {
            if controller.canRetry { Button("重新加载") { controller.retryLoading() } }
            Button("知道了") { controller.error = nil }
        } message: { Text(controller.error ?? "") }
        .sheet(isPresented: Binding(get: { controller.formula != nil }, set: { if !$0 { controller.formula = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("公式原文").font(.headline); Spacer(); Button("完成") { controller.formula = nil } }
                ScrollView { Text(controller.formula ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button("复制 LaTeX", systemImage: "doc.on.doc") {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.formula ?? "", forType: .string)
                    #else
                    UIPasteboard.general.string = controller.formula
                    #endif
                }
            }.padding(24).frame(minWidth: 280, idealWidth: 500, minHeight: 200, idealHeight: 280)
                .presentationDetents([.medium])
        }
    }

    private func display(_ content: String, preferSavedPosition: Bool) {
        displayedProgressID = library.progressUpdate(for: document.id)?.id
        loadedSession = controller.display(document, markdown: content, position: library.position(for: document.id),
            preferences: preferences, roots: library.roots, imageSizes: imageSizes, preferSavedPosition: preferSavedPosition)
    }
    private var outlineView: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("文章目录").font(.headline).padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(controller.outline) { heading in
                        Button { controller.scroll(to: heading); showOutline = false } label: {
                            Text(heading.title).font(heading.level <= 2 ? .body.weight(.medium) : .callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, CGFloat(max(0, heading.level - 1)) * 10).padding(.vertical, 9)
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal)
            }
        }.frame(width: 290, height: 420).presentationCompactAdaptation(.popover)
    }
    private var preferencesView: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("阅读设置").font(.headline)
            Stepper(value: $fontSize, in: 14...28, step: 1) { Text("字号 \(Int(fontSize))") }
            Picker("外观", selection: $theme) {
                Text("自动").tag("system")
                Text("浅色").tag("light")
                Text("深色").tag("dark")
            }.pickerStyle(.segmented)
            Toggle("折叠解答", isOn: $foldAnswers)
            Text("点击公式可以查看并复制 LaTeX 原文。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 290).presentationCompactAdaptation(.popover)
    }
}
