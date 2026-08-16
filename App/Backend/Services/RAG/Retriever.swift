import Foundation

/// RAGService: refines query once, then retrieves from vectorstore.db via FTS5.
final class RAGService {

    private let retriever: SQLiteRetriever
    private let queryRefiner: QueryRefiner

    /// - Parameter retriever: Pass `AppConfig.retriever` to reuse the shared SQLite connection.
    init(retriever: SQLiteRetriever = AppConfig.retriever) {
        self.retriever = retriever
        self.queryRefiner = QueryRefiner()
    }

    /// - Parameter profileTerms: key medical terms from the persisted patient profile (diagnosis,
    ///   procedure, wound location). They join the refiner's own enrichment terms rather than the
    ///   base query, which keeps retrieval patient-aware without letting the profile outweigh the
    ///   question actually asked: `SQLiteRetriever` ORs base and enriched terms into the FTS
    ///   match, so profile terms lift chunks about this patient's procedure while BM25 still
    ///   ranks on what they typed. The vector pass embeds `baseQuery` alone for the same reason —
    ///   folding a diagnosis into every embedding would pull an off-topic-but-valid question
    ///   ("what should I eat?") toward the diagnosis instead of the answer. Empty for a blank
    ///   profile, which reduces this to the previous behavior exactly.
    func process(userQuery: String, profileTerms: [String] = []) async -> RetrievedContext {
        let refined = queryRefiner.refineQuery(userQuery)

        var seen = Set<String>()
        let enrichedTerms = (refined.enrichedTerms + profileTerms).filter { seen.insert($0).inserted }

        let profileNote = profileTerms.isEmpty ? "" : " (+profile: \(profileTerms.joined(separator: ", ")))"
        print("RAGService: '\(userQuery)' → '\(refined.baseQuery)'\(profileNote)")

        let context = retriever.retrieve(query: refined.baseQuery, enrichedTerms: enrichedTerms)
        print("RAGService: \(context.chunks.count) chunks, confidence=\(String(format: "%.2f", context.confidenceScore))")

        return context
    }
}
