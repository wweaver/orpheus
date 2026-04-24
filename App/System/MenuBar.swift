import SwiftUI
import AppKit
import PianobarCore

/// Title rendered next to the system menu bar icon. Reflects the current song
/// (formatted per Prefs) or "♪" when nothing is playing.
struct MenuBarLabel: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @AppStorage(Prefs.Keys.menuBarShowArtist) private var showArtist: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowTitle)  private var showTitle: Bool = true
    @AppStorage(Prefs.Keys.menuBarMaxWidth)   private var maxWidth: Int = 40

    var body: some View {
        Text(title)
    }

    private var title: String {
        guard let song = bootstrap.playbackState?.currentSong else { return "♪" }
        var parts: [String] = []
        if showArtist { parts.append(song.artist) }
        if showTitle  { parts.append(song.title) }
        let raw = parts.joined(separator: " — ")
        let width = max(10, maxWidth)
        let truncated = raw.count > width
            ? String(raw.prefix(width - 1)) + "…"
            : raw
        return "♪ " + truncated
    }
}

/// Dropdown content for the menu bar item: transport controls, stations
/// submenu, show-app / quit.
struct MenuBarContent: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
            content(state: state, ctrl: ctrl)
        } else {
            Button("Starting…") {}.disabled(true)
            Divider()
            Button("Show PianobarGUI") { showMainWindow() }
            Button("Quit PianobarGUI") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func content(state: PlaybackState, ctrl: PianobarCtrl) -> some View {
        Button(state.isPlaying ? "Pause" : "Play") {
            Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
        }
        .keyboardShortcut("p")

        Button("Next") {
            Task { try? await ctrl.next() }
        }

        Button("Thumbs Up") {
            Task { try? await ctrl.love() }
        }

        Button("Thumbs Down") {
            Task { try? await ctrl.ban() }
        }

        Divider()

        Menu("Stations") {
            ForEach(Array(state.stations.enumerated()), id: \.element.id) { idx, station in
                Button {
                    let isFirst = state.currentSong == nil
                    Task {
                        if isFirst {
                            try? await ctrl.selectStationAtPrompt(index: idx)
                        } else {
                            try? await ctrl.switchStation(index: idx)
                        }
                    }
                } label: {
                    if station.id == state.currentStation?.id {
                        Label(station.name, systemImage: "checkmark")
                    } else {
                        Text(station.name)
                    }
                }
            }
        }

        Divider()

        Button("Show PianobarGUI") { showMainWindow() }
        Button("Preferences…") { openSettings() }
            .keyboardShortcut(",")
        Button("Quit PianobarGUI") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { isMainAppWindow($0) }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func isMainAppWindow(_ window: NSWindow) -> Bool {
        // Exclude SwiftUI's Settings window and any non-restorable helper windows.
        let cls = String(describing: type(of: window))
        if cls.contains("Settings") { return false }
        return window.canBecomeKey && window.contentViewController != nil
    }
}
