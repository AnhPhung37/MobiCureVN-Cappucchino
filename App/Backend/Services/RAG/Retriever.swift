import Foundation

/// RAGService: refines query once, then retrieves from vectorstore.db via FTS5.
final class RAGService {

    private let retriever: SQLiteRetriever
    private let queryRefiner: QueryRefiner

    init() {
        self.retriever = SQLiteRetriever()
        self.queryRefiner = QueryRefiner()
    }

    func process(userQuery: String) async -> RetrievedContext {
        let refined = queryRefiner.refineQuery(userQuery)
        print("RAGService: '\(userQuery)' → '\(refined.baseQuery)'")

        let context = retriever.retrieve(query: refined.baseQuery, enrichedTerms: refined.enrichedTerms)
        print("RAGService: \(context.chunks.count) chunks, confidence=\(String(format: "%.2f", context.confidenceScore))")

        return context
    }
}
