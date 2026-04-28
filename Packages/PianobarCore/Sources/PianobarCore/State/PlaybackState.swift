import Foundation
import Combine

@MainActor
public final class PlaybackState: ObservableObject {
    @Published public private(set) var currentSong: SongInfo?
    @Published public private(set) var currentStation: Station?
    @Published public private(set) var stations: [Station] = []
    @Published public private(set) var history: [SongInfo] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public var volume: Int = 50
    @Published public private(set) var progressSeconds: Int = 0
    @Published public private(set) var errorBanner: String?
    @Published public private(set) var authFailure: String?

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
                history.insert(prev, at: 0)
                if history.count > 50 { history.removeLast(history.count - 50) }
            }
            currentSong = song
            currentStation = stations.first { $0.name == song.stationName }
                              ?? currentStation
            progressSeconds = 0
            isPlaying = true
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
        case .stationFetchPlaylist: break
        case .stationsChanged(let s):
            // Pianobar occasionally emits an empty stations list during
            // transient errors (network blip, expired session being refreshed,
            // etc.). Keep the last-known list rather than wiping the UI.
            guard !s.isEmpty else { break }
            stations = s
            currentStation = stations.first { $0.name == currentSong?.stationName }
        case .stationCreated(let s):
            if !stations.contains(where: { $0.id == s.id }) { stations.append(s) }
        case .stationDeleted(let id):
            stations.removeAll { $0.id == id }
        case .stationRenamed(let id, let newName):
            if let i = stations.firstIndex(where: { $0.id == id }) {
                stations[i].name = newName
            }
        case .userLogin(let ok, let msg):
            authFailure = ok ? nil : (msg.isEmpty ? "Sign-in failed" : msg)
        case .pandoraError(_, let msg), .networkError(let msg):
            errorBanner = msg
            errorBannerSetAt = Date()
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
