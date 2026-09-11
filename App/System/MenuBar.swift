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
        return "♪ " + middleTruncated(raw, to: width)
    }

    /// Truncate in the middle rather than at the end. With "artist — title"
    /// titles, a trailing ellipsis eats the song name first and leaves only
    /// the artist visible.
    private func middleTruncated(_ text: String, to width: Int) -> String {
        guard text.count > width else { return text }
        guard width > 1 else { return String(text.prefix(width)) }
        let keep = width - 1
        let lead = keep - keep / 2
        let trail = keep / 2
        return String(text.prefix(lead)) + "…" + String(text.suffix(trail))
    }
}

// MARK: - Dropdown content

/// Dropdown content for the menu bar item: transport controls, stations
/// submenu, show-app / quit.
struct MenuBarContent: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
            MenuBarCommands(
                state: state,
                ctrl: ctrl,
                openWindow: openWindow,
                openSettings: openSettings
            )
        } else {
            Button("Show Orpheus") { MenuBarActions.showMainWindow(openWindow: openWindow) }
            Button("Preferences…") { MenuBarActions.openSettings(openSettings: openSettings) }
            Divider()
            Button("Starting…") {}.disabled(true)
            Divider()
            Button("Quit Orpheus") { NSApp.terminate(nil) }
        }
    }
}

private struct MenuBarCommands: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    let openWindow: OpenWindowAction
    let openSettings: OpenSettingsAction

    var body: some View {
        Button("Show Orpheus") { MenuBarActions.showMainWindow(openWindow: openWindow) }
        Button("Preferences…") { MenuBarActions.openSettings(openSettings: openSettings) }

        Divider()

        // No ⌘P here: it collides with the system-standard Print, and the
        // Controls menu in the main window owns the real shortcuts now.
        Button(state.isPlaying ? "Pause" : "Play") {
            let target = !state.isPlaying
            Task { await state.setPlayback(target, via: ctrl) }
        }

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
                    // See StationsSidebarView.switchTo — `currentSong` is
                    // restored from the previous session's snapshot, so only
                    // `hasLiveSong` tells us pianobar is past its startup
                    // "Select station:" prompt.
                    let isFirst = !state.hasLiveSong
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

        Button("Quit Orpheus") { NSApp.terminate(nil) }
    }
}

// MARK: - Actions

enum MenuBarActions {
    /// Delegates to SwiftUI's WindowGroup `openWindow`. If the main window is
    /// already open, SwiftUI brings it forward; if it was closed it rebuilds
    /// a fresh instance from the scene. This is more reliable than poking at
    /// NSApp.windows, which gets confused when Settings is also open.
    static func showMainWindow(openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    static func openSettings(openSettings: OpenSettingsAction) {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
    }
}
