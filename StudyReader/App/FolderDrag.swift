#if os(macOS)
import AppKit

/// Folder IDs use a distinct payload so a folder reorder cannot be read as an article move.
enum FolderDrag {
    static let typeIdentifier = "com.personal.studyreader.folder-id"
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    @MainActor static func pasteboardItem(for id: UUID) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(Data(id.uuidString.utf8), forType: pasteboardType)
        return item
    }

    @MainActor static func read(_ pasteboard: NSPasteboard) throws -> [UUID] {
        var result: [UUID] = []
        for item in pasteboard.pasteboardItems ?? [] {
            guard let data = item.data(forType: pasteboardType) else { continue }
            guard data.count <= 128, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw ReaderFailure(message: "请拖动书架内的资料夹。")
            }
            if !result.contains(id) { result.append(id) }
        }
        guard !result.isEmpty else { throw ReaderFailure(message: "请拖动书架内的资料夹。") }
        return result
    }
}
#endif
