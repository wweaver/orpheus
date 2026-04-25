import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var selection: String?

    var body: some View {
        List(selection: $selection) {
            ForEach(state.stations) { station in
                row(for: station)
                    .tag(station.id)
                    .onTapGesture(count: 2) { switchTo(station) }
            }
        }
    }

    private func row(for station: Station) -> some View {
        let isCurrent = state.currentStation?.id == station.id
        return HStack(spacing: 6) {
            Image(systemName: isCurrent ? "speaker.wave.2.fill" : "circle.dotted")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary.opacity(0.4))
                .font(.caption)
                .frame(width: 14)
            Text(station.name)
        }
    }

    private func switchTo(_ station: Station) {
        guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
        else { return }
        let isFirst = state.currentSong == nil
        Task {
            if isFirst {
                try? await ctrl.selectStationAtPrompt(index: idx)
            } else {
                try? await ctrl.switchStation(index: idx)
            }
        }
    }
}
