# QA Checklist — Plan 2

Do these manual checks against a real Pandora account before declaring
Plan 2 done. Plan 1 checklist must already pass.

## Menu bar

- [ ] Menu bar icon appears at app launch.
- [ ] Title updates to "♪ {artist} — {title}" when a new song starts.
- [ ] Menu bar title truncates to the configured max width.
- [ ] Left-click activates and focuses the main window.
- [ ] Right-click shows Play/Pause, Next, Thumbs Up, Thumbs Down, Stations submenu, Show PianobarGUI, Quit.
- [ ] Clicking a station in the submenu switches playback to it.

## Now Playing / media keys

- [ ] Song appears in Control Center's Now Playing widget with title, artist, album, and artwork (for songs that have it).
- [ ] F7/F8/F9 (or fn+F7/F8/F9) keys control playback.
- [ ] Pause/Play on AirPods or Bluetooth headset toggles playback.
- [ ] Lock Screen shows current song while playing.

## Notifications

- [ ] A banner appears when a new song starts.
- [ ] Action buttons 👍 / 👎 / ⏭ work when clicked.
- [ ] Disabling "Notify on song change" in Preferences stops the banners.

## History

- [ ] Bottom drawer shows most recent song when collapsed.
- [ ] Expanding the drawer shows the last ~50 songs with thumbs icons.
- [ ] Right-click "Open in Pandora" opens the correct URL.

## Global hotkeys

- [ ] Setting `defaults write org.pianobar-gui.PianobarGUI hotkey.playPause "49,768"` binds ⌘⇧Space (keyCode 49 = space, mods 768 = ⌘⇧) — verify the hotkey triggers play/pause from any frontmost app.
- [ ] Clearing the `hotkey.playPause` key stops the hotkey from triggering.

## Preferences

- [ ] Opening Preferences (⌘,) shows 5 tabs.
- [ ] Changing Audio quality is saved (restart, verify persisted).
- [ ] Toggles update immediately in their respective behaviors.
- [ ] Sign Out clears credentials and returns to LoginView.

## Supervisor

- [ ] Kill pianobar via Activity Monitor once — playback resumes automatically within a few seconds.
- [ ] Rename `/opt/homebrew/bin/pianobar` temporarily so it can't spawn — after the backoff exhausts, error banner appears. Restore the binary.
