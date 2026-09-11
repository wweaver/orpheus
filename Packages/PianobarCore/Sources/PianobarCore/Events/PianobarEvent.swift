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
    /// A station was deleted. Carries no list: see EventParser for why the
    /// payload's station list can't be trusted for this event.
    case stationDeleted
    case userLogin(LoginResult)
    case pandoraError(code: Int, message: String)
    case networkError(message: String)
}

/// Outcome of a `userlogin` event.
///
/// The distinction matters: Pandora rejecting the password means the stored
/// credentials are wrong and must be cleared, whereas failing to *reach*
/// Pandora says nothing about them — clearing on a DNS blip would silently
/// throw away working credentials and force a manual re-login.
public struct LoginResult: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        /// Pandora rejected the credentials (`pRet != 1`).
        case credentials
        /// Couldn't reach Pandora at all (`wRet != 0`).
        case network
    }

    /// nil when the login succeeded.
    public let failure: Failure?
    public let message: String

    public var isSuccess: Bool { failure == nil }

    public init(failure: Failure?, message: String) {
        self.failure = failure
        self.message = message
    }
}
