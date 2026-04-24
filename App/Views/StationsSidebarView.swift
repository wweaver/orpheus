import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var filter: String = ""
    @State private var selection: String?
    @State private var programmaticSelection: Bool = false
    @AppStorage(Prefs.Keys.stationClickCount) private var clickCount: Int = 2

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
                .padding(.horizontal, 10)
                .padding(.top, 32)
                .padding(.bottom, 6)

            List(selection: $selection) {
                ForEach(filtered) { station in
                    row(for: station)
                        .tag(station.id)
                        .simultaneousGesture(
                            TapGesture(count: 2).onEnded {
                                if clickCount == 2 { switchTo(station) }
                            }
                        )
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 200)
        .onChange(of: selection) { newID in
            // Ignore selections that came from state (programmatic) or no change.
            guard !programmaticSelection else {
                programmaticSelection = false
                return
            }
            guard clickCount == 1,
                  let id = newID,
                  id != state.currentStation?.id,
                  let station = state.stations.first(where: { $0.id == id })
            else { return }
            switchTo(station)
        }
        .onChange(of: state.currentStation?.id) { newID in
            // Reflect playback state into visual selection without triggering
            // the user-click branch above.
            programmaticSelection = true
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
