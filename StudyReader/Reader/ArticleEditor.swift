import SwiftUI

struct ArticleEditor: View {
    let document: LibraryDocument
    let originalMarkdown: String
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmDiscard = false

    init(document: LibraryDocument, markdown: String) {
        self.document = document
        originalMarkdown = markdown
        _draft = State(initialValue: markdown)
    }
    private var hasChanges: Bool { draft != originalMarkdown }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("编辑当前文章").font(.headline)
                Text(document.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            Divider()
            MarkdownSourceEditor(text: $draft, isEditable: !isSaving)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                HStack {
                    if isSaving { ProgressView().controlSize(.small); Text("正在保存…").font(.callout) }
                    Spacer()
                    Button("取消", action: cancel).keyboardShortcut(.cancelAction).disabled(isSaving)
                    Button("保存", action: save).keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || isSaving || !library.canOrganize)
                }
            }.padding(16)
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 800, minHeight: 420, idealHeight: 620)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .interactiveDismissDisabled(hasChanges || isSaving)
        .confirmationDialog("放弃未保存的修改？", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) { }
        }
    }

    private func cancel() {
        guard !isSaving else { return }
        if hasChanges { confirmDiscard = true } else { dismiss() }
    }
    private func save() {
        guard hasChanges, !isSaving, library.canOrganize else { return }
        isSaving = true
        errorMessage = nil
        let markdown = draft
        Task {
            defer { isSaving = false }
            do {
                try await library.saveMarkdown(markdown, for: document, originalMarkdown: originalMarkdown)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
