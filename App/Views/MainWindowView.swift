import SwiftUI
import PianobarCore

/// Diagnostic placeholder. If THIS launches without crashing, the bug
/// lives inside StationsSidebarView or NowPlayingView. If it still
/// crashes, the bug is in PianobarGUIApp / AppBootstrap / RootView /
/// PlaybackState / a framework interaction.
struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 16) {
            Text("Orpheus")
                .font(.largeTitle)
                .bold()

            Text("Diagnostic build — UI temporarily disabled")
                .foregroundStyle(.secondary)

            if let song = state.currentSong {
                VStack {
                    Text(song.title).bold()
                    Text(song.artist).foregroundStyle(.secondary)
                }
            } else {
                Text("Pianobar is running; select a station via menu bar.")
                    .foregroundStyle(.secondary)
            }

            Text("Stations loaded: \(state.stations.count)")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
