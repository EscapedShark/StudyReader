import Foundation

/// A private pasteboard format prevents file URLs or arbitrary text from being treated as library moves.
enum DocumentDrag {
    static let typeIdentifier = "com.personal.studyreader.document-id"

    static func provider(for id: UUID, title: String) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = title
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    @MainActor static func read(_ providers: [NSItemProvider]) async throws -> [UUID] {
        var result: [UUID] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: ReaderFailure(message: "未能读取拖动的文章，请重试。")) }
                }
            }
            guard data.count <= 128, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw ReaderFailure(message: "请拖动书架内的文章。")
            }
            if !result.contains(id) { result.append(id) }
        }
        guard !result.isEmpty else { throw ReaderFailure(message: "请拖动书架内的文章。") }
        return result
    }
}
