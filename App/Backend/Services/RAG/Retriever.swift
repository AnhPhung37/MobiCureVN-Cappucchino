import Foundation

/// RAGService: refines query once, then retrieves from vectorstore.db via FTS5.
///
/// `nonisolated` on purpose. The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// without this annotation the whole retrieval path — FTS5, the sqlite-vec KNN, and the CoreML
/// query embedding, which now runs on EVERY query — would be pinned to the main actor and block
/// the UI while the user waits for an answer. See Docs/BE/optimizationChecklist.md B3.1.
nonisolated final class RAGService {

    private let retriever: SQLiteRetriever
    private let queryRefiner: QueryRefiner

    /// - Parameter retriever: Pass `AppConfig.retriever` to reuse the shared SQLite connection.
    init(retriever: SQLiteRetriever = AppConfig.retriever) {
        self.retriever = retriever
        self.queryRefiner = QueryRefiner()
    }

    func process(userQuery: String) async -> RetrievedContext {
        let refined = queryRefiner.refineQuery(userQuery)
        let context = retriever.retrieve(query: refined.baseQuery, enrichedTerms: refined.enrichedTerms)

        // DEBUG-only: `userQuery` is the patient's message. ChatFlowLog already carries the
        // retrieval summary into the per-turn trace for release-safe observability.
        #if DEBUG
        print("RAGService: '\(userQuery)' → '\(refined.baseQuery)'")
        print("RAGService: \(context.chunks.count) chunks, confidence=\(String(format: "%.2f", context.confidenceScore))")
        #endif

        return context
    }
}
