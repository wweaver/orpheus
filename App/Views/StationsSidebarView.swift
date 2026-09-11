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
    /// How long to wait for pianobar to confirm a station switch before
    /// abandoning a destructive follow-up command.
    private static let stationSwitchTimeout: TimeInterval = 10

    @State private var lastClickedID: String?
    @State private var lastClickedAt: Date = .distantPast
    @State private var filter: String = ""

    private var filteredStations: [Station] {
        let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return state.stations }
        return state.stations.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// A new account has no stations yet; the bare list plus an unexplained
    /// "+" gave no hint about what to do.
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Stations", systemImage: "antenna.radiowaves.left.and.right")
        } description: {
            Text("Create your first station from a song or artist you like.")
        } actions: {
            Button("Create Station…") { addSheetPresented = true }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(filteredStations) { station in
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
            // Deliberately no `.space` binding: space is the universal
            // play/pause key, and binding it here made pressing it tear down
            // the current stream and start a different station. It also broke
            // List's type-select.
            .searchable(text: $filter, placement: .sidebar, prompt: "Filter stations")
            .overlay {
                if state.stations.isEmpty {
                    emptyState
                } else if filteredStations.isEmpty {
                    ContentUnavailableView.search(text: filter)
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
                .accessibilityLabel("New station")

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
                .accessibilityLabel("Delete selected station")
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
            RenameStationSheet(originalName: station.name,
                               note: renameNote(for: station)) { newName in
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
            Text(deleteWarning(for: station))
        }
    }

    /// pianobar can only delete the station it's currently playing, so removing
    /// any other one means switching to it first — which ends the song you're
    /// listening to. Say so up front rather than letting it happen unannounced;
    /// the app switches back afterwards, but on a new song.
    private func deleteWarning(for station: Station) -> String {
        let base = "Are you sure you want to delete \"\(station.name)\"? This can't be undone."
        guard let current = state.currentStation, current.id != station.id else { return base }
        return base + "\n\nThis will interrupt playback: pianobar can only delete the station "
            + "it's playing, so Orpheus has to switch to \"\(station.name)\" first. "
            + "You'll be returned to \"\(current.name)\" afterwards, on a new song."
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
        // The speaker glyph is decorative and hidden from VoiceOver, so fold
        // "now playing" into the row's own label — otherwise there's no way to
        // tell which station is playing.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isCurrent ? "\(station.name), now playing" : station.name)
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

        // Before pianobar's first songstart it's still sitting at the
        // "Select station:" prompt, which wants bare digits rather than the
        // runtime `s<N>` command. `currentSong` can't answer that question —
        // it's pre-populated from the previous session's snapshot — so ask
        // whether a real songstart has arrived this session.
        let isFirst = !state.hasLiveSong
        Task {
            if isFirst {
                try? await ctrl.selectStationAtPrompt(index: idx)
            } else {
                try? await ctrl.switchStation(index: idx)
            }
        }
    }

    /// Pianobar's `r` renames the *currently playing* station, so for any
    /// other station we have to switch to it first — and then put the user
    /// back on whatever they were actually listening to.
    private func rename(_ station: Station, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != station.name else { return }
        Task {
            let resumeTo = stationToResumeAfterActing(on: station)
            guard await makeCurrent(station, action: "rename") else { return }
            try? await ctrl.renameStation(trimmed)
            // The station we're returning to may itself have been renamed, so
            // resolve by the new name when that's the one we left.
            await resume(resumeTo == station.name ? trimmed : resumeTo)
        }
    }

    /// Pianobar's `d` deletes the *currently playing* station, so to remove
    /// any other station we have to switch to it first.
    ///
    /// Deleting whatever is playing leaves pianobar at a `Select station:`
    /// prompt waiting for a replacement, and that prompt takes a **bare**
    /// index — the `s` of the usual `s<N>` command is literal text there. We
    /// previously sent `s<N>`, which the prompt rejected and then re-asked,
    /// leaving pianobar parked forever and silently eating every later
    /// command. Answering is mandatory, not optional: there is no path where
    /// we can skip it.
    private func delete(_ station: Station) {
        Task {
            let resumeTo = stationToResumeAfterActing(on: station)
            guard await makeCurrent(station, action: "delete") else { return }
            try? await ctrl.deleteStation()

            // Indices at the prompt are against pianobar's list *after* the
            // delete. Our copy still has the station (its event payload can't
            // be trusted — see EventParser), so drop it to get the same view.
            // Deliberately index-based rather than filtering by name: the
            // prompt's filter is a substring match, and names like
            // "Christmas Radio" / "My Christmas Radio" would match two
            // stations and leave the prompt unanswered again.
            let remaining = state.stations.filter { $0.id != station.id }
            let target = remaining.firstIndex { $0.name == resumeTo } ?? remaining.indices.first
            if let target {
                try? await ctrl.selectStationAtPrompt(index: target)
            }
            state.removeStation(id: station.id)
        }
    }

    private func renameNote(for station: Station) -> String {
        guard let current = state.currentStation, current.id != station.id else {
            return "Renaming applies to the station you're currently playing."
        }
        return "pianobar can only rename the station it's playing, so this will switch to "
            + "\"\(station.name)\" and interrupt playback, then return you to "
            + "\"\(current.name)\" on a new song."
    }

    /// Name of the station to return to once we're done acting on `station`,
    /// or nil if there's nothing to go back to.
    ///
    /// Renaming and deleting both require making the target station current,
    /// which starts playing it. Left alone, asking to delete a station you
    /// weren't listening to would interrupt your music and start the very
    /// station you're removing.
    private func stationToResumeAfterActing(on station: Station) -> String? {
        guard let current = state.currentStation, current.id != station.id else { return nil }
        return current.name
    }

    /// Go back to the station identified by `name` once the mutation has been
    /// applied.
    private func resume(_ name: String?) async {
        guard let name else { return }
        // Wait for pianobar's refreshed station list before resolving an
        // index: a delete shifts every index after it, so acting on the stale
        // list would switch to the wrong station.
        let deadline = Date().addingTimeInterval(Self.stationSwitchTimeout)
        while Date() < deadline {
            if let idx = state.stations.firstIndex(where: { $0.name == name }),
               state.currentStation?.name != name {
                try? await ctrl.switchStation(index: idx)
                return
            }
            // Already back where we started — nothing to do.
            if state.currentStation?.name == name { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Switch to `station` and wait for pianobar to confirm it actually
    /// happened. Returns false (and shows a banner) if it didn't.
    ///
    /// This used to be a flat `Task.sleep(600ms)`. A station switch needs a
    /// Pandora round trip, and on a slow connection it takes far longer than
    /// that — so the following `d` landed while pianobar was still on the
    /// *previous* station and deleted the wrong one, permanently and with no
    /// undo. Wait for the state to actually reflect the switch instead.
    private func makeCurrent(_ station: Station, action: String) async -> Bool {
        if state.currentStation?.id == station.id { return true }
        guard let idx = state.stations.firstIndex(where: { $0.id == station.id })
        else { return false }
        do {
            try await ctrl.switchStation(index: idx)
        } catch {
            state.setErrorBanner("Couldn't switch to \"\(station.name)\", so the \(action) was cancelled.")
            return false
        }

        let deadline = Date().addingTimeInterval(Self.stationSwitchTimeout)
        while Date() < deadline {
            if state.currentStation?.id == station.id { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        state.setErrorBanner(
            "\"\(station.name)\" didn't start in time, so the \(action) was cancelled. Try again.")
        return false
    }
}

private struct AddStationSheet: View {
    @State private var query: String = ""
    @FocusState private var focused: Bool
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
                .focused($focused)
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
        .onAppear { focused = true }
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

private struct RenameStationSheet: View {
    let originalName: String
    /// Explains the playback consequence when this isn't the playing station.
    let note: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String
    @FocusState private var focused: Bool

    init(originalName: String,
         note: String,
         onSubmit: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.originalName = originalName
        self.note = note
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _name = State(initialValue: originalName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Station").font(.headline)
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Station name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
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
        .onAppear { focused = true }
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
