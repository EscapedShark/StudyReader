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

/// UTF-16 ranges bridge directly to AppKit and are converted to String indices by SwiftUI.
struct LibrarySearchText: Equatable, Sendable {
    var text: String
    var highlights: [NSRange] = []

    init(_ text: String, query: String) {
        self.text = text
        guard !query.isEmpty else { return }
        var start = text.startIndex
        while start < text.endIndex, let range = text[start...].localizedStandardRange(of: query), !range.isEmpty {
            highlights.append(NSRange(range, in: text))
            start = range.upperBound
        }
    }
}

struct ReaderSearchTarget: Equatable, Sendable {
    let query: String
    /// The actual source spelling preserves accents and PDF ligatures during highlighting.
    let matchedText: String
    let sourceLine: Int
    var dictionary: [String: Any] { ["query": query, "matchedText": matchedText, "sourceLine": sourceLine] }
}

struct LibrarySearchHit: Equatable, Sendable {
    let documentID: UUID
    let title: LibrarySearchText
    let snippet: LibrarySearchText?
    let target: ReaderSearchTarget?
}

struct LibrarySearchIssue: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let path: String
    let message: String
}

struct LibrarySearchResults: Sendable {
    var hits: [UUID: LibrarySearchHit] = [:]
    var issues: [LibrarySearchIssue] = []
}

protocol LibrarySearching: Sendable {
    func search(query: String, documents: [LibraryDocument], revision: Int) async throws -> LibrarySearchResults
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
    private var results: [String: LibrarySearchResults] = [:]
    private var recentQueries: [String] = []

    func matches(query: String, documents: [LibraryDocument], revision: Int) async throws -> Set<UUID> {
        Set(try await search(query: query, documents: documents, revision: revision).hits.keys)
    }

    func search(query: String, documents: [LibraryDocument], revision: Int) async throws -> LibrarySearchResults {
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
        // A missing or temporarily unavailable file can recover without a corpus revision.
        // Retrying the same query must read it again rather than cache an incomplete answer.
        guard cachedRevision == revision, matches.issues.isEmpty else { return matches }
        recentQueries.removeAll { $0 == query }
        if recentQueries.count >= 8 { results.removeValue(forKey: recentQueries.removeFirst()) }
        results[query] = matches
        recentQueries.append(query)
        return matches
    }

    /// Reading a thousand files one after another leaves the other cores idle for the whole query.
    /// Each worker takes every nth document, so neighbouring files of similar size spread evenly,
    /// and only one body per worker is resident at a time.
    private static func scan(query: String, documents: [LibraryDocument]) async throws -> LibrarySearchResults {
        let workers = min(documents.count, 6, max(1, ProcessInfo.processInfo.activeProcessorCount))
        return try await withThrowingTaskGroup(of: LibrarySearchResults.self) { group in
            for worker in 0..<workers {
                group.addTask {
                    var found = LibrarySearchResults()
                    var index = worker
                    while index < documents.count {
                        try Task.checkCancellation()
                        let document = documents[index]
                        try autoreleasepool { try Self.search(query: query, in: document, into: &found) }
                        index += workers
                    }
                    return found
                }
            }
            var all = LibrarySearchResults()
            for try await part in group {
                all.hits.merge(part.hits) { first, _ in first }
                all.issues.append(contentsOf: part.issues)
            }
            let order = Dictionary(uniqueKeysWithValues: documents.enumerated().map { ($0.element.id, $0.offset) })
            all.issues.sort { order[$0.id, default: 0] < order[$1.id, default: 0] }
            return all
        }
    }

    private static func search(query: String, in document: LibraryDocument, into result: inout LibrarySearchResults) throws {
        let title = LibrarySearchText(document.title, query: query)
        if query.isEmpty || !title.highlights.isEmpty {
            result.hits[document.id] = LibrarySearchHit(documentID: document.id, title: title, snippet: nil, target: nil)
        }
        guard !query.isEmpty else { return }
        do {
            // Use the same front-matter removal and newline normalization as markdown-it.
            var body = try LibraryDisk.readMarkdown(for: document)
            if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
            if body.hasPrefix("---") {
                body = body.replacingOccurrences(of: "^---\\r?\\n[\\s\\S]*?\\r?\\n(?:---|\\.\\.\\.)\\s*(?:\\r?\\n|$)", with: "", options: .regularExpression)
            }
            if body.utf8.contains(13) {
                body = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            }
            try Task.checkCancellation()
            guard let match = body.localizedStandardRange(of: query), !match.isEmpty else { return }
            let matchedText = String(body[match])
            let line = body[..<match.lowerBound].utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
            var start = body.index(match.lowerBound, offsetBy: -20, limitedBy: body.startIndex) ?? body.startIndex
            var end = body.index(match.upperBound, offsetBy: 95, limitedBy: body.endIndex) ?? body.endIndex
            // Do not fill a short hit's preview with the previous/next paragraph's equations.
            if let boundary = body[start..<match.lowerBound].range(of: "\n\n", options: .backwards) { start = boundary.upperBound }
            if let boundary = body[match.upperBound..<end].range(of: "\n\n") { end = boundary.lowerBound }
            let context = String(body[start..<end].prefix(240)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            let truncatedStart = start > body.startIndex && body[body.index(before: start)] != "\n"
            let truncatedEnd = end < body.endIndex && body[end] != "\n"
            let excerpt = (truncatedStart ? "…" : "") + context + (truncatedEnd || body.distance(from: start, to: end) > 240 ? "…" : "")
            let snippetQuery = matchedText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            result.hits[document.id] = LibrarySearchHit(documentID: document.id, title: title,
                snippet: LibrarySearchText(excerpt, query: snippetQuery),
                target: ReaderSearchTarget(query: query, matchedText: matchedText, sourceLine: line))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            result.issues.append(LibrarySearchIssue(id: document.id, title: document.title,
                path: document.record.relativePath, message: error.localizedDescription))
        }
    }
}
