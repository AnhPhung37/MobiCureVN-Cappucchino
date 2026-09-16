import XCTest
@testable import MobiCureVN

/// Tests for BundleSourceDocumentProvider — citation cards open the bundled source PDF,
/// scrolled to the cited passage.
final class SourceDocumentProviderTests: XCTestCase {

    private let sut = BundleSourceDocumentProvider()

    private func source(id: String, excerpt: String = "", page: Int = 0) -> MedicalSource {
        MedicalSource(id: id, title: "", excerpt: excerpt, page: page, documentName: "")
    }

    func testResolvesBundledDocumentByDocID() {
        XCTAssertNotNil(sut.documentURL(for: source(id: "RM_ARBS")))
    }

    func testUnbundledDocumentHasNoURL() {
        XCTAssertNil(sut.documentURL(for: source(id: "BCUK_EW_2023")))
        let index = expectation(description: "page lookup")
        Task {
            let page = await sut.pageIndex(for: source(id: "BCUK_EW_2023", excerpt: "anything at all here to search for"))
            XCTAssertNil(page)
            index.fulfill()
        }
        wait(for: [index], timeout: 5)
    }

    func testKnownPageIsUsedWithoutSearching() async {
        let page = await sut.pageIndex(for: source(id: "RM_ARBS", page: 3))
        XCTAssertEqual(page, 2)
    }

    func testLocatesExcerptInDocument() async {
        let excerpt = "You will attend a pre-assessment clinic to check that you are fit enough to have a general anaesthetic and an operation. This check may…"
        let page = await sut.pageIndex(for: source(id: "RM_ARBS", excerpt: excerpt))
        XCTAssertNotNil(page)
    }

    func testSearchWindowsSkipTruncatedLastWordAndSymbols() {
        let windows = BundleSourceDocumentProvider.searchWindows(from: "one two — three four five six seven eig…")
        XCTAssertEqual(windows.first, "one two three four five")
        XCTAssertFalse(windows.contains { $0.contains("eig") })
    }
}
