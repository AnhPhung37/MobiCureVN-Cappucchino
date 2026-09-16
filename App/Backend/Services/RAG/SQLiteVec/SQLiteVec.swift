import Foundation
import SQLite3

/// sqlite-vec, statically linked from `sqlite-vec.c` (v0.1.9, the version that built vectorstore.db).
///
/// iOS cannot load an extension dylib at runtime the way the Python pipeline does, so the `vec0`
/// module and `vec_*` functions must be registered on each connection before it touches `vec_chunks`.
enum SQLiteVec {

    /// Returns nil on success, otherwise the reason registration failed.
    static func register(on db: OpaquePointer) -> String? {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_vec_init(db, &message, nil)
        guard rc != SQLITE_OK else { return nil }
        defer { sqlite3_free(message) }
        return message.map { String(cString: $0) } ?? "sqlite3_vec_init returned \(rc)"
    }
}
