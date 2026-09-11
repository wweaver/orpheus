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
    /// A fresh, complete station list. Emitted for `usergetstations` and also
    /// for every station mutation (create/delete/rename/addmusic): pianobar's
    /// `BarUiStartEventCmd` dumps the full `station<N>=` list on those events
    /// too, so a wholesale replace is both simpler and more accurate than
    /// trying to reconstruct per-mutation deltas from a payload that doesn't
    /// identify which station changed.
    case stationsChanged([Station])
    case userLogin(success: Bool, message: String)
    case pandoraError(code: Int, message: String)
    case networkError(message: String)
}
