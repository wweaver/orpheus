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

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        registerCommands()
        observeState()
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.play(); self?.state.setPlaying(true) }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.pause(); self?.state.setPlaying(false) }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { try? await self.ctrl.togglePlay(); self.state.setPlaying(!self.state.isPlaying) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.next() }
            return .success
        }
        c.likeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.love() }
            return .success
        }
        c.dislikeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.ban() }
            return .success
        }

        // Disable what we can't support.
        c.previousTrackCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
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
        if let url = song.coverArtURL {
            Task {
                if let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    await MainActor.run {
                        var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        current[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
