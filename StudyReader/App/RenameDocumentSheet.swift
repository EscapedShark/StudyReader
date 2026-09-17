import SwiftUI

struct RenameDocumentSheet: View {
    let document: LibraryDocument
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?
    @State private var isSaving = false
    @FocusState private var nameFocused: Bool

    init(document: LibraryDocument) {
        self.document = document
        _name = State(initialValue: document.title)
    }
    private var canSave: Bool {
        !isSaving && library.canOrganize && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.trimmingCharacters(in: .whitespacesAndNewlines) != document.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名文章文件").font(.headline)
                TextField("文件名", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .autocorrectionDisabled()
                    .onSubmit(save).disabled(isSaving)
                    .accessibilityIdentifier("rename-document-name")
            Text("保留 .\(document.fileURL.pathExtension) 扩展名，正文内容保持原样。").font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.padding(24).frame(minWidth: 280, idealWidth: 400, maxWidth: 440)
            .onAppear { nameFocused = true }
            .interactiveDismissDisabled(isSaving)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                try await library.renameDocument(document, to: name)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
