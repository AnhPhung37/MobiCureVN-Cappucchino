import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Retrieves medical context from the bundled vectorstore.db using FTS5 (BM25).
/// Replaces the hardcoded mock Retriever.
///
/// Query path (current):  FTS5 keyword search  — no on-device embedding needed
/// Query path (future):   vec_chunks KNN        — requires CoreML query embedder
final class SQLiteRetriever {

    private var db: OpaquePointer?

    init() {
        guard let url = Bundle.main.url(forResource: "vectorstore", withExtension: "db") else {
            print("SQLiteRetriever: vectorstore.db not found in bundle")
            return
        }
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("SQLiteRetriever: failed to open db — \(errorMessage)")
            db = nil
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: - Public

    func retrieve(query: String, topK: Int = 5) -> RetrievedContext {
        guard db != nil else {
            return RetrievedContext(chunks: [], confidenceScore: 0, sources: [])
        }

        let ftsQuery = buildFTSQuery(from: query)
        let rows = runFTS(query: ftsQuery, limit: topK)

        guard !rows.isEmpty else {
            return RetrievedContext(chunks: [], confidenceScore: 0, sources: [])
        }

        let chunks = rows.map(\.chunk)
        let confidence = calculateConfidence(rows: rows)
        let sources = dedupedSources(from: rows)

        return RetrievedContext(chunks: chunks, confidenceScore: confidence, sources: sources)
    }

    // MARK: - FTS Query Builder

    private func buildFTSQuery(from text: String) -> String {
        // Split into tokens, strip FTS5 special chars, apply prefix match
        let forbidden = CharacterSet.alphanumerics.union(.whitespaces).inverted
        return text
            .components(separatedBy: .whitespaces)
            .compactMap { token -> String? in
                let cleaned = token.components(separatedBy: forbidden).joined()
                return cleaned.isEmpty ? nil : "\(cleaned)*"
            }
            .joined(separator: " ")
    }

    // MARK: - FTS5 Search

    private struct FTSRow {
        let chunk: ContextChunk
        let score: Double
        let docID: String
        let sourceOrg: String
        let docType: String
        let credibilityTier: Int
    }

    private func runFTS(query: String, limit: Int) -> [FTSRow] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let sql = """
            SELECT
                c.chunk_id,
                c.doc_id,
                c.text,
                c.section,
                c.source_org,
                c.doc_type,
                c.credibility_tier,
                c.token_count,
                -fts.rank AS score
            FROM chunks_fts fts
            JOIN chunks c ON fts.rowid = c.rowid
            WHERE chunks_fts MATCH ?
            ORDER BY rank
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteRetriever: prepare failed — \(errorMessage)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, query, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [FTSRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkID    = string(stmt, col: 0)
            let docID      = string(stmt, col: 1)
            let text       = string(stmt, col: 2)
            let section    = string(stmt, col: 3)
            let sourceOrg  = string(stmt, col: 4)
            let docType    = string(stmt, col: 5)
            let tier       = Int(sqlite3_column_int(stmt, 6))
            let score      = sqlite3_column_double(stmt, 8)

            let chunk = ContextChunk(
                id: chunkID,
                content: text,
                section: section,
                sourceID: docID,
                relevanceScore: min(score / 10.0, 1.0)  // normalise BM25 score to 0–1
            )
            rows.append(FTSRow(
                chunk: chunk,
                score: score,
                docID: docID,
                sourceOrg: sourceOrg,
                docType: docType,
                credibilityTier: tier
            ))
        }
        return rows
    }

    // MARK: - Confidence + Sources

    private func calculateConfidence(rows: [FTSRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        let avgRelevance = rows.map(\.chunk.relevanceScore).reduce(0, +) / Double(rows.count)
        let countBoost   = min(Double(rows.count) / 5.0, 1.0)
        // Boost confidence for tier-1 (clinical guidelines) results
        let tierBoost    = rows.contains(where: { $0.credibilityTier == 1 }) ? 0.1 : 0.0
        return min(avgRelevance * (0.7 + 0.3 * countBoost) + tierBoost, 1.0)
    }

    private func dedupedSources(from rows: [FTSRow]) -> [MedicalSource] {
        var seen = Set<String>()
        return rows.compactMap { row -> MedicalSource? in
            guard !seen.contains(row.docID) else { return nil }
            seen.insert(row.docID)
            return MedicalSource(
                id: row.docID,
                title: row.chunk.section ?? row.docID,
                excerpt: String(row.chunk.content.prefix(120)),
                page: 0,
                documentName: "\(row.sourceOrg) — \(row.docType)"
            )
        }
    }

    // MARK: - SQLite Helpers

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func string(_ stmt: OpaquePointer?, col: Int32) -> String {
        guard let cStr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: cStr)
    }
}
