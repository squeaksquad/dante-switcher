import XCTest
@testable import DanteSyncCore

final class ReleaseVersionTests: XCTestCase {
    func testATagIsReadWithOrWithoutTheV() {
        XCTAssertEqual(ReleaseVersion("v0.3.0")?.parts, [0, 3, 0])
        XCTAssertEqual(ReleaseVersion("0.3.0")?.parts, [0, 3, 0])
    }

    func testNumbersCompareAsNumbers() throws {
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.9")), try XCTUnwrap(ReleaseVersion("0.10")))
        XCTAssertLessThan(try XCTUnwrap(ReleaseVersion("0.2.0")), try XCTUnwrap(ReleaseVersion("v0.2.1")))
        XCTAssertGreaterThan(try XCTUnwrap(ReleaseVersion("1.0")), try XCTUnwrap(ReleaseVersion("0.99.99")))
    }

    func testMissingPartsCountAsZero() {
        XCTAssertEqual(ReleaseVersion("0.2"), ReleaseVersion("0.2.0"))
        XCTAssertFalse(ReleaseVersion("0.2")! < ReleaseVersion("0.2.0")!)
    }

    func testAnythingElseIsNotAVersion() {
        XCTAssertNil(ReleaseVersion("0.3.0-beta"))
        XCTAssertNil(ReleaseVersion("v"))
        XCTAssertNil(ReleaseVersion("0..3"))
        XCTAssertNil(ReleaseVersion("latest"))
    }
}
