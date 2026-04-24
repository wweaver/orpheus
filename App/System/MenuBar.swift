import SwiftUI
import AppKit
import PianobarCore

// MARK: - Label (title in the system menu bar)

/// Title rendered next to the system menu bar icon. Reflects the current song
/// (formatted per Prefs) or "♪" when nothing is playing.
struct MenuBarLabel: View {
    @EnvironmentObject var bootstrap: AppBootstrap

    var body: some View {
        // Nested ObservableObject pattern: when bootstrap.playbackState changes,
        // the outer view re-renders; the inner view observes the PlaybackState
        // directly so published-property changes on it trigger re-renders too.
        if let state = bootstrap.playbackState {
            MenuBarTitle(state: state)
        } else {
            Text("♪")
        }
    }
}

private struct MenuBarTitle: View {
    @ObservedObject var state: PlaybackState
    @AppStorage(Prefs.Keys.menuBarShowArtist) private var showArtist: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowTitle)  private var showTitle: Bool = true
    @AppStorage(Prefs.Keys.menuBarMaxWidth)   private var maxWidth: Int = 40

    var body: some View {
        Text(title)
    }

    private var title: String {
        guard let song = state.currentSong else { return "♪" }
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

// MARK: - Dropdown content

/// Dropdown content for the menu bar item: transport controls, stations
/// submenu, show-app / quit.
struct MenuBarContent: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
            MenuBarCommands(state: state, ctrl: ctrl, openWindow: openWindow)
        } else {
            Button("Starting…") {}.disabled(true)
            Divider()
            Button("Show PianobarGUI") { MenuBarActions.showMainWindow(openWindow: openWindow) }
            Button("Quit PianobarGUI") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

private struct MenuBarCommands: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    let openWindow: OpenWindowAction

    var body: some View {
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

        Button("Show PianobarGUI") { MenuBarActions.showMainWindow(openWindow: openWindow) }
        Button("Preferences…") { MenuBarActions.openSettings() }
            .keyboardShortcut(",")
        Button("Quit PianobarGUI") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

// MARK: - Actions

enum MenuBarActions {
    static func showMainWindow(openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { isMainAppWindow($0) }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private static func isMainAppWindow(_ window: NSWindow) -> Bool {
        let cls = String(describing: type(of: window))
        if cls.contains("Settings") { return false }
        return window.canBecomeKey && window.contentViewController != nil
    }
}
