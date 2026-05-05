import AppKit
import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var selection: String?
    @State private var addSheetPresented: Bool = false
    @State private var stationToDelete: Station?
    @State private var stationToRename: Station?
    @State private var lastSwitchRequestID: String?
    @State private var lastSwitchRequestDate: Date = .distantPast
    @State private var lastClickedID: String?
    @State private var lastClickedAt: Date = .distantPast

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(state.stations) { station in
                    row(for: station)
                        .contextMenu {
                            Button("Start station") { switchTo(station) }
                            Button("Rename station…") { stationToRename = station }
                            Divider()
                            Button(role: .destructive) {
                                stationToDelete = station
                            } label: {
                                Text("Delete station")
                            }
                        }
                }
            }
            .onKeyPress(.return) {
                activateSelectedStation()
                return .handled
            }
            .onKeyPress(.space) {
                activateSelectedStation()
                return .handled
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
        .sheet(item: $stationToRename) { station in
            RenameStationSheet(originalName: station.name) { newName in
                stationToRename = nil
                rename(station, to: newName)
            } onCancel: {
                stationToRename = nil
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

    /// Stable view tree: the speaker icon is always rendered and toggled via
    /// opacity so the row's identity never changes. macOS 26.4.1's
    /// `List(selection:)` is flaky when rows insert/remove subviews on
    /// selection changes; opacity-only toggles avoid that.
    private func rowContent(for station: Station) -> some View {
        let isCurrent = state.currentStation?.id == station.id
        return HStack(spacing: 6) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .opacity(isCurrent ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(station.name)
                .fontWeight(isCurrent ? .semibold : .regular)
        }
    }

    private func row(for station: Station) -> some View {
        rowContent(for: station)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(station.id)
            .onTapGesture { handleTap(on: station) }
    }

    // A single `onTapGesture` avoids the double-click disambiguation delay
    // a `count: 2` recognizer introduces. Selection is set on every click so
    // the row highlights instantly; double-clicks are detected by comparing
    // the timestamp of the previous click on the same row.
    private func handleTap(on station: Station) {
        selection = station.id
        let now = Date()
        let isDoubleClick = lastClickedID == station.id
            && now.timeIntervalSince(lastClickedAt) < NSEvent.doubleClickInterval
        if isDoubleClick {
            lastClickedID = nil
            switchTo(station)
        } else {
            lastClickedID = station.id
            lastClickedAt = now
        }
    }

    private func activateSelectedStation() {
        guard let id = selection,
              let station = state.stations.first(where: { $0.id == id })
        else { return }
        switchTo(station)
    }

    private func switchTo(_ station: Station) {
        guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
        else { return }
        let now = Date()
        if lastSwitchRequestID == station.id,
           now.timeIntervalSince(lastSwitchRequestDate) < 0.5 {
            return
        }
        lastSwitchRequestID = station.id
        lastSwitchRequestDate = now

        let isFirst = state.currentSong == nil
        Task {
            if isFirst {
                try? await ctrl.selectStationAtPrompt(index: idx)
            } else {
                try? await ctrl.switchStation(index: idx)
            }
        }
    }

    /// Pianobar's `r` renames the *currently playing* station, so for any
    /// other station we switch first, settle briefly, then send the rename.
    /// Mirrors the pattern used by `delete(_:)` below.
    private func rename(_ station: Station, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != station.name else { return }
        Task {
            if state.currentStation?.id != station.id {
                guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
                else { return }
                try? await ctrl.switchStation(index: idx)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            try? await ctrl.renameStation(trimmed)
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

private struct RenameStationSheet: View {
    let originalName: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String

    init(originalName: String,
         onSubmit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Station").font(.headline)
            Text("Pianobar will briefly switch to this station to apply the rename.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Station name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var disabled: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == originalName
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != originalName else { return }
        onSubmit(trimmed)
    }
}
