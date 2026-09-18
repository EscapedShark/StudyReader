import Foundation
import Combine

/// Each window owns its request lifetime. Finishing an obsolete or cancelled request cannot
/// replace newer results, even if a search provider ignores cancellation.
@MainActor final class LibrarySearchModel: ObservableObject {
    @Published private(set) var matchedIDs: Set<UUID> = []
    @Published private(set) var hits: [UUID: LibrarySearchHit] = [:]
    @Published private(set) var issues: [LibrarySearchIssue] = []
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var resultRevision = 0
    private(set) var resultToken = UUID()
    private var completedQuery = ""
    private var completedCorpusRevision = -1
    private var request: UUID?

    func isCurrent(query: String, revision: Int) -> Bool {
        query == completedQuery && revision == completedCorpusRevision
    }

    func search(query: String, documents: [LibraryDocument], revision: Int,
                using engine: any LibrarySearching, debounceNanoseconds: UInt64 = 200_000_000) async {
        let token = UUID()
        request = token
        error = nil
        issues = []
        if query.isEmpty {
            matchedIDs = []
            hits = [:]
            completedQuery = query
            completedCorpusRevision = revision
            isSearching = false
            resultToken = UUID()
            resultRevision &+= 1
            return
        }
        isSearching = true
        defer { if request == token { isSearching = false } }
        do {
            try await Task.sleep(nanoseconds: debounceNanoseconds)
            let matches = try await engine.search(query: query, documents: documents, revision: revision)
            try Task.checkCancellation()
            guard request == token else { return }
            hits = matches.hits
            issues = matches.issues
            matchedIDs = Set(matches.hits.keys)
            completedQuery = query
            completedCorpusRevision = revision
            resultToken = UUID()
            resultRevision &+= 1
        } catch is CancellationError {
            // The next query (or closing the view) owns the UI now.
        } catch {
            guard request == token, !Task.isCancelled else { return }
            matchedIDs = []
            hits = [:]
            issues = []
            completedQuery = query
            completedCorpusRevision = revision
            self.error = "搜索未完成：\(error.localizedDescription)"
            resultToken = UUID()
            resultRevision &+= 1
        }
    }
}
