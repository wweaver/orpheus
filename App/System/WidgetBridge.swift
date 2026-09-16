import Foundation
import AppKit
import Combine
import WidgetKit
import PianobarCore

/// Keeps the desktop widget fed, and executes the commands it sends back.
///
/// The widget runs in a sandboxed extension process and cannot talk to
/// pianobar, which is a child of *this* process. So the two halves are:
///
/// - **Out:** a flat `WidgetSnapshot` (plus the cover art as bytes) written into
///   a directory the extension has a read-only sandbox exception for, followed
///   by a WidgetKit reload. See `OrpheusShared.sharedDirectory` for why it isn't
///   an App Group container.
/// - **In:** a distributed notification per button press, translated here into
///   the same `PianobarCtrl` calls the in-app transport uses.
///
/// Modelled on NowPlayingBridge, which does the equivalent job for Control
/// Center's media controls.
@MainActor
final class WidgetBridge {
    private let state: PlaybackState
    private let ctrl: PianobarCtrl
    private var subs = Set<AnyCancellable>()
    private var commandObserver: NSObjectProtocol?

    /// Cover art already written out, keyed by source URL, so a song repeating
    /// (or the snapshot being republished on a pause) doesn't re-download an
    /// image we still have on disk.
    private var artworkFileByURL: [URL: String] = [:]
    private var artworkFetchURL: URL?

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        observeCommands()
        observeState()
    }

    func invalidate() {
        if let commandObserver {
            DistributedNotificationCenter.default().removeObserver(commandObserver)
        }
        commandObserver = nil
        subs.removeAll()
        artworkFileByURL.removeAll()
        artworkFetchURL = nil
    }

    /// Empty the widget because there's no longer a song behind it — Orpheus is
    /// quitting, or has signed out.
    ///
    /// Blanking rather than just clearing `appRunning`: the widget would
    /// otherwise keep showing the last track on the desktop indefinitely,
    /// implying playback that has stopped. Nothing resumes it either — pianobar
    /// goes down with the app, and the next launch starts its station from
    /// whatever Pandora serves next, not from that song.
    ///
    /// Called from the termination hook and sign-out rather than from
    /// `invalidate`, which also runs when the playback stack is being rebuilt
    /// under a still-running app.
    static func clearSnapshot() {
        WidgetStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Outbound state

    private func observeState() {
        // Deliberately not driven by `progressSeconds`: that ticks once a
        // second and would exhaust WidgetKit's reload budget within minutes.
        // The snapshot records when it was taken and the widget extrapolates
        // playback position from there — see `WidgetSnapshot.elapsed(at:)`.
        state.$currentSong
            .combineLatest(state.$currentStation, state.$isPlaying)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.publish() }
            .store(in: &subs)
    }

    private func publish() {
        let song = state.currentSong
        let url = song?.coverArtURL
        let snapshot = WidgetSnapshot(
            title: song?.title ?? "",
            artist: song?.artist ?? "",
            album: song?.album ?? "",
            stationName: state.currentStation?.name ?? song?.stationName ?? "",
            isPlaying: state.isPlaying,
            progressSeconds: state.progressSeconds,
            durationSeconds: song?.durationSeconds ?? 0,
            rating: (song?.rating ?? .unrated).rawValue,
            artworkFile: url.flatMap { artworkFileByURL[$0] },
            savedAt: Date(),
            appRunning: true
        )
        WidgetStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()

        if let url, artworkFileByURL[url] == nil, artworkFetchURL != url {
            fetchArtwork(for: url)
        }
    }

    /// Download the cover once per URL, park it next to the snapshot, and
    /// republish so the widget picks it up.
    private func fetchArtwork(for url: URL) {
        artworkFetchURL = url
        Task { [weak self] in
            // URLSession rather than `Data(contentsOf:)`, which blocks a
            // cooperative-pool thread on network I/O with no timeout.
            let data = try? await URLSession.shared.data(from: url).0
            await MainActor.run {
                guard let self else { return }
                self.artworkFetchURL = nil
                guard let data,
                      let file = WidgetStore.writeArtwork(data, token: url.absoluteString)
                else { return }
                // Only one cover survives pruning on disk, so drop the other
                // entries rather than leaving them pointing at deleted files.
                self.artworkFileByURL = [url: file]
                // The song may have moved on while the download was in flight.
                guard self.state.currentSong?.coverArtURL == url else { return }
                self.publish()
            }
        }
    }

    // MARK: - Inbound commands

    private func observeCommands() {
        commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: OrpheusShared.commandNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let raw = note.object as? String,
                  let command = OrpheusCommand(rawValue: raw)
            else { return }
            MainActor.assumeIsolated { self?.perform(command) }
        }
    }

    private func perform(_ command: OrpheusCommand) {
        switch command {
        case .togglePlay:
            // Through the shared transport helper, which sends an explicit
            // P/S against a computed target instead of pianobar's blind `p`
            // toggle. See PlaybackState.setPlayback(_:via:).
            Task { [state, ctrl] in await state.setPlayback(!state.isPlaying, via: ctrl) }
        case .next:
            Task { [ctrl] in try? await ctrl.next() }
        case .love:
            Task { [ctrl] in try? await ctrl.love() }
        case .ban:
            Task { [ctrl] in try? await ctrl.ban() }
        case .tired:
            Task { [ctrl] in try? await ctrl.tired() }
        }
    }
}
