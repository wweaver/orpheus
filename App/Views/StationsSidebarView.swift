import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var filter: String = ""

    var body: some View {
        StationsList(
            stations: state.stations,
            currentStationId: state.currentStation?.id,
            isFirstSelection: state.currentSong == nil,
            filter: filter,
            ctrl: ctrl
        )
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .frame(minWidth: 200)
    }
}

/// Encapsulates the station list and selection gesture. Takes plain-value
/// inputs so changes to unrelated PlaybackState fields (e.g. progressSeconds
/// ticking every second) don't rebuild the List and interrupt gestures.
private struct StationsList: View {
    let stations: [Station]
    let currentStationId: String?
    let isFirstSelection: Bool
    let filter: String
    let ctrl: PianobarCtrl

    @AppStorage(Prefs.Keys.stationClickCount) private var clickCount: Int = 2
    @State private var selection: String?
    @State private var programmaticSelection: Bool = false

    private var filtered: [Station] {
        guard !filter.isEmpty else { return stations }
        return stations.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { station in
                row(for: station)
                    .tag(station.id)
                    // Per-row simultaneousGesture so List's native single-click
                    // selection still fires. The subview extraction (above)
                    // keeps the row stable across progress-ticker re-renders,
                    // so the gesture recognizer doesn't get torn down mid-click.
                    .simultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            if clickCount == 2 { switchTo(station) }
                        }
                    )
            }
        }
        .listStyle(.sidebar)
        .frame(maxHeight: .infinity)
        .onChange(of: selection) { newID in
            guard !programmaticSelection else {
                programmaticSelection = false
                return
            }
            guard clickCount == 1,
                  let id = newID,
                  id != currentStationId,
                  let station = stations.first(where: { $0.id == id })
            else { return }
            switchTo(station)
        }
        .onChange(of: currentStationId) { newID in
            programmaticSelection = true
            selection = newID
        }
        .onAppear {
            programmaticSelection = true
            selection = currentStationId
        }
    }

    @ViewBuilder
    private func row(for station: Station) -> some View {
        HStack {
            if currentStationId == station.id {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
            }
            Text(station.name)
        }
    }

    private func switchTo(_ station: Station) {
        guard let idx = stations.firstIndex(where: { $0.id == station.id })
        else { return }
        let firstSelection = isFirstSelection
        Task {
            if firstSelection {
                try? await ctrl.selectStationAtPrompt(index: idx)
            } else {
                try? await ctrl.switchStation(index: idx)
            }
        }
    }
}
