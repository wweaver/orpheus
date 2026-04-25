import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 16) {
            albumArt
                .frame(width: 220, height: 220)

            if let song = state.currentSong {
                Text(song.title).font(.title3).bold()
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(song.artist).foregroundStyle(.secondary)
                Text(song.album).font(.callout).foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else {
                Text("Not playing").foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                transportButton(systemName: state.isPlaying ? "pause.fill" : "play.fill") {
                    Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
                }
                transportButton(systemName: "forward.fill") {
                    Task { try? await ctrl.next() }
                }
                transportButton(systemName: "hand.thumbsdown") {
                    Task { try? await ctrl.ban() }
                }
                transportButton(systemName: "hand.thumbsup") {
                    Task { try? await ctrl.love() }
                }
            }

            progressBar
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private var progressBar: some View {
        if let song = state.currentSong, song.durationSeconds > 0 {
            VStack(spacing: 4) {
                ProgressView(
                    value: Double(min(state.progressSeconds, song.durationSeconds)),
                    total: Double(song.durationSeconds)
                )
                HStack {
                    Text(format(state.progressSeconds))
                    Spacer()
                    Text(format(song.durationSeconds))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
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
