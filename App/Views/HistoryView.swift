import SwiftUI
import PianobarCore

struct HistoryView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                list
            }
        }
        .background(.background)
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                Text("History").bold()
                Spacer()
                if let most = state.history.first {
                    Text("\(most.title) · \(most.artist)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.history.enumerated()), id: \.offset) { _, song in
                    row(song).padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
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
