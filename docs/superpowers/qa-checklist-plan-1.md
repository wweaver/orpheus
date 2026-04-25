# Orpheus — QA Checklist (Plan 1)

Do these manual checks against a real Pandora account on a dev Mac with
`brew install pianobar` before declaring Plan 1 done.

## First-run

- [ ] Fresh Application Support dir (delete `~/Library/Application Support/PianobarGUI/` if present).
- [ ] Launch app → LoginView appears.
- [ ] Enter valid credentials, click Sign In.
- [ ] Main window opens. Within ~5 seconds, stations populate and a song starts.

## Playback

- [ ] Album art loads for the current song.
- [ ] Song title, artist, album displayed correctly.
- [ ] Progress bar advances approximately in real time.
- [ ] Play/pause toggles; pause stops the progress timer.
- [ ] Skip loads the next song within a second or two.

## Rating

- [ ] Thumbs-up highlights; reverting via thumbs-down updates immediately.
- [ ] Overflow menu: Tired of Track skips and doesn't replay the song soon.
- [ ] Overflow menu: Bookmark Song, Bookmark Artist complete without error.

## Stations

- [ ] Sidebar lists all stations.
- [ ] Clicking a different station starts a new song from that station within a few seconds.
- [ ] Filter field narrows the list instantly.

## Volume

- [ ] Slider adjusts playback volume audibly.

## Second launch

- [ ] Close the app, relaunch. Skips LoginView, auto-resumes last station.

## Sign out (via Keychain)

- [ ] Manually delete Keychain entry (via Keychain Access.app, search for the
      app's service name `org.pianobar-gui.PianobarGUI.pandora`). Restart
      app → LoginView returns.

## Failure modes

- [ ] Disable Wi-Fi; trigger a skip. An error banner appears with an
      informative message. Re-enable Wi-Fi, click Retry (or next action);
      playback resumes without restarting the app.
- [ ] Kill `pianobar` via Activity Monitor. Error banner appears; Plan 2
      adds auto-restart — for now, quit and relaunch.
