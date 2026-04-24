import XCTest
import Combine
@testable import PianobarCore

@MainActor
final class PlaybackStateTests: XCTestCase {
    private var subs = Set<AnyCancellable>()

    // AsyncStream.makeStream() is macOS 14+; we support macOS 13.
    // Capture the continuation manually.
    private func makeEventStream() -> (AsyncStream<PianobarEvent>, AsyncStream<PianobarEvent>.Continuation) {
        var cont: AsyncStream<PianobarEvent>.Continuation!
        let stream = AsyncStream<PianobarEvent> { cont = $0 }
        return (stream, cont)
    }

    func testSongStartUpdatesCurrentSong() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)

        let song = SongInfo(title: "Shivers", artist: "Ed Sheeran", album: "=",
                            coverArtURL: nil, durationSeconds: 228,
                            rating: .unrated, detailURL: nil,
                            stationName: "Imagine Dragons Radio")
        cont.yield(.songStart(song))

        await waitUntil { state.currentSong?.title == "Shivers" }
        XCTAssertEqual(state.currentSong, song)
        XCTAssertEqual(state.progressSeconds, 0)
        XCTAssertTrue(state.isPlaying)
        cont.finish()
    }

    func testSongStartAppendsPreviousToHistory() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        let a = makeSong(title: "A")
        let b = makeSong(title: "B")
        cont.yield(.songStart(a))
        await waitUntil { state.currentSong?.title == "A" }
        cont.yield(.songStart(b))
        await waitUntil { state.currentSong?.title == "B" }
        XCTAssertEqual(state.history.map(\.title), ["A"])
        cont.finish()
    }

    func testStationsChangedReplacesList() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        cont.yield(.stationsChanged([
            Station(id: "1", name: "A", isQuickMix: false),
            Station(id: "2", name: "B", isQuickMix: false)
        ]))
        await waitUntil { state.stations.count == 2 }
        XCTAssertEqual(state.stations.map(\.name), ["A", "B"])
        cont.finish()
    }

    func testUserLoginFailureClearsAuth() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        cont.yield(.userLogin(success: false, message: "Invalid login"))
        await waitUntil { state.authFailure != nil }
        XCTAssertEqual(state.authFailure, "Invalid login")
        cont.finish()
    }

    // Helpers
    private func makeSong(title: String) -> SongInfo {
        SongInfo(title: title, artist: "x", album: "x", coverArtURL: nil,
                 durationSeconds: 100, rating: .unrated, detailURL: nil,
                 stationName: "x")
    }

    private func waitUntil(timeout: Double = 2,
                           _ cond: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never became true")
    }
}
