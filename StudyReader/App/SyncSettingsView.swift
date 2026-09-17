import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var createLibrary = false
    @State private var pickerError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("在电脑整理，在手机接着看", systemImage: "icloud")
                        .font(.headline)
                    Text("两台设备登录同一个 Apple 账号并开启 iCloud Drive，然后各选择一次同一个资料库文件夹。")
                        .foregroundStyle(.secondary)
                }
                if let connection = library.syncConnection {
                    Section("当前资料库") {
                        LabeledContent("文件夹", value: connection.folderName)
                        HStack {
                            if library.isSyncing { ProgressView().controlSize(.small) }
                            Text(library.syncStatus)
                        }
                        if let checked = library.lastSyncCheck {
                            LabeledContent("最近检查") { Text(checked, style: .time) }
                        }
                        Button("立即同步", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await library.synchronize() }
                        }.disabled(library.isSyncing || !library.canOrganize)
                        Button("重新选择原资料库…", systemImage: "folder") { select(create: false) }
                            .disabled(library.isSyncing || library.isConnecting)
                        Button("断开连接", role: .destructive) { library.disconnectSyncFolder() }
                            .disabled(library.isSyncing || library.isConnecting)
                        Text("断开后，已下载的资料和本机修改会继续保留。iCloud 中的资料不会被删除。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section("首次设置") {
                        Button("新建同步资料库…", systemImage: "folder.badge.plus") { select(create: true) }
                        Button("连接已有资料库…", systemImage: "folder") { select(create: false) }
                        Text("先在 iCloud Drive 中创建一个空文件夹，再选择「新建同步资料库」。另一台设备使用「连接已有资料库」，选择相同文件夹。")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("连接前会自动备份本机资料。两端已有资料会合并，相同的导入内容会去重。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.disabled(!library.canOrganize || library.isSyncing)
                }
                if library.isConnecting {
                    HStack { ProgressView().controlSize(.small); Text("正在连接并备份本机资料…") }
                }
                if let error = pickerError ?? library.syncIssue {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("同步内容") {
                    Label("文章、图片、资料夹和排序", systemImage: "checkmark.circle")
                    Text("收藏和阅读进度暂时保存在当前设备。")
                        .foregroundStyle(.secondary)
                    Text("打开 App 后自动检查更新。已下载的文章可以离线阅读，离线修改会在恢复连接后继续同步；同时修改同一篇文章时，会保留冲突副本。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("资料库同步")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
        #if os(macOS)
        .frame(width: 500, height: 640)
        #endif
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let create = createLibrary
                Task { await library.connectSyncFolder(url, create: create) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { pickerError = error.localizedDescription }
            }
        }
    }

    private func select(create: Bool) {
        pickerError = nil
        createLibrary = create
        showPicker = true
    }
}
