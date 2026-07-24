import XCTest
@testable import MobiCureVN

/// Tests for the session fact memory: the deterministic parsing and store logic that runs
/// around the (non-deterministic) LLM extraction call. The LLM call itself isn't exercised
/// here — these cover the parts that must behave predictably regardless of what the model says.
///
/// A new build passes if:
///   - Well-formed JSON (including prose-wrapped and numeric values) parses into facts
///   - Junk / empty / "[]" replies parse to no facts (fail-closed)
///   - Restating a key overwrites rather than duplicates it (latest statement wins)
///   - The per-conversation cap evicts oldest facts
///   - Facts are isolated per conversationId
final class SessionMemoryTests: XCTestCase {

    // MARK: - Extractor parsing

    func testParsesWellFormedJSON() {
        let facts = SessionFactExtractor.parse(#"[{"key":"name","value":"Anh"},{"key":"allergy","value":"penicillin"}]"#)
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts.first, .init(key: "name", value: "Anh"))
        XCTAssertEqual(facts.last, .init(key: "allergy", value: "penicillin"))
    }

    func testParsesJSONWrappedInProse() {
        // Small models sometimes ignore "ONLY the JSON array" and add commentary.
        let reply = #"Sure! Here are the facts: [{"key":"age","value":"34"}] Hope that helps."#
        let facts = SessionFactExtractor.parse(reply)
        XCTAssertEqual(facts, [.init(key: "age", value: "34")])
    }

    func testParsesNumericValue() {
        // The model may emit age as a number rather than a string.
        let facts = SessionFactExtractor.parse(#"[{"key":"age","value":34}]"#)
        XCTAssertEqual(facts, [.init(key: "age", value: "34")])
    }

    func testStripsThinkingPreamble() {
        let reply = "<think>The user said their name is Anh.</think>[{\"key\":\"name\",\"value\":\"Anh\"}]"
        XCTAssertEqual(SessionFactExtractor.parse(reply), [.init(key: "name", value: "Anh")])
    }

    func testFailsClosedOnEmptyArray() {
        XCTAssertTrue(SessionFactExtractor.parse("[]").isEmpty)
    }

    func testFailsClosedOnJunk() {
        XCTAssertTrue(SessionFactExtractor.parse("I don't know what to extract.").isEmpty)
        XCTAssertTrue(SessionFactExtractor.parse("").isEmpty)
        XCTAssertTrue(SessionFactExtractor.parse("[{broken").isEmpty)
    }

    func testSkipsFactsMissingKeyOrValue() {
        let facts = SessionFactExtractor.parse(#"[{"key":"","value":"x"},{"key":"name","value":""},{"key":"sex","value":"female"}]"#)
        XCTAssertEqual(facts, [.init(key: "sex", value: "female")])
    }

    // MARK: - Store behaviour

    func testMergeOverwritesSameKey() async {
        let store = SessionFactStore()
        let convo = UUID()
        await store.merge([.init(key: "age", value: "34")], into: convo)
        await store.merge([.init(key: "age", value: "35")], into: convo) // user corrects themselves

        let facts = await store.facts(for: convo)
        XCTAssertEqual(facts, [.init(key: "age", value: "35")])
    }

    func testMergeNormalizesKeyCasing() async {
        let store = SessionFactStore()
        let convo = UUID()
        await store.merge([.init(key: "Name", value: "Anh")], into: convo)
        await store.merge([.init(key: "NAME", value: "Bao")], into: convo)

        let facts = await store.facts(for: convo)
        XCTAssertEqual(facts, [.init(key: "name", value: "Bao")])
    }

    func testFactsAreIsolatedPerConversation() async {
        let store = SessionFactStore()
        let a = UUID(), b = UUID()
        await store.merge([.init(key: "name", value: "Anh")], into: a)

        let factsB = await store.facts(for: b)
        XCTAssertTrue(factsB.isEmpty)
        let blockB = await store.promptBlock(for: b)
        XCTAssertNil(blockB)
    }

    func testPromptBlockFormatsFacts() async {
        let store = SessionFactStore()
        let convo = UUID()
        await store.merge([.init(key: "wound_location", value: "left forearm")], into: convo)

        let block = await store.promptBlock(for: convo)
        XCTAssertEqual(block, "- Wound location: left forearm")
    }

    func testResetClearsConversation() async {
        let store = SessionFactStore()
        let convo = UUID()
        await store.merge([.init(key: "name", value: "Anh")], into: convo)
        await store.reset(convo)
        let facts = await store.facts(for: convo)
        XCTAssertTrue(facts.isEmpty)
    }

    func testEvictsOldestBeyondCap() async {
        let store = SessionFactStore()
        let convo = UUID()
        // 15 distinct keys; cap is 12, so the 3 oldest should be evicted.
        for i in 0..<15 {
            await store.merge([.init(key: "k\(i)", value: "v\(i)")], into: convo)
        }
        let facts = await store.facts(for: convo)
        XCTAssertEqual(facts.count, 12)
        XCTAssertEqual(facts.first?.key, "k3")     // k0,k1,k2 evicted
        XCTAssertEqual(facts.last?.key, "k14")
    }
}
