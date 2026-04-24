import Foundation
import PianobarCore

/// What to persist across a pause-on-quit cycle so the UI can immediately
/// show the state pianobar is still holding internally.
struct SessionSnapshot: Codable {
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

enum SessionStore {
    static let key = "sessionSnapshot.v1"

    static func save(_ snapshot: SessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> SessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
