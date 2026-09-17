import Foundation
import ImageIO

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


/// Pixel sizes of the imported attachments. The page reserves the right box before an image
/// decodes, so the article stops jumping while it loads and a saved position no longer has to
/// wait for it. Only each file's header is read: a 25 MB photo is never decoded to learn its shape.
actor LibraryImageSizes {
    private static let extensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    private static let scanLimit = 5_000
    private var revision = -1
    private var cache: [UUID: [String: [Int]]] = [:]

    /// Keyed by the attachment's path inside its collection, exactly as the Markdown writes it.
    /// Both sides compare precomposed text, because the file system may hand back a decomposed name.
    func sizes(collection id: UUID, root: URL, revision: Int) -> [String: [Int]] {
        if self.revision != revision {
            cache.removeAll()
            self.revision = revision
        }
        if let cached = cache[id] { return cached }
        let sizes = Self.read(root: root)
        cache[id] = sizes
        return sizes
    }

    private static func read(root: URL) -> [String: [Int]] {
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [:] }
        var sizes: [String: [Int]] = [:]
        var scanned = 0
        for case let file as URL in walker {
            guard scanned < scanLimit else { break }
            guard extensions.contains(file.pathExtension.lowercased()) else { continue }
            scanned += 1
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0 else { continue }
            let relative = String(path.dropFirst(base.count + 1)).precomposedStringWithCanonicalMapping
            sizes[relative] = [width, height]
        }
        return sizes
    }
}

protocol LibrarySearching: Sendable {
    func matches(query: String, documents: [LibraryDocument], revision: Int) async throws -> Set<UUID>
}

/// This actor scans off the main thread. Cancellation is checked between documents and no body
/// is kept by the search cache. Selecting an article uses the independent LibraryContent actor.
///
/// Typing one more character cannot be answered from the previous query's matches. A longer
/// query can match a document the shorter one missed, because `localizedStandardContains` only
/// matches whole characters: a body carrying the ligature "ﬁ" answers "confi" but not "conf".
/// Study material pasted out of LaTeX PDFs is full of those, so every query scans the library.
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
        let matches = try await Self.scan(query: query, documents: documents)
        try Task.checkCancellation()
        // Another query may have replaced the corpus while this scan was running on the cores.
        // Its answer is still correct for its own caller, but it no longer describes this revision.
        guard cachedRevision == revision else { return matches }
        if recentQueries.count >= 8 { results.removeValue(forKey: recentQueries.removeFirst()) }
        results[query] = matches
        recentQueries.append(query)
        return matches
    }

    /// Reading a thousand files one after another leaves the other cores idle for the whole query.
    /// Each worker takes every nth document, so neighbouring files of similar size spread evenly,
    /// and only one body per worker is resident at a time.
    private static func scan(query: String, documents: [LibraryDocument]) async throws -> Set<UUID> {
        let workers = min(6, max(1, ProcessInfo.processInfo.activeProcessorCount))
        guard documents.count > 1, workers > 1 else {
            return Set(try documents.filter { try Self.matches(query: query, in: $0) }.map(\.id))
        }
        return try await withThrowingTaskGroup(of: [UUID].self) { group in
            for worker in 0..<workers {
                group.addTask {
                    var found: [UUID] = []
                    var index = worker
                    while index < documents.count {
                        try Task.checkCancellation()
                        let document = documents[index]
                        if try autoreleasepool(invoking: { try Self.matches(query: query, in: document) }) {
                            found.append(document.id)
                        }
                        index += workers
                    }
                    return found
                }
            }
            var all = Set<UUID>()
            for try await part in group { all.formUnion(part) }
            return all
        }
    }

    private static func matches(query: String, in document: LibraryDocument) throws -> Bool {
        if query.isEmpty || document.title.localizedStandardContains(query) { return true }
        return try LibraryDisk.readMarkdown(for: document).localizedStandardContains(query)
    }
}
