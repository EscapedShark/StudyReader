import Foundation

/// Encoding and atomic disk I/O have their own executor. The store supplies revisioned value
/// snapshots and awaits completion, so neither large JSON payloads nor disk latency blocks UI.
actor ReadingStateWriter {
    private let beforeWrite: (@Sendable () async throws -> Void)?
    private(set) var writeCount = 0

    init(beforeWrite: (@Sendable () async throws -> Void)? = nil) {
        self.beforeWrite = beforeWrite
    }

    func write(_ state: LocalReadingState, to url: URL) async throws {
        try await beforeWrite?()
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        writeCount += 1
    }
}
