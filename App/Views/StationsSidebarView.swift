import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.stations) { station in
                    row(for: station)
                        .tag(station.id)
                        .onTapGesture(count: 2) { switchTo(station) }
                        .contextMenu {
                            Button("Start station") { switchTo(station) }
                            Divider()
                            Button(role: .destructive) {
                                delete(station)
                            } label: {
                                Text("Delete station")
                            }
                        }
                }
            }

            Divider()

            HStack(spacing: 14) {
                Button(action: addFromCurrentSong) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New station from current song")
                .disabled(state.currentSong == nil)

                Button {
                    if let id = selection,
                       let station = state.stations.first(where: { $0.id == id }) {
                        delete(station)
                    }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .help("Delete selected station")
                .disabled(selection == nil)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    /// Always-2-children row keeps the layout buffer constant. The speaker
    /// icon is always present; only its opacity changes for the current
    /// station — avoids the conditional-children bug on macOS 26.4.1.
    private func row(for station: Station) -> some View {
        let isCurrent = state.currentStation?.id == station.id
        return HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(Color.accentColor)
                .font(.caption)
                .frame(width: 14)
                .opacity(isCurrent ? 1 : 0)
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

    private func addFromCurrentSong() {
        Task { try? await ctrl.createStationFromSong() }
    }

    /// Pianobar's `d` deletes the *currently playing* station, so to remove
    /// any other station we have to switch to it first, give pianobar a
    /// moment to settle, then send the delete.
    private func delete(_ station: Station) {
        Task {
            if state.currentStation?.id != station.id {
                guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
                else { return }
                try? await ctrl.switchStation(index: idx)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            try? await ctrl.deleteStation()
        }
    }
}
