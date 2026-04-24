import XCTest
@testable import PianobarCore

final class SmokeTest: XCTestCase {
    func testVersionExists() {
        XCTAssertEqual(PianobarCore.version, "0.1.0")
    }
}
