import SwiftUI
import PianobarCore

/// The app's Controls menu.
///
/// Until now there were no `.commands` at all: the app shipped SwiftUI's stock
/// File/Edit/Window menus and had no in-window shortcut for play/pause, skip,
/// thumbs, tired or bookmark. This also makes the overflow-menu actions
/// discoverable, since a menu item advertises its own shortcut.
struct PlaybackCommands: Commands {
    @ObservedObject var bootstrap: AppBootstrap

    var body: some Commands {
        CommandMenu("Controls") {
            if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
                ControlsMenuItems(state: state, ctrl: ctrl)
            } else {
                Button("Play") {}.disabled(true)
            }
        }
    }
}

/// Split out so the menu observes `PlaybackState` directly and re-renders when
/// playback changes (e.g. Play <-> Pause).
private struct ControlsMenuItems: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    private var hasSong: Bool { state.currentSong != nil }

    var body: some View {
        Button(state.isPlaying ? "Pause" : "Play") {
            let target = !state.isPlaying
            Task { await state.setPlayback(target, via: ctrl) }
        }
        // All of these are ⌘⇧+letter on purpose. Menu key equivalents are
        // matched before the responder chain gets a look in, so the arrow-key
        // shortcuts the design spec suggested (⌘→, ⌘↑, ⌘↓) would have been
        // stolen from text fields — typing in the station filter or the rename
        // sheet and pressing ⌘→ to jump to end-of-line would skip the song.
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button("Next Song") { Task { try? await ctrl.next() } }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!hasSong)

        Divider()

        Button("Thumbs Up") { Task { try? await ctrl.love() } }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .disabled(!hasSong)

        Button("Thumbs Down") { Task { try? await ctrl.ban() } }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!hasSong)

        Button("Tired of Song") { Task { try? await ctrl.tired() } }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .disabled(!hasSong)

        Divider()

        Button("Bookmark Song") { Task { try? await ctrl.bookmarkSong() } }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(!hasSong)

        Button("Bookmark Artist") { Task { try? await ctrl.bookmarkArtist() } }
            .disabled(!hasSong)

        Divider()

        Button("Create Station from Song") {
            Task { try? await ctrl.createStationFromSong() }
        }
        .disabled(!hasSong)

        Button("Create Station from Artist") {
            Task { try? await ctrl.createStationFromArtist() }
        }
        .disabled(!hasSong)
    }
}
