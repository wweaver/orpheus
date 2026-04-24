import Foundation

public enum PianobarEvent: Equatable, Sendable {
    case songStart(SongInfo)
    case songFinish
    case songLove
    case songBan
    case songShelf
    case songBookmark
    case artistBookmark
    case stationFetchPlaylist
    case stationsChanged([Station])
    case stationCreated(Station)
    case stationDeleted(id: String)
    case stationRenamed(id: String, newName: String)
    case userLogin(success: Bool, message: String)
    case pandoraError(code: Int, message: String)
    case networkError(message: String)
}
