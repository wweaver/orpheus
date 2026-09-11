import XCTest
@testable import PianobarCore

@MainActor
final class PlaybackStateStationTests: XCTestCase {

    private func makeState() -> PlaybackState {
        PlaybackState(events: AsyncStream<PianobarEvent> { $0.finish() })
    }

    private func song(title: String = "T", station: String) -> SongInfo {
        SongInfo(title: title, artist: "A", album: "Al", coverArtURL: nil,
                 durationSeconds: 100, rating: .unrated, detailURL: nil,
                 stationName: station)
    }

    private func stations(_ names: [String]) -> [Station] {
        names.enumerated().map { Station(id: String($0.offset), name: $0.element, isQuickMix: false) }
    }

    func testStationsRefreshKeepsCurrentStationWhenNothingIsPlaying() {
        // Resolving solely from `currentSong?.stationName` nil'd this out
        // whenever no song was playing, silently wiping the sidebar's
        // now-playing indicator on every station refresh.
        let state = makeState()
        state.apply(.stationsChanged(stations(["Radio A", "Radio B"])))
        state.apply(.songStart(song(station: "Radio B")))
        XCTAssertEqual(state.currentStation?.name, "Radio B")

        state.restoreSnapshot(stations: [], currentStation: state.currentStation,
                              currentSong: nil, progressSeconds: 0, isPlaying: false)
        state.apply(.stationsChanged(stations(["Radio A", "Radio B"])))
        XCTAssertEqual(state.currentStation?.name, "Radio B")
    }

    func testCurrentStationSurvivesIndexShiftFromADeletedStation() {
        // Station ids fall back to the array index, so anchoring on id would
        // follow the shift and select the wrong station after a delete.
        let state = makeState()
        state.apply(.stationsChanged(stations(["Radio A", "Radio B", "Radio C"])))
        state.apply(.songStart(song(station: "Radio C")))
        XCTAssertEqual(state.currentStation?.name, "Radio C")

        // "Radio A" is deleted; "Radio C" moves from index 2 to index 1.
        state.apply(.stationsChanged(stations(["Radio B", "Radio C"])))
        XCTAssertEqual(state.currentStation?.name, "Radio C")
    }

    func testLiveSongStationWinsOverPreviousSelection() {
        let state = makeState()
        state.apply(.stationsChanged(stations(["Radio A", "Radio B"])))
        state.apply(.songStart(song(station: "Radio A")))
        state.apply(.songStart(song(station: "Radio B")))
        state.apply(.stationsChanged(stations(["Radio A", "Radio B"])))
        XCTAssertEqual(state.currentStation?.name, "Radio B")
    }

    func testEmptyStationListIsIgnored() {
        let state = makeState()
        state.apply(.stationsChanged(stations(["Radio A"])))
        state.apply(.stationsChanged([]))
        XCTAssertEqual(state.stations.map(\.name), ["Radio A"])
    }

    // MARK: - hasLiveSong

    func testRestoreSnapshotDoesNotClaimALiveSong() {
        // Auto-resume and the "is pianobar still at its startup prompt?" check
        // both key off this. A restored snapshot describes the *previous*
        // session, so treating it as a live song silently disabled auto-resume
        // after the first-ever launch.
        let state = makeState()
        XCTAssertFalse(state.hasLiveSong)
        state.restoreSnapshot(stations: stations(["Radio A"]),
                              currentStation: nil,
                              currentSong: song(station: "Radio A"),
                              progressSeconds: 42, isPlaying: false)
        XCTAssertNotNil(state.currentSong)
        XCTAssertFalse(state.hasLiveSong, "a restored snapshot is not a live song")
    }

    func testSongStartMarksALiveSong() {
        let state = makeState()
        state.apply(.songStart(song(station: "Radio A")))
        XCTAssertTrue(state.hasLiveSong)
    }

    // MARK: - Buffering

    func testFetchPlaylistSetsBufferingAndSongStartClearsIt() {
        let state = makeState()
        state.apply(.stationFetchPlaylist)
        XCTAssertTrue(state.isBuffering)
        state.apply(.songStart(song(station: "Radio A")))
        XCTAssertFalse(state.isBuffering)
    }

    // MARK: - History identity

    func testHistoryEntriesGetDistinctIdentitiesEvenWhenIdentical() {
        // History inserts at index 0, so rows keyed by array offset changed
        // identity on every new song.
        let state = makeState()
        let repeated = song(title: "Same", station: "Radio A")
        state.apply(.songStart(repeated))
        state.apply(.songStart(repeated))
        state.apply(.songStart(repeated))
        XCTAssertEqual(state.history.count, 2)
        XCTAssertNotEqual(state.history[0].id, state.history[1].id)
    }
}
