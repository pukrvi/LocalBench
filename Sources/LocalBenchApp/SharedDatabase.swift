import Foundation
import LocalBenchCore

/// Single SQLite store shared by all app sections (WAL allows concurrent
/// readers; writes are serialized by the store's own lock).
@MainActor
enum SharedDatabase {
    private static var instance: SQLiteStore?

    static func shared() throws -> SQLiteStore {
        if let instance { return instance }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalBench", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = try SQLiteStore(path: url.appendingPathComponent("localbench.sqlite").path)
        instance = store
        return store
    }
}
