import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var systemVolume: Double = Double(SystemVolume.read() ?? 50)

    var body: some View {
        VStack(spacing: 16) {
            albumArt
                .frame(width: 220, height: 220)

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

            HStack {
                Text("🔈").foregroundStyle(.secondary)
                Slider(value: $systemVolume, in: 0...100) { editing in
                    if !editing { SystemVolume.set(Int(systemVolume)) }
                }
                Text("🔊").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .onAppear {
                if let v = SystemVolume.read() { systemVolume = Double(v) }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var albumArt: some View {
        if let url = state.currentSong?.coverArtURL {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                placeholderArt
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.2))
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
            )
    }
}
