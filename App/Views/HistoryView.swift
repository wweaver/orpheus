import SwiftUI
import PianobarCore

struct HistoryView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("History").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider()

            if state.history.isEmpty {
                Spacer()
                Text("Songs you've played will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(20)
                Spacer()
            } else {
                List {
                    ForEach(Array(state.history.enumerated()), id: \.offset) { _, song in
                        row(song)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 220)
        .background(.background)
    }

    private func row(_ song: SongInfo) -> some View {
        HStack(spacing: 8) {
            icon(for: song.rating)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text("\(song.artist) · \(song.album)")
                    .foregroundStyle(.secondary).font(.caption).lineLimit(1)
            }
        }
        .contextMenu {
            if let url = song.detailURL {
                Button("Open in Pandora") { NSWorkspace.shared.open(url) }
            }
        }
    }

    @ViewBuilder private func icon(for rating: Rating) -> some View {
        switch rating {
        case .loved:   Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green)
        case .banned:  Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.red)
        case .unrated: Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }
}
