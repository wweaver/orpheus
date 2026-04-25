import SwiftUI
import PianobarCore

/// Minimal sidebar — plain List, no .searchable, no per-row gesture.
/// Single-click selects + switches.
struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var selection: String?

    var body: some View {
        List(state.stations, selection: $selection) { station in
            Text(station.name).tag(station.id)
        }
        .onChange(of: selection) { newID in
            guard let id = newID,
                  let idx = state.stations.firstIndex(where: { $0.id == id })
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
}
