import Foundation
import Combine

@MainActor
public final class PlaybackState: ObservableObject {
    @Published public private(set) var currentSong: SongInfo?
    @Published public private(set) var currentStation: Station?
    @Published public private(set) var stations: [Station] = []
    @Published public private(set) var history: [HistoryEntry] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public var volume: Int = 50
    @Published public private(set) var progressSeconds: Int = 0
    @Published public private(set) var errorBanner: String?
    @Published public private(set) var authFailure: String?
    /// True once pianobar has reported a real `songstart` in *this* session.
    /// Deliberately not set by `restoreSnapshot` — a restored snapshot tells us
    /// what was playing last time, not that pianobar is past its startup
    /// "Select station:" prompt. Callers that need to distinguish those two
    /// cases must use this rather than `currentSong != nil`.
    @Published public private(set) var hasLiveSong: Bool = false
    /// Set while pianobar is fetching a playlist (i.e. after a station switch)
    /// and cleared on the next `songstart`.
    @Published public private(set) var isBuffering: Bool = false

    /// Auto-dismiss timeout for transient error banners. The banner sticks
    /// until either pianobar reports a new song (we infer recovery) or this
    /// many seconds elapse — whichever comes first.
    private static let errorBannerTimeout: TimeInterval = 30

    private var errorBannerSetAt: Date?
    private var consumeTask: Task<Void, Never>?
    private var ticker: Timer?

    public init<E: AsyncSequence>(events: E) where E.Element == PianobarEvent {
        consumeTask = Task { [weak self] in
            do {
                for try await event in events {
                    await self?.apply(event)
                }
            } catch {
                // AsyncStream never throws; other sequences may.
            }
        }
        startTicker()
    }

    deinit {
        consumeTask?.cancel()
        ticker?.invalidate()
    }

    public func apply(_ event: PianobarEvent) {
        switch event {
        case .songStart(let song):
            if let prev = currentSong {
                history.insert(HistoryEntry(song: prev), at: 0)
                if history.count > 50 { history.removeLast(history.count - 50) }
            }
            currentSong = song
            currentStation = stations.first { $0.name == song.stationName }
                              ?? currentStation
            progressSeconds = 0
            isPlaying = true
            hasLiveSong = true
            isBuffering = false
            // A new song means pianobar recovered from whatever transient
            // hiccup the banner was reporting. Don't clear authFailure
            // here — that's a separate, sticky condition.
            errorBanner = nil
            errorBannerSetAt = nil
        case .songFinish:
            break // song will be appended when next songStart fires
        case .songLove:     currentSong?.rating = .loved
        case .songBan:      currentSong?.rating = .banned
        case .songShelf:    break
        case .songBookmark, .artistBookmark: break
        case .stationFetchPlaylist:
            isBuffering = true
        case .stationsChanged(let s):
            // Pianobar occasionally emits an empty stations list during
            // transient errors (network blip, expired session being refreshed,
            // etc.). Keep the last-known list rather than wiping the UI.
            guard !s.isEmpty else { break }
            let previousName = currentStation?.name
            stations = s
            // Re-resolve against the refreshed list. Anchor on the previously
            // selected station's *name*, not its id: pianobar doesn't emit real
            // Pandora station ids, so `Station.id` falls back to the array
            // index, which shifts whenever a station is created or deleted.
            //
            // The old code resolved solely from `currentSong?.stationName`,
            // which evaluated to nil whenever no song was playing and silently
            // wiped the sidebar's now-playing indicator.
            // A live song's station is authoritative; fall back to whatever was
            // selected before, then to keeping what we have.
            currentStation = (hasLiveSong
                    ? stations.first { $0.name == currentSong?.stationName }
                    : nil)
                ?? previousName.flatMap { name in stations.first { $0.name == name } }
                ?? stations.first { $0.name == currentSong?.stationName }
                ?? currentStation
        case .userLogin(let result):
            switch result.failure {
            case nil:
                authFailure = nil
            case .credentials:
                // The stored password is genuinely wrong; the app clears it and
                // returns to the login screen.
                authFailure = result.message.isEmpty ? "Sign-in failed" : result.message
            case .network:
                // Couldn't reach Pandora. Leave the credentials alone, but make
                // this banner sticky (nil `setAt` opts out of the 30s
                // auto-dismiss): the app is unauthenticated and won't recover on
                // its own, so a banner that quietly vanished would leave it
                // looking idle and healthy.
                errorBanner = "Couldn't sign in to Pandora: \(result.message)"
                errorBannerSetAt = nil
            }
        case .pandoraError(_, let msg), .networkError(let msg):
            errorBanner = msg
            errorBannerSetAt = Date()
            // A fetch that failed will never produce the songStart that would
            // otherwise clear this, so "Buffering…" would sit there forever.
            isBuffering = false
        }
    }

    public func setPlaying(_ playing: Bool) { isPlaying = playing }

    /// Pre-populate state from a snapshot taken by a prior app session so the
    /// UI isn't blank while we wait for pianobar's next event.
    public func restoreSnapshot(
        stations: [Station],
        currentStation: Station?,
        currentSong: SongInfo?,
        progressSeconds: Int,
        isPlaying: Bool
    ) {
        self.stations = stations
        self.currentStation = currentStation
        self.currentSong = currentSong
        self.progressSeconds = progressSeconds
        self.isPlaying = isPlaying
        // Intentionally does NOT touch `hasLiveSong`: this is cached data from a
        // previous session, not evidence that pianobar is currently playing.
    }

    public func setErrorBanner(_ message: String) {
        errorBanner = message
        errorBannerSetAt = Date()
    }

    public func dismissErrorBanner() {
        errorBanner = nil
        errorBannerSetAt = nil
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let setAt = self.errorBannerSetAt,
                   Date().timeIntervalSince(setAt) >= Self.errorBannerTimeout {
                    self.errorBanner = nil
                    self.errorBannerSetAt = nil
                }
                guard self.isPlaying,
                      let dur = self.currentSong?.durationSeconds,
                      self.progressSeconds < dur
                else { return }
                self.progressSeconds += 1
            }
        }
    }
}

/// A played song plus a stable identity. History is inserted at index 0, so
/// list rows keyed by array offset would change identity on every new song and
/// animate/recycle incorrectly.
public struct HistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var song: SongInfo

    public init(id: UUID = UUID(), song: SongInfo) {
        self.id = id
        self.song = song
    }
}
