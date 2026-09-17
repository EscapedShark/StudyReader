import SwiftUI

struct RenameFolderSheet: View {
    let folder: LibraryFolder
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(folder: LibraryFolder) {
        self.folder = folder
        _name = State(initialValue: folder.name)
    }
    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.canOrganize && !trimmed.isEmpty && trimmed != folder.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名资料夹").font(.headline)
            TextField("资料夹名称", text: $name)
                .textFieldStyle(.roundedBorder).focused($nameFocused)
                .autocorrectionDisabled().onSubmit(save)
                .accessibilityIdentifier("rename-folder-name")
            if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }.padding(24).frame(minWidth: 280, idealWidth: 380, maxWidth: 420)
            .onAppear { nameFocused = true }
    }

    private func save() {
        guard canSave else { return }
        do {
            try library.renameFolder(folder.id, to: name, expectedName: folder.name)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
