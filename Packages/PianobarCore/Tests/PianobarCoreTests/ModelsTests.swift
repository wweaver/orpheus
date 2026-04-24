import XCTest
@testable import PianobarCore

final class ModelsTests: XCTestCase {
    func testRatingFromPianobarInt() {
        XCTAssertEqual(Rating(pianobarInt: 0), .unrated)
        XCTAssertEqual(Rating(pianobarInt: 1), .loved)
        XCTAssertEqual(Rating(pianobarInt: -1), .banned)
        XCTAssertEqual(Rating(pianobarInt: 99), .unrated) // unknown → unrated
    }

    func testSongInfoEquality() {
        let a = SongInfo(title: "Shivers", artist: "Ed Sheeran", album: "=",
                         coverArtURL: nil, durationSeconds: 228, rating: .unrated,
                         detailURL: nil, stationName: "Imagine Dragons Radio")
        let b = a
        XCTAssertEqual(a, b)
    }

    func testStationEquality() {
        let s = Station(id: "4", name: "Bad Bunny 360° Radio", isQuickMix: false)
        XCTAssertEqual(s, Station(id: "4", name: "Bad Bunny 360° Radio", isQuickMix: false))
        XCTAssertNotEqual(s, Station(id: "5", name: "Bad Bunny 360° Radio", isQuickMix: false))
    }
}
