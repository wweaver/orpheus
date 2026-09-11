import SwiftUI
import PianobarCore

struct HistoryView: View {
    @ObservedObject var state: PlaybackState

    /// Bound by the parent so the drawer can collapse to just its header.
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()

            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("History").font(.subheadline).bold()
                    if !isExpanded, let latest = state.history.first?.song {
                        Text("· \(latest.title) — \(latest.artist)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityLabel(isExpanded ? "Collapse history" : "Expand history")

            if isExpanded {
                Divider()
                content
            }
        }
        .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    ForEach(state.history) { entry in
                        row(entry.song)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(height: 180)
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
