import XCTest
import SQLite3
@testable import MobiCureVN

/// The vector half of hybrid retrieval runs a `vec0` KNN query, which only works when sqlite-vec is
/// registered on the connection. When it is not, the query fails to prepare and retrieval quietly
/// degrades to FTS-only while still reporting high confidence — so these tests run real queries
/// against the bundled vectorstore.db instead of trusting that `vec_chunks` exists.
@MainActor
final class SQLiteVecRetrievalTests: XCTestCase {

    func testVectorSearchReturnsNeighboursFromTheBundledIndex() {
        let rows = SQLiteRetriever().runVectorSearch(query: "My ostomy pouch is overflowing.", limit: 5)
        XCTAssertEqual(
            rows.count, 5,
            "vector search returned no rows: vec0 is not usable on the retriever's connection, so retrieval is FTS-only"
        )
    }

    func testLinkedSQLiteVecIsTheVersionThatBuiltTheIndex() throws {
        let db = try openBundledIndex()
        defer { sqlite3_close(db) }

        let linked = try XCTUnwrap(text(db, "SELECT vec_version()"))
        let indexed = try XCTUnwrap(text(db, "SELECT value FROM vec_chunks_info WHERE key = 'CREATE_VERSION'"))
        XCTAssertEqual(linked, indexed, "sqlite-vec in the app differs from the version that built vectorstore.db")
    }

    func testAStoredChunkVectorIsItsOwnNearestNeighbour() throws {
        let db = try openBundledIndex()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT c.chunk_id, v.embedding
            FROM vec_chunks v JOIN chunks c ON c.rowid = v.rowid
            ORDER BY v.rowid LIMIT 1 OFFSET 100
            """
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)

        let chunkID = String(cString: try XCTUnwrap(sqlite3_column_text(stmt, 0)))
        let bytes = try XCTUnwrap(sqlite3_column_blob(stmt, 1))
        let count = Int(sqlite3_column_bytes(stmt, 1)) / MemoryLayout<Float>.size
        XCTAssertEqual(count, 384)
        let embedding = Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: count))

        let rows = SQLiteRetriever().runVectorSearch(embedding: embedding, limit: 3)
        XCTAssertEqual(rows.first?.info.chunkID, chunkID)
    }

    // MARK: - Helpers

    private struct IndexError: Error, CustomStringConvertible {
        let description: String
    }

    private func openBundledIndex() throws -> OpaquePointer {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "vectorstore", withExtension: "db"))
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw IndexError(description: "could not open vectorstore.db")
        }
        if let error = SQLiteVec.register(on: db) {
            sqlite3_close(db)
            throw IndexError(description: "sqlite-vec registration failed: \(error)")
        }
        return db
    }

    private func text(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("\(sql) — \(String(cString: sqlite3_errmsg(db)))")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }
}
