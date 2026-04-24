import XCTest
@testable import PianobarCore

final class EventParserTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: "Fixtures/event_payloads/\(name)",
                                    withExtension: "txt")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesSongStart() throws {
        let payload = try loadFixture("songstart")
        let event = EventParser.parse(eventType: "songstart", payload: payload)
        guard case .songStart(let song) = event else {
            return XCTFail("expected .songStart, got \(String(describing: event))")
        }
        XCTAssertEqual(song.title, "Shivers")
        XCTAssertEqual(song.artist, "Ed Sheeran")
        XCTAssertEqual(song.album, "=")
        XCTAssertEqual(song.durationSeconds, 228)
        XCTAssertEqual(song.rating, .unrated)
        XCTAssertEqual(song.stationName, "Imagine Dragons Radio")
        XCTAssertEqual(song.coverArtURL?.absoluteString, "https://example.com/cover.jpg")
    }

    func testParsesUserGetStations() throws {
        let payload = try loadFixture("usergetstations")
        let event = EventParser.parse(eventType: "usergetstations", payload: payload)
        guard case .stationsChanged(let stations) = event else {
            return XCTFail()
        }
        XCTAssertEqual(stations.count, 3)
        XCTAssertEqual(stations[0], Station(id: "123", name: "Imagine Dragons Radio", isQuickMix: false))
        XCTAssertEqual(stations[1], Station(id: "456", name: "Bad Bunny 360° Radio", isQuickMix: false))
        XCTAssertEqual(stations[2], Station(id: "789", name: "The Beatles Radio", isQuickMix: false))
    }

    func testUserLoginSuccess() throws {
        let payload = try loadFixture("userlogin_ok")
        let event = EventParser.parse(eventType: "userlogin", payload: payload)
        guard case .userLogin(let success, _) = event else { return XCTFail() }
        XCTAssertTrue(success)
    }

    func testUserLoginFailure() throws {
        let payload = try loadFixture("userlogin_fail")
        let event = EventParser.parse(eventType: "userlogin", payload: payload)
        guard case .userLogin(let success, let message) = event else { return XCTFail() }
        XCTAssertFalse(success)
        XCTAssertEqual(message, "Invalid login")
    }

    func testSimpleEventTypes() {
        XCTAssertEqual(EventParser.parse(eventType: "songfinish", payload: ""),
                       .songFinish)
        XCTAssertEqual(EventParser.parse(eventType: "songlove", payload: ""),
                       .songLove)
        XCTAssertEqual(EventParser.parse(eventType: "songban", payload: ""),
                       .songBan)
        XCTAssertEqual(EventParser.parse(eventType: "songshelf", payload: ""),
                       .songShelf)
    }

    func testUnknownEventTypeReturnsNil() {
        XCTAssertNil(EventParser.parse(eventType: "somethingWeird", payload: ""))
    }

    func testMalformedPayloadDoesNotCrash() {
        let event = EventParser.parse(eventType: "songstart", payload: "nonsense\n===")
        // parser should return nil or a .songStart with best-effort fields
        // but must not crash
        _ = event
    }
}
