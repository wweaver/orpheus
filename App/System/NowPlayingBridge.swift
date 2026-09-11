import Foundation
import AppKit
import MediaPlayer
import Combine
import PianobarCore

@MainActor
final class NowPlayingBridge {
    private let state: PlaybackState
    private let ctrl: PianobarCtrl
    private var subs = Set<AnyCancellable>()
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// Cover art keyed by URL, so the 1 Hz publish path never re-downloads.
    /// Bounded because a session only ever sees a few dozen songs; trimmed in
    /// `fetchArtwork` if it grows past `maxCachedArtwork`.
    private var artworkCache: [URL: MPMediaItemArtwork] = [:]
    /// URL of an in-flight fetch, to avoid stacking duplicate requests.
    private var artworkFetchURL: URL?
    private static let maxCachedArtwork = 64

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        registerCommands()
        observeState()
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()

        commandTargets.append((c.playCommand, c.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.setPlayback(true)
            }
            return .success
        }))
        commandTargets.append((c.pauseCommand, c.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.setPlayback(false)
            }
            return .success
        }))
        commandTargets.append((c.togglePlayPauseCommand, c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.setPlayback(!self.state.isPlaying)
            }
            return .success
        }))
        commandTargets.append((c.nextTrackCommand, c.nextTrackCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.next() }
            return .success
        }))
        commandTargets.append((c.likeCommand, c.likeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.love() }
            return .success
        }))
        commandTargets.append((c.dislikeCommand, c.dislikeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.ban() }
            return .success
        }))

        // Disable what we can't support.
        c.previousTrackCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    func invalidate() {
        for (command, target) in commandTargets {
            command.removeTarget(target)
        }
        commandTargets.removeAll()
        subs.removeAll()
        artworkCache.removeAll()
        artworkFetchURL = nil
        // Clear the Now Playing entry too, otherwise a ghost song lingers in
        // Control Center after sign-out or teardown.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func setPlayback(_ shouldPlay: Bool) async {
        // Delegate to the shared, race-free transport helper so the media-key
        // path stays in sync with the in-app transport controls.
        await state.setPlayback(shouldPlay, via: ctrl)
    }

    private func observeState() {
        state.$currentSong
            .combineLatest(state.$progressSeconds, state.$isPlaying)
            .sink { [weak self] song, elapsed, playing in
                self?.publish(song: song, elapsed: elapsed, playing: playing)
            }
            .store(in: &subs)
    }

    private func publish(song: SongInfo?, elapsed: Int, playing: Bool) {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: Double(song.durationSeconds),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        // This runs once per second, because `publish` is driven by the
        // progress ticker as well as by song changes. Serve the artwork from
        // cache and only hit the network when the URL actually changes —
        // previously every tick started a fresh synchronous download of the
        // same cover art, and then the unconditional assignment below raced
        // those in-flight fetches and wiped the artwork they had just set.
        if let url = song.coverArtURL, let artwork = artworkCache[url] {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let url = song.coverArtURL, artworkCache[url] == nil, artworkFetchURL != url {
            fetchArtwork(for: url)
        }
    }

    /// Fetch cover art once per URL and re-publish with it attached.
    private func fetchArtwork(for url: URL) {
        artworkFetchURL = url
        Task { [weak self] in
            // URLSession rather than `Data(contentsOf:)`, which blocks a
            // cooperative-pool thread on network I/O with no timeout.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data)
            else {
                await MainActor.run { self?.artworkFetchURL = nil }
                return
            }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            await MainActor.run {
                guard let self else { return }
                self.artworkFetchURL = nil
                if self.artworkCache.count >= Self.maxCachedArtwork {
                    self.artworkCache.removeAll()
                }
                self.artworkCache[url] = artwork
                // Only attach if this is still the current song's art.
                guard self.state.currentSong?.coverArtURL == url,
                      var current = MPNowPlayingInfoCenter.default().nowPlayingInfo
                else { return }
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }
}
