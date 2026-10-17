import XCTest
import ClawdCoreChecks

final class UsageTests: XCTestCase {
    func testUsageParsingAndStateRules() throws {
        XCTAssertGreaterThanOrEqual(try CoreChecks.run(), 28)
    }
}
