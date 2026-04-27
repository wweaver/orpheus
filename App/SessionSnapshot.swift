import Foundation
import PianobarCore

/// What to persist across launches so the UI can immediately show whatever
/// pianobar is still holding internally. We keep an app-private Codable
/// "wire" struct so the public PianobarCore models don't have to be Codable
/// — synthesized Codable conformance was inflating their AttributeGraph
/// metadata enough to crash SwiftUI on macOS 26.4.1.
struct SessionSnapshot {
    var stations: [Station]
    var currentStation: Station?
    var currentSong: SongInfo?
    var progressSeconds: Int
    var wasPlaying: Bool
    var savedAt: Date

    var elapsedSinceSavedSeconds: Int {
        max(0, Int(Date().timeIntervalSince(savedAt)))
    }
}

// MARK: - Persistence

private struct WireStation: Codable {
    var id: String
    var name: String
    var isQuickMix: Bool

    init(_ s: Station) {
        id = s.id; name = s.name; isQuickMix = s.isQuickMix
    }
    var model: Station { Station(id: id, name: name, isQuickMix: isQuickMix) }
}

private struct WireSong: Codable {
    var title: String
    var artist: String
    var album: String
    var coverArtURL: URL?
    var durationSeconds: Int
    var rating: String      // Rating.rawValue
    var detailURL: URL?
    var artistDetailURL: URL?
    var albumDetailURL: URL?
    var stationName: String

    init(_ s: SongInfo) {
        title = s.title; artist = s.artist; album = s.album
        coverArtURL = s.coverArtURL; durationSeconds = s.durationSeconds
        rating = s.rating.rawValue; detailURL = s.detailURL
        artistDetailURL = s.artistDetailURL; albumDetailURL = s.albumDetailURL
        stationName = s.stationName
    }
    var model: SongInfo {
        SongInfo(
            title: title, artist: artist, album: album,
            coverArtURL: coverArtURL, durationSeconds: durationSeconds,
            rating: Rating(rawValue: rating) ?? .unrated,
            detailURL: detailURL,
            artistDetailURL: artistDetailURL,
            albumDetailURL: albumDetailURL,
            stationName: stationName
        )
    }
}

private struct WireSnapshot: Codable {
    var stations: [WireStation]
    var currentStation: WireStation?
    var currentSong: WireSong?
    var progressSeconds: Int
    var wasPlaying: Bool
    var savedAt: Date

    init(_ s: SessionSnapshot) {
        stations = s.stations.map(WireStation.init)
        currentStation = s.currentStation.map(WireStation.init)
        currentSong = s.currentSong.map(WireSong.init)
        progressSeconds = s.progressSeconds
        wasPlaying = s.wasPlaying
        savedAt = s.savedAt
    }
    var model: SessionSnapshot {
        SessionSnapshot(
            stations: stations.map(\.model),
            currentStation: currentStation?.model,
            currentSong: currentSong?.model,
            progressSeconds: progressSeconds,
            wasPlaying: wasPlaying,
            savedAt: savedAt
        )
    }
}

enum SessionStore {
    static let key = "sessionSnapshot.v1"

    static func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(WireSnapshot(snapshot)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return (try? JSONDecoder().decode(WireSnapshot.self, from: data))?.model
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
