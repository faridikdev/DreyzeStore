import XCTest
@testable import DreyzeStore

final class SemanticVersionTests: XCTestCase {
    func testNumericComponentsAreComparedNumerically() throws {
        let one = try XCTUnwrap(SemanticVersion("1.0"))
        let oneOne = try XCTUnwrap(SemanticVersion("1.1"))
        let oneNine = try XCTUnwrap(SemanticVersion("1.9"))
        let oneTen = try XCTUnwrap(SemanticVersion("1.10"))

        XCTAssertLessThan(one, oneOne)
        XCTAssertLessThan(oneNine, oneTen)
    }

    func testPrereleasePrecedesStableAndUsesSemVerOrdering() throws {
        let beta = try XCTUnwrap(SemanticVersion("2.0-beta.2"))
        let laterBeta = try XCTUnwrap(SemanticVersion("2.0-beta.11"))
        let release = try XCTUnwrap(SemanticVersion("2.0"))

        XCTAssertLessThan(beta, laterBeta)
        XCTAssertLessThan(laterBeta, release)
    }

    func testLargeNumericComponentsDoNotOverflow() throws {
        let low = try XCTUnwrap(SemanticVersion("2.999999999999999999999"))
        let high = try XCTUnwrap(SemanticVersion("2.1000000000000000000000"))

        XCTAssertLessThan(low, high)
    }

    func testInvalidVersionsAreRejected() {
        XCTAssertNil(SemanticVersion("01.2"))
        XCTAssertNil(SemanticVersion("2"))
        XCTAssertNil(SemanticVersion("2.0-"))
        XCTAssertNil(SemanticVersion("2.0+"))
        XCTAssertNil(SemanticVersion("2.0.0-beta.01"))
    }
}
