import Foundation

enum DocumentFileName {
    static func title(for relativePath: String) -> String {
        ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The rename field edits the basename; keep the existing Markdown extension.
    static func renamedFileName(_ rawName: String, originalExtension: String) throws -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if LibraryDisk.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !name.isEmpty else { throw ReaderFailure(message: "请输入文件名。") }
        guard !name.hasPrefix("."), name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains("\\"), !name.contains(":") else {
            throw ReaderFailure(message: "文件名不能以点开头，也不能包含 /、\\、冒号、换行或控制字符。")
        }
        let filename = name + "." + originalExtension
        guard filename.utf8.count <= 255 else { throw ReaderFailure(message: "文件名过长，请缩短后再试。") }
        return filename
    }
}
