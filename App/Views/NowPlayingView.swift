import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 12) {
                albumArt
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 240)

                if let song = state.currentSong {
                    Text(song.title).font(.headline).bold()
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(song.album).font(.caption).foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else {
                    Text("Not playing").foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
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
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .frame(width: 24, height: 24)
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
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
                    .font(.title)
                    .foregroundStyle(.secondary)
            )
    }
}
