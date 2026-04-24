import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var filter: String = ""
    @State private var selection: String?
    @AppStorage(Prefs.Keys.stationClickCount) private var clickCount: Int = 2

    var filtered: [Station] {
        guard !filter.isEmpty else { return state.stations }
        return state.stations.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { station in
                row(for: station)
                    .tag(station.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: max(1, clickCount)) {
                        switchTo(station)
                    }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .frame(minWidth: 200)
        .onChange(of: state.currentStation?.id) { newID in
            selection = newID
        }
    }

    @ViewBuilder
    private func row(for station: Station) -> some View {
        HStack {
            if state.currentStation?.id == station.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
            }
            Text(station.name)
        }
    }

    private func switchTo(_ station: Station) {
        guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
        else { return }
        let isFirstSelection = state.currentSong == nil
        Task {
            if isFirstSelection {
                try? await ctrl.selectStationAtPrompt(index: idx)
            } else {
                try? await ctrl.switchStation(index: idx)
            }
        }
    }
}
