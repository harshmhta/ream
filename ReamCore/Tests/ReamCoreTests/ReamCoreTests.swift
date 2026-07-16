import XCTest
@testable import ReamCore

final class ReamCoreTests: XCTestCase {
    func testVersionIsSemantic() {
        XCTAssertEqual(ReamCore.version, "0.1.0")
        XCTAssertEqual(ReamCore.name, "ReamCore")
    }

    func testPDFDescriptorStoresURL() {
        let url = URL(fileURLWithPath: "/tmp/example.pdf")
        let descriptor = PDFDescriptor(url: url, pageCount: 3)
        XCTAssertEqual(descriptor.url, url)
        XCTAssertEqual(descriptor.pageCount, 3)
    }

    func testPDFDescriptorDefaultsPageCountToNil() {
        let descriptor = PDFDescriptor(url: URL(fileURLWithPath: "/tmp/x.pdf"))
        XCTAssertNil(descriptor.pageCount)
    }
}
