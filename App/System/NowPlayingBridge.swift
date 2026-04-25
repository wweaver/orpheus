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
    }

    private func setPlayback(_ shouldPlay: Bool) async {
        guard state.isPlaying != shouldPlay else { return }
        try? await ctrl.togglePlay()
        state.setPlaying(shouldPlay)
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
        let info: [String: Any] = [
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
