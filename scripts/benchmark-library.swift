// Compile with the Library Swift sources; see PERFORMANCE.md. Fixtures are temporary and never
// touch the app's real library. BASELINE builds against the pre-optimization source snapshot.
import Foundation

@MainActor private final class MainActorPulse {
    private var last = DispatchTime.now().uptimeNanoseconds
    private(set) var maximumGapMS = 0.0
    private(set) var ticks = 0
    func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        maximumGapMS = max(maximumGapMS, Double(now - last) / 1_000_000)
        last = now
        ticks += 1
    }
}

@main struct LibraryBenchmark {
    @MainActor static func measure<T>(_ work: @MainActor () async throws -> T) async rethrows -> (T, Double, Double, Int) {
        let pulse = MainActorPulse()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
                pulse.tick()
            }
        }
        // Let the timer begin before measuring even a synchronous baseline operation.
        await Task.yield()
        let start = DispatchTime.now().uptimeNanoseconds
        defer { ticker.cancel() }
        let result = try await work()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        let ticksDuringWork = pulse.ticks
        pulse.tick()
        return (result, elapsed, pulse.maximumGapMS, ticksDuringWork)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyReader-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paragraph = "条件概率与贝叶斯公式 Probability and conditional distributions. $P(A|B)=P(A\\cap B)/P(B)$。学习时先理解样本空间，再看推导步骤。\n\n"
        let body = String(repeating: paragraph, count: 300)
        for count in [100, 1000] {
            let appRoot = root.appendingPathComponent("library-\(count)")
            let collections = appRoot.appendingPathComponent("Collections")
            let collectionID = UUID()
            let folder = collections.appendingPathComponent(collectionID.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var records: [DocumentRecord] = []
            for index in 0..<count {
                let path = "article-\(index).md", title = "概率论笔记 \(index)"
                try Data(("# \(title)\n\n" + body).utf8).write(to: folder.appendingPathComponent(path))
                records.append(DocumentRecord(id: UUID(), title: title, relativePath: path))
            }
            let manifest = CollectionManifest(id: collectionID, name: "概率论", importedAt: Date(), fingerprint: "fixture", documents: records)
            try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent(".reader-collection.json"))
            let (store, startupMS, startupGapMS, startupTicks) = await measure {
                let store = LibraryStore(rootURL: appRoot, seedSamples: false)
                #if !BASELINE
                await store.loadIfNeeded()
                #endif
                return store
            }
            if let error = store.errorMessage { throw ReaderFailure(message: error) }
            var searches: [[String: Any]] = []
            for query in ["贝", "贝叶", "贝叶斯公式", "不存在的知识点", "qzxmissingterm"] {
                let (matches, ms, maximumGapMS, ticks) = try await measure {
                    #if BASELINE
                    return store.visibleDocuments(filter: "all", search: query).count
                    #else
                    return try await store.searchEngine.matches(query: query, documents: store.documents, revision: store.contentRevision).count
                    #endif
                }
                searches.append(["query": query, "matches": matches, "ms": ms,
                                 "mainActorMaximumGapMS": maximumGapMS, "mainActorTicks": ticks])
            }
            #if BASELINE
            let matches: Set<UUID>? = nil
            #else
            let matches = try await store.searchEngine.matches(query: "qzxmissingterm", documents: store.documents, revision: store.contentRevision)
            #endif
            let (_, cacheMS, _, _) = await measure {
                let token = UUID()
                for _ in 0..<1000 {
                    #if BASELINE
                    _ = store.visibleDocuments(filter: "all", search: "qzxmissingterm")
                    #else
                    _ = store.visibleDocuments(filter: "all", matching: matches, searchToken: token)
                    #endif
                }
            }
            #if BASELINE
            let firstBodyMS = 0.0 // Already eagerly loaded by the constructor.
            let bodyBytes = 0
            #else
            let (_, firstBodyMS, _, _) = try await measure { try await store.content.markdown(for: store.documents[0]) }
            let bodyBytes = await store.content.retainedBytes
            #endif
            let result: [String: Any] = ["documents": count, "totalMarkdownMB": Double(body.utf8.count * count) / 1_000_000,
                "loadStoreMS": startupMS, "startupMainActorMaximumGapMS": startupGapMS, "startupMainActorTicks": startupTicks,
                "search": searches, "cachedShelf1000CallsMS": cacheMS, "firstBodyMS": firstBodyMS, "retainedBodyBytes": bodyBytes]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
