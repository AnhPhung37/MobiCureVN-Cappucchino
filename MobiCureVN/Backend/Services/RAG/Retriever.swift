import Foundation

/// Retriever: manages semantic search over medical documents
/// MVP implementation: in-memory mock retriever
/// Production: integrate with vector DB (Pinecone, Weaviate, Milvus, etc.)
final class Retriever {
    
    private let queryRefiner: QueryRefiner
    
    // MARK: - Mock Data (MVP)
    
    private var mockDocuments: [ContextChunk] = []
    private var mockSources: [String: MedicalSource] = [:]
    
    init() {
        self.queryRefiner = QueryRefiner()
        setupMockKnowledgeBase()
    }
    
    /// Retrieve relevant medical context for a query
    /// Parameters:
    /// - query: user's medical question (will be refined)
    /// - topK: number of chunks to retrieve
    func retrieve(query: String, topK: Int = 5) async -> RetrievedContext {
        // Step 1: Refine query
        let refinedQuery = queryRefiner.refineQuery(query)
        
        // Step 2: Retrieve chunks (mock implementation)
        let retrievedChunks = await performRetrieval(refinedQuery, topK: topK)
        
        // Step 3: Calculate confidence score
        let confidenceScore = calculateConfidence(retrievedChunks)
        
        // Step 4: Gather sources
        let sources = gatherSources(from: retrievedChunks)
        
        return RetrievedContext(
            chunks: retrievedChunks,
            confidenceScore: confidenceScore,
            sources: sources
        )
    }
    
    // MARK: - Private Retrieval Logic
    
    private func performRetrieval(_ refinedQuery: String, topK: Int) async -> [ContextChunk] {
        // Mock implementation: keyword + simple similarity
        let queryTerms = refinedQuery.lowercased().split(separator: " ")
        
        var scored: [(chunk: ContextChunk, score: Double)] = []
        
        for chunk in mockDocuments {
            var score = 0.0
            let chunkLower = (chunk.content + " " + chunk.section).lowercased()
            
            for term in queryTerms {
                if chunkLower.contains(String(term)) {
                    score += 1.0
                }
            }
            
            if score > 0 {
                scored.append((chunk, score: score / Double(queryTerms.count)))
            }
        }
        
        // Sort by score and return top-k
        let sorted = scored.sorted { $0.score > $1.score }
        return Array(sorted.prefix(topK)).map { $0.chunk }
    }
    
    private func calculateConfidence(_ chunks: [ContextChunk]) -> Double {
        guard !chunks.isEmpty else { return 0.0 }
        
        let avgRelevance = chunks.map { $0.relevanceScore }.reduce(0, +) / Double(chunks.count)
        let countBoost = min(Double(chunks.count) / 5.0, 1.0) // Boost if more chunks found
        
        return min(avgRelevance * (0.7 + 0.3 * countBoost), 1.0)
    }
    
    private func gatherSources(from chunks: [ContextChunk]) -> [MedicalSource] {
        var sources: [MedicalSource] = []
        var seen = Set<String>()
        
        for chunk in chunks {
            if !seen.contains(chunk.sourceID),
               let source = mockSources[chunk.sourceID] {
                sources.append(source)
                seen.insert(chunk.sourceID)
            }
        }
        
        return sources
    }
    
    // MARK: - Mock Knowledge Base Setup
    
    private func setupMockKnowledgeBase() {
        // Sample medical documents (MVP)
        
        // Source 1: Post-operative wound care
        let source1 = MedicalSource(
            id: "post-op-wound",
            title: "Post-operative Wound Care Guidelines",
            excerpt: "Keep surgical site clean and dry for first 48 hours",
            page: 1,
            documentName: "Vietnam Ministry of Health - Post-op Care"
        )
        mockSources["post-op-wound"] = source1
        
        mockDocuments.append(contentsOf: [
            ContextChunk(
                id: "chunk_1",
                content: "Surgical wounds should be kept clean and dry for the first 48 hours after surgery. Change dressing daily or as directed by your surgeon. Watch for signs of infection including redness, swelling, warmth, pain, or pus drainage.",
                section: "Wound Care",
                sourceID: "post-op-wound",
                relevanceScore: 0.95
            ),
            ContextChunk(
                id: "chunk_2",
                content: "Pain after surgery is normal in the first few days. Take pain medication as prescribed by your doctor. Do not exceed recommended dosage. Report severe or worsening pain to your healthcare team.",
                section: "Pain Management",
                sourceID: "post-op-wound",
                relevanceScore: 0.92
            ),
            ContextChunk(
                id: "chunk_3",
                content: "Infection signs include fever over 101F (38.3C), increasing redness, warmth, swelling, pus, or streaking. Contact your doctor immediately if you notice these signs.",
                section: "Infection Prevention",
                sourceID: "post-op-wound",
                relevanceScore: 0.88
            )
        ])
        
        // Source 2: Diet after colorectal surgery
        let source2 = MedicalSource(
            id: "colorectal-diet",
            title: "Nutritional Guidelines After Colorectal Surgery",
            excerpt: "Gradual diet progression from clear liquids to regular foods",
            page: 5,
            documentName: "Vietnam Ministry of Health - Surgical Nutrition"
        )
        mockSources["colorectal-diet"] = source2
        
        mockDocuments.append(contentsOf: [
            ContextChunk(
                id: "chunk_4",
                content: "For the first few days after colorectal surgery, stick to clear liquids like broth, juice, and water. Gradually advance to soft foods over 1-2 weeks. Avoid high-fiber foods, fatty foods, and dairy initially.",
                section: "Diet Progression",
                sourceID: "colorectal-diet",
                relevanceScore: 0.90
            ),
            ContextChunk(
                id: "chunk_5",
                content: "Drink at least 2 liters of water daily to support recovery. Avoid alcohol, caffeine, and carbonated beverages in the first week. Eat slowly and chew thoroughly to aid digestion.",
                section: "Hydration and Nutrition",
                sourceID: "colorectal-diet",
                relevanceScore: 0.85
            )
        ])
        
        // Source 3: General post-operative recovery
        let source3 = MedicalSource(
            id: "general-recovery",
            title: "General Post-operative Recovery Guidelines",
            excerpt: "Activity restrictions and healing timeline",
            page: 10,
            documentName: "WHO - Post-operative Care Standards"
        )
        mockSources["general-recovery"] = source3
        
        mockDocuments.append(contentsOf: [
            ContextChunk(
                id: "chunk_6",
                content: "Most patients can resume light activities within 2-3 weeks. Avoid strenuous exercise for 4-6 weeks. Follow your surgeon's specific restrictions. Gradual return to normal activities is important for proper healing.",
                section: "Activity Guidelines",
                sourceID: "general-recovery",
                relevanceScore: 0.82
            ),
            ContextChunk(
                id: "chunk_7",
                content: "Medications should be taken exactly as prescribed. Do not skip doses. Report any side effects to your healthcare provider. Store medications in a cool, dry place away from children.",
                section: "Medication Safety",
                sourceID: "general-recovery",
                relevanceScore: 0.78
            )
        ])
    }
}

/// RAG Service: orchestrates full retrieval + context validation pipeline
final class RAGService {
    
    private let retriever: Retriever
    private let queryRefiner: QueryRefiner
    
    init() {
        self.retriever = Retriever()
        self.queryRefiner = QueryRefiner()
    }
    
    /// Full RAG pipeline: refine → retrieve → validate
    func process(userQuery: String) async -> RetrievedContext {
        // Step 1: Refine query
        let refinedQuery = await queryRefiner.refineQuery(userQuery)
        print("RAGService: Refined query: '\(userQuery)' → '\(refinedQuery)'")
        
        // Step 2: Retrieve context
        let context = await retriever.retrieve(query: refinedQuery)
        print("RAGService: Retrieved \(context.chunks.count) chunks with confidence: \(String(format: "%.2f", context.confidenceScore))")
        
        // Step 3: Validate and return
        return context
    }
}
