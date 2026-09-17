import Foundation

/// Only recently opened bodies are retained; the shelf and search results contain metadata only.
actor LibraryContent {
    private struct Entry {
        let url: URL
        let revision: UUID?
        let text: String
        let cost: Int
    }
    private let maxBytes: Int
    private let maxEntries: Int
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private(set) var retainedBytes = 0

    init(maxBytes: Int = 8 * 1024 * 1024, maxEntries: Int = 8) {
        self.maxBytes = max(0, maxBytes)
        self.maxEntries = max(0, maxEntries)
    }

    func remove(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) { retainedBytes -= entry.cost }
        order.removeAll { $0 == id }
    }

    func markdown(for document: LibraryDocument) throws -> String {
        try Task.checkCancellation()
        if let entry = entries[document.id], entry.url == document.fileURL, entry.revision == document.record.revision {
            order.removeAll { $0 == document.id }
            order.append(document.id)
            return entry.text
        }
        let text = try LibraryDisk.readMarkdown(for: document)
        try Task.checkCancellation()
        let cost = text.utf16.count * 2
        if let previous = entries.removeValue(forKey: document.id) {
            retainedBytes -= previous.cost
            order.removeAll { $0 == document.id }
        }
        guard cost <= maxBytes, maxEntries > 0 else { return text }
        while !order.isEmpty && (retainedBytes + cost > maxBytes || order.count >= maxEntries) {
            let oldest = order.removeFirst()
            if let removed = entries.removeValue(forKey: oldest) { retainedBytes -= removed.cost }
        }
        entries[document.id] = Entry(url: document.fileURL, revision: document.record.revision, text: text, cost: cost)
        order.append(document.id)
        retainedBytes += cost
        return text
    }
}

protocol LibrarySearching: Sendable {
    func matches(query: String, documents: [LibraryDocument], revision: Int) async throws -> Set<UUID>
}

/// This actor scans on its own executor. Cancellation is checked between documents and no body
/// is kept by the search cache. Selecting an article uses the independent LibraryContent actor.
actor LibrarySearchEngine: LibrarySearching {
    private var cachedRevision: Int?
    private var results: [String: Set<UUID>] = [:]
    private var recentQueries: [String] = []

    func matches(query: String, documents: [LibraryDocument], revision: Int) async throws -> Set<UUID> {
        try Task.checkCancellation()
        if cachedRevision != revision {
            results.removeAll()
            recentQueries.removeAll()
            cachedRevision = revision
        }
        if let cached = results[query] {
            recentQueries.removeAll { $0 == query }
            recentQueries.append(query)
            return cached
        }
        var matches = Set<UUID>()
        for document in documents {
            try Task.checkCancellation()
            let matchesDocument = try autoreleasepool {
                if query.isEmpty || document.title.localizedStandardContains(query) { return true }
                return try LibraryDisk.readMarkdown(for: document).localizedStandardContains(query)
            }
            if matchesDocument { matches.insert(document.id) }
        }
        try Task.checkCancellation()
        if recentQueries.count >= 8 { results.removeValue(forKey: recentQueries.removeFirst()) }
        results[query] = matches
        recentQueries.append(query)
        return matches
    }
}
