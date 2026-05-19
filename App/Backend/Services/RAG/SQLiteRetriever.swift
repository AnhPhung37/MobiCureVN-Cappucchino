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
    private var hasFTSIndex: Bool = false
    private var hasVecIndex: Bool = false
    private var hasPageStartColumn: Bool = false
    private var queryEmbedder: QueryEmbedder?

    init() {
        guard let url = Bundle.main.url(forResource: "vectorstore", withExtension: "db") else {
            print("SQLiteRetriever: vectorstore.db not found in bundle")
            return
        }
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) != SQLITE_OK {
            print("SQLiteRetriever: failed to open db — \(errorMessage)")
            db = nil
            return
        }

        hasFTSIndex = tableExists("chunks_fts")
        hasVecIndex = tableExists("vec_chunks")
        hasPageStartColumn = columnExists(tableName: "chunks", columnName: "page_start")
        queryEmbedder = QueryEmbedder()
        if !hasFTSIndex {
            print("SQLiteRetriever: chunks_fts not found, using chunks fallback search")
        }
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    // MARK: - Public

    func retrieve(query: String, enrichedTerms: [String] = [], topK: Int = 5) -> RetrievedContext {
        guard db != nil else {
            return RetrievedContext(chunks: [], confidenceScore: 0, sources: [])
        }

        let candidateLimit = max(topK * 3, topK)
        let rows = runFTS(baseQuery: query, enrichedTerms: enrichedTerms, limit: candidateLimit)
        let vectorRows = runVectorSearch(query: query, limit: candidateLimit)
        let mergedRows = mergeRows(ftsRows: rows, vectorRows: vectorRows)
        let dedupedRows = dedupeRowsByContent(mergedRows)
        let finalRows = Array(dedupedRows.prefix(topK))

        guard !finalRows.isEmpty else {
            return RetrievedContext(chunks: [], confidenceScore: 0, sources: [])
        }

        let chunks = finalRows.map { row in
            ContextChunk(
                id: row.info.chunkID,
                content: row.info.text,
                section: row.info.section,
                sourceID: row.info.docID,
                relevanceScore: row.relevanceScore
            )
        }
        let confidence = calculateConfidence(rows: finalRows)
        let sources = dedupedSources(from: finalRows)

        return RetrievedContext(chunks: chunks, confidenceScore: confidence, sources: sources)
    }

    // MARK: - FTS Query Builder

    private func buildFTSQuery(baseText: String, enrichedTerms: [String]) -> String {
        let baseTokens = tokenizeForFTS(baseText)
        let enrichedTokens = enrichedTerms.flatMap { tokenizeForFTS($0) }

        let baseClause = baseTokens.joined(separator: " AND ")
        let enrichedClause = enrichedTokens.joined(separator: " OR ")

        if !baseClause.isEmpty && !enrichedClause.isEmpty {
            return "(\(baseClause)) OR (\(enrichedClause))"
        }

        if !baseClause.isEmpty {
            return baseClause
        }

        return enrichedClause
    }

    private func tokenizeForFTS(_ text: String) -> [String] {
        let forbidden = CharacterSet.alphanumerics.union(.whitespaces).inverted
        var seen = Set<String>()
        return text
            .components(separatedBy: .whitespaces)
            .compactMap { token -> String? in
                let cleaned = token.components(separatedBy: forbidden).joined()
                guard cleaned.count >= 3 else { return nil }  // drop stop words: "a", "is", "I"
                let prefixed = "\(cleaned)*"
                return seen.insert(prefixed).inserted ? prefixed : nil
            }
    }

    // MARK: - FTS5 Search

    private struct RowInfo {
        let chunkID: String
        let docID: String
        let text: String
        let section: String
        let sourceOrg: String
        let docType: String
        let credibilityTier: Int
        let pageStart: Int
    }

    private struct ScoredRow {
        let info: RowInfo
        let relevanceScore: Double
    }

    private func runFTS(baseQuery: String, enrichedTerms: [String], limit: Int) -> [ScoredRow] {
        let ftsQuery = buildFTSQuery(baseText: baseQuery, enrichedTerms: enrichedTerms)
        guard !ftsQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        if !hasFTSIndex {
            return runFallbackSearch(baseQuery: baseQuery, enrichedTerms: enrichedTerms, limit: limit)
        }

        let pageSelect = hasPageStartColumn ? "c.page_start" : "0"
        let sql = """
            SELECT
                c.chunk_id,
                c.doc_id,
                c.text,
                c.section,
                c.source_org,
                c.doc_type,
                c.credibility_tier,
                \(pageSelect) AS page_start,
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

        sqlite3_bind_text(stmt, 1, ftsQuery, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rawRows: [(RowInfo, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkID = string(stmt, col: 0)
            let docID = string(stmt, col: 1)
            let text = string(stmt, col: 2)
            let section = string(stmt, col: 3)
            let sourceOrg = string(stmt, col: 4)
            let docType = string(stmt, col: 5)
            let tier = Int(sqlite3_column_int(stmt, 6))
            let pageStart = intOrZero(stmt, col: 7)
            let score = sqlite3_column_double(stmt, 8)

            rawRows.append((
                RowInfo(
                    chunkID: chunkID,
                    docID: docID,
                    text: text,
                    section: section,
                    sourceOrg: sourceOrg,
                    docType: docType,
                    credibilityTier: tier,
                    pageStart: pageStart
                ),
                score
            ))
        }

        return normalizeRows(rawRows)
    }

    private func runFallbackSearch(baseQuery: String, enrichedTerms: [String], limit: Int) -> [ScoredRow] {
        let baseTokens = tokenizePlain(baseQuery)
        let enrichedTokens = enrichedTerms.flatMap { tokenizePlain($0) }
        let tokens = baseTokens + enrichedTokens

        guard !tokens.isEmpty else { return [] }

        let conditions = tokens.map { _ in "LOWER(c.text) LIKE LOWER(?) OR LOWER(COALESCE(c.section, '')) LIKE LOWER(?)" }
            .joined(separator: " OR ")

        let pageSelect = hasPageStartColumn ? "c.page_start" : "0"
        let sql = """
            SELECT
                c.chunk_id,
                c.doc_id,
                c.text,
                c.section,
                c.source_org,
                c.doc_type,
                c.credibility_tier,
                \(pageSelect) AS page_start
            FROM chunks c
            WHERE \(conditions)
            LIMIT 200
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteRetriever: fallback prepare failed — \(errorMessage)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        for token in tokens {
            let pattern = "%\(token)%"
            sqlite3_bind_text(stmt, bindIndex, pattern, -1, SQLITE_TRANSIENT)
            bindIndex += 1
            sqlite3_bind_text(stmt, bindIndex, pattern, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }

        var rawRows: [(RowInfo, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkID = string(stmt, col: 0)
            let docID = string(stmt, col: 1)
            let text = string(stmt, col: 2)
            let section = string(stmt, col: 3)
            let sourceOrg = string(stmt, col: 4)
            let docType = string(stmt, col: 5)
            let tier = Int(sqlite3_column_int(stmt, 6))
            let pageStart = intOrZero(stmt, col: 7)

            let haystack = (text + " " + section).lowercased()
            let baseMatches = baseTokens.reduce(0) { partial, token in
                partial + (haystack.contains(token.lowercased()) ? 1 : 0)
            }
            let enrichedMatches = enrichedTokens.reduce(0) { partial, token in
                partial + (haystack.contains(token.lowercased()) ? 1 : 0)
            }
            let score = Double(baseMatches * 2 + enrichedMatches)

            rawRows.append((
                RowInfo(
                    chunkID: chunkID,
                    docID: docID,
                    text: text,
                    section: section,
                    sourceOrg: sourceOrg,
                    docType: docType,
                    credibilityTier: tier,
                    pageStart: pageStart
                ),
                score
            ))
        }

        let normalized = normalizeRows(rawRows)
        return normalized
            .sorted { $0.relevanceScore > $1.relevanceScore }
            .prefix(limit)
            .map { $0 }
    }

    private func runVectorSearch(query: String, limit: Int) -> [ScoredRow] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard hasVecIndex, let embedder = queryEmbedder else { return [] }
        guard let embedding = embedder.embed(query) else { return [] }

        let pageSelect = hasPageStartColumn ? "c.page_start" : "0"
        let sql = """
            SELECT
                c.chunk_id,
                c.doc_id,
                c.text,
                c.section,
                c.source_org,
                c.doc_type,
                c.credibility_tier,
                \(pageSelect) AS page_start,
                v.distance
            FROM vec_chunks v
            JOIN chunks c ON v.rowid = c.rowid
            WHERE v.embedding MATCH ?
              AND k = ?
            ORDER BY v.distance
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLiteRetriever: vector prepare failed — \(errorMessage)")
            return []
        }
        defer { sqlite3_finalize(stmt) }

        let blob = floatArrayToData(embedding)
        blob.withUnsafeBytes { buffer in
            sqlite3_bind_blob(stmt, 1, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rawRows: [(RowInfo, Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chunkID = string(stmt, col: 0)
            let docID = string(stmt, col: 1)
            let text = string(stmt, col: 2)
            let section = string(stmt, col: 3)
            let sourceOrg = string(stmt, col: 4)
            let docType = string(stmt, col: 5)
            let tier = Int(sqlite3_column_int(stmt, 6))
            let pageStart = intOrZero(stmt, col: 7)
            let distance = sqlite3_column_double(stmt, 8)

            rawRows.append((
                RowInfo(
                    chunkID: chunkID,
                    docID: docID,
                    text: text,
                    section: section,
                    sourceOrg: sourceOrg,
                    docType: docType,
                    credibilityTier: tier,
                    pageStart: pageStart
                ),
                -distance
            ))
        }

        return normalizeRows(rawRows)
    }

    private func mergeRows(ftsRows: [ScoredRow], vectorRows: [ScoredRow]) -> [ScoredRow] {
        if vectorRows.isEmpty { return ftsRows }
        if ftsRows.isEmpty { return vectorRows }
        return mergeWithRRF(ftsRows: ftsRows, vectorRows: vectorRows)
    }

    private func mergeWithRRF(ftsRows: [ScoredRow], vectorRows: [ScoredRow]) -> [ScoredRow] {
        let k: Double = 60.0
        let ftsRanks = Dictionary(uniqueKeysWithValues: ftsRows.enumerated().map { ($0.element.info.chunkID, $0.offset + 1) })
        let vectorRanks = Dictionary(uniqueKeysWithValues: vectorRows.enumerated().map { ($0.element.info.chunkID, $0.offset + 1) })

        var infoByID: [String: RowInfo] = [:]
        for row in ftsRows { infoByID[row.info.chunkID] = row.info }
        for row in vectorRows { infoByID[row.info.chunkID] = row.info }

        var scored: [(RowInfo, Double)] = []
        for (chunkID, info) in infoByID {
            let ftsRank = ftsRanks[chunkID]
            let vectorRank = vectorRanks[chunkID]

            let ftsScore = ftsRank != nil ? 1.0 / (k + Double(ftsRank!)) : 0.0
            let vectorScore = vectorRank != nil ? 1.0 / (k + Double(vectorRank!)) : 0.0
            scored.append((info, ftsScore + vectorScore))
        }

        let maxScore = scored.map { $0.1 }.max() ?? 0
        let normalized = scored.map { info, score -> ScoredRow in
            let relevance = maxScore > 0 ? score / maxScore : 0
            return ScoredRow(info: info, relevanceScore: relevance)
        }

        return normalized.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private func normalizeRows(_ rawRows: [(RowInfo, Double)]) -> [ScoredRow] {
        guard !rawRows.isEmpty else { return [] }
        let scores = rawRows.map { $0.1 }
        let maxScore = scores.max() ?? 1
        let minScore = scores.min() ?? 0
        let range = maxScore - minScore

        return rawRows.map { info, score in
            let normalized = range > 0 ? (score - minScore) / range : 1.0
            return ScoredRow(info: info, relevanceScore: normalized)
        }
    }

    private func tokenizePlain(_ text: String) -> [String] {
        let forbidden = CharacterSet.alphanumerics.union(.whitespaces).inverted
        var seen = Set<String>()
        return text
            .components(separatedBy: .whitespaces)
            .compactMap { token -> String? in
                let cleaned = token.components(separatedBy: forbidden).joined()
                guard !cleaned.isEmpty else { return nil }
                return seen.insert(cleaned).inserted ? cleaned : nil
            }
    }

    private func dedupeRowsByContent(_ rows: [ScoredRow]) -> [ScoredRow] {
        var seen = Set<String>()
        var result: [ScoredRow] = []

        for row in rows {
            let normalized = row.info.text
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fingerprint = String(normalized.prefix(200))

            if seen.insert(fingerprint).inserted {
                result.append(row)
            }
        }

        return result
    }

    private func floatArrayToData(_ values: [Float]) -> Data {
        var copy = values
        return Data(bytes: &copy, count: copy.count * MemoryLayout<Float>.size)
    }

    private func tableExists(_ tableName: String) -> Bool {
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, tableName, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func columnExists(tableName: String, columnName: String) -> Bool {
        let sql = "PRAGMA table_info(\(tableName))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = string(stmt, col: 1)
            if name == columnName { return true }
        }

        return false
    }

    // MARK: - Confidence + Sources

    private func calculateConfidence(rows: [ScoredRow]) -> Double {
        guard !rows.isEmpty else { return 0 }
        let scores = rows.map(\.relevanceScore)
        let avgRelevance = scores.reduce(0, +) / Double(rows.count)
        let topRelevance = scores.first ?? 0
        let uniqueDocs = Set(rows.map { $0.info.docID }).count
        let diversityBoost = min(Double(uniqueDocs) / 3.0, 1.0)
        let tierBoost = rows.first?.info.credibilityTier == 1 ? 0.1 : 0.0

        return min((0.6 * topRelevance + 0.3 * avgRelevance + 0.1 * diversityBoost) + tierBoost, 1.0)
    }

    private func dedupedSources(from rows: [ScoredRow]) -> [MedicalSource] {
        var seen = Set<String>()
        return rows.compactMap { row -> MedicalSource? in
            let docID = row.info.docID
            guard !seen.contains(docID) else { return nil }
            seen.insert(docID)
            let title = row.info.section.isEmpty ? docID : row.info.section
            return MedicalSource(
                id: docID,
                title: title,
                excerpt: String(row.info.text.prefix(120)),
                page: row.info.pageStart,
                documentName: "\(row.info.sourceOrg) — \(row.info.docType)"
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

    private func intOrZero(_ stmt: OpaquePointer?, col: Int32) -> Int {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return 0 }
        return Int(sqlite3_column_int(stmt, col))
    }
}
