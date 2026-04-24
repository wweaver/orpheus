import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 20) {
            albumArt
                .frame(width: 240, height: 240)
            if let song = state.currentSong {
                VStack(spacing: 4) {
                    Text(song.title).font(.title3).bold()
                    Text(song.artist).font(.body).foregroundStyle(.secondary)
                    Text(song.album).font(.callout).foregroundStyle(.tertiary)
                }
            } else {
                Text("Not playing").foregroundStyle(.secondary)
            }

            controls

            progress

            volume
        }
        .padding(24)
        .frame(minWidth: 380)
    }

    @ViewBuilder private var albumArt: some View {
        if let url = state.currentSong?.coverArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: placeholderArt
                }
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
            .overlay(Image(systemName: "music.note").font(.system(size: 64))
                .foregroundStyle(.secondary))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            button(systemName: state.isPlaying ? "pause.fill" : "play.fill") {
                Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
            }
            button(systemName: "forward.fill") {
                Task { try? await ctrl.next() }
            }
            button(systemName: "hand.thumbsdown",
                   active: state.currentSong?.rating == .banned) {
                Task { try? await ctrl.ban() }
            }
            button(systemName: "hand.thumbsup",
                   active: state.currentSong?.rating == .loved) {
                Task { try? await ctrl.love() }
            }
            Menu {
                Button("Bookmark Song")   { Task { try? await ctrl.bookmarkSong() } }
                Button("Bookmark Artist") { Task { try? await ctrl.bookmarkArtist() } }
                Button("Tired of Track")  { Task { try? await ctrl.tired() } }
                if let url = state.currentSong?.detailURL {
                    Button("Open in Pandora") { NSWorkspace.shared.open(url) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func button(systemName: String, active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
    }

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(state.progressSeconds),
                         total: Double(max(state.currentSong?.durationSeconds ?? 1, 1)))
            HStack {
                Text(format(state.progressSeconds))
                Spacer()
                Text(format(state.currentSong?.durationSeconds ?? 0))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var volume: some View {
        HStack {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(state.volume) },
                set: { newVal in
                    state.volume = Int(newVal)
                    Task { try? await ctrl.setVolume(Int(newVal)) } }),
                   in: 0...100)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
