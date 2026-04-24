import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var filter: String = ""

    var filtered: [Station] {
        guard !filter.isEmpty else { return state.stations }
        return state.stations.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: Binding(
                get: { state.currentStation?.id },
                set: { newID in
                    if let id = newID,
                       let idx = state.stations.firstIndex(where: { $0.id == id }) {
                        let isFirstSelection = state.currentSong == nil
                        Task {
                            if isFirstSelection {
                                try? await ctrl.selectStationAtPrompt(index: idx)
                            } else {
                                try? await ctrl.switchStation(index: idx)
                            }
                        }
                    }
                })) {
                ForEach(filtered) { station in
                    HStack {
                        if state.currentStation?.id == station.id {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                        }
                        Text(station.name)
                    }.tag(station.id)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 200)
    }
}
