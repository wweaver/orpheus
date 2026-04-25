import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var selection: String?
    @State private var addSheetPresented: Bool = false
    @State private var stationToDelete: Station?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.stations) { station in
                    rowText(for: station)
                        .tag(station.id)
                        .onTapGesture(count: 2) { switchTo(station) }
                        .contextMenu {
                            Button("Start station") { switchTo(station) }
                            Divider()
                            Button(role: .destructive) {
                                stationToDelete = station
                            } label: {
                                Text("Delete station")
                            }
                        }
                }
            }

            Divider()

            HStack(spacing: 14) {
                Button {
                    addSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New station from search")

                Button {
                    if let id = selection,
                       let station = state.stations.first(where: { $0.id == id }) {
                        stationToDelete = station
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
        .sheet(isPresented: $addSheetPresented) {
            AddStationSheet { query in
                addSheetPresented = false
                Task { try? await ctrl.createStationFromSearch(query) }
            } onCancel: {
                addSheetPresented = false
            }
        }
        .confirmationDialog(
            "Delete station?",
            isPresented: Binding(
                get: { stationToDelete != nil },
                set: { if !$0 { stationToDelete = nil } }
            ),
            presenting: stationToDelete
        ) { station in
            Button("Delete \(station.name)", role: .destructive) {
                delete(station)
                stationToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                stationToDelete = nil
            }
        } message: { station in
            Text("Are you sure you want to delete \"\(station.name)\"? This can't be undone.")
        }
    }

    /// Pure-Text row. Style changes only — no nested HStack, no Image with
    /// conditional opacity. macOS 26.4.1's List selection binding has been
    /// flaky whenever rows contain anything beyond a single Text.
    private func rowText(for station: Station) -> some View {
        let isCurrent = state.currentStation?.id == station.id
        return Text(station.name)
            .fontWeight(isCurrent ? .semibold : .regular)
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
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

private struct AddStationSheet: View {
    @State private var query: String = ""
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Station").font(.headline)
            Text("Type a song or artist name. Pianobar will search Pandora and create a station from the first match.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Song or artist", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
