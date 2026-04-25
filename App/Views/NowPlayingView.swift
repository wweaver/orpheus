import SwiftUI
import PianobarCore

/// Minimal player UI to dodge the SwiftUI layout-engine crash on
/// macOS 26.4.1. No AsyncImage, no Menu, no Slider, no helper-returning
/// closures — just Text + Buttons. We bring features back once the
/// baseline is stable.
struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 16) {
            if let song = state.currentSong {
                Text(song.title).font(.title3).bold()
                    .multilineTextAlignment(.center)
                Text(song.artist).foregroundStyle(.secondary)
                Text(song.album).font(.callout).foregroundStyle(.tertiary)
            } else {
                Text("Not playing").foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                Button(state.isPlaying ? "Pause" : "Play") {
                    Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
                }
                Button("Next") {
                    Task { try? await ctrl.next() }
                }
                Button("👎") {
                    Task { try? await ctrl.ban() }
                }
                Button("👍") {
                    Task { try? await ctrl.love() }
                }
            }
            .buttonStyle(.bordered)

            if let song = state.currentSong {
                Text("\(state.progressSeconds) / \(song.durationSeconds) sec")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
