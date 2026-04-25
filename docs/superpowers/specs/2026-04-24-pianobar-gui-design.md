# Orpheus — Design Spec

> Originally drafted under the working title **PianobarGUI**; the shipping
> app is **Orpheus**. References below to "PianobarGUI" remain accurate
> for filenames, the Swift package name, and the bundle identifier — only
> user-facing identity changed.

**Date:** 2026-04-24
**Author:** wweaver
**Status:** Draft for review

## Summary

A native macOS Pandora client, built in Swift/SwiftUI on top of the
[pianobar](https://github.com/promyloph/pianobar) CLI. Replaces
[Hermes](https://hermesapp.org/), which is an unmaintained 32-bit Intel app
that stops working on newer macOS releases.

The user is a paying Pandora subscriber and specifically wants the Pandora
service, the menu-bar-first UX of Hermes, and integration with macOS native
media controls (Control Center, Now Playing widget, media keys).

## Goals

- Feel like a native macOS app: menu bar presence, unified window with
  sidebar, Now Playing widget, media keys, system notifications, Keychain.
- Support the core Pandora actions: play/pause/skip, thumbs up/down, tired-
  of-track, bookmark song/artist, switch stations, create/rename/delete
  stations, played-song history.
- Survive Pandora-side API changes with minimal maintenance by delegating
  all protocol work to pianobar.
- Ship as a signed, notarized `.app` that double-click installs like any
  other Mac app.

## Non-Goals

- Last.fm scrobbling.
- Sleep timer / quiet hours.
- Supporting services other than Pandora.
- Premium-only features Pandora's app offers that pianobar does not
  (on-demand tracks, podcasts, lyrics scrolling). If pianobar gains them
  later we can wire them up; not MVP.
- Seeking within a track (pianobar does not support it).
- iOS / iPadOS companion.

## Architecture

Single Swift/SwiftUI app that spawns and supervises a bundled `pianobar`
binary. The Swift app owns the UI and state; pianobar owns Pandora
protocol and audio output. Two IPC channels between them:

- **Commands (Swift → pianobar):** writes to a named pipe (FIFO) that
  pianobar watches.
- **Events (pianobar → Swift):** pianobar invokes its `event_command` hook
  on every state change; we install a small helper script as that hook,
  which forwards the event over a Unix domain socket to the app.

```
┌─────────────────────────────────────────┐
│  PianobarGUI.app (Swift / SwiftUI)       │
│                                          │
│  ┌──────────────┐   ┌─────────────────┐ │
│  │ SwiftUI View │◄──┤ PlaybackState   │ │
│  │ (main window)│   │ (ObservableObj) │ │
│  └──────────────┘   └─────────────────┘ │
│  ┌──────────────┐          ▲            │
│  │ Menu bar     │          │            │
│  │ NSStatusItem │          │            │
│  └──────────────┘   ┌──────┴────────┐   │
│  ┌──────────────┐   │ PianobarCtrl  │   │
│  │ MPNowPlaying │   │  ─ command()  │───┼── FIFO write
│  │ / media keys │──►│  ─ events →   │◄──┼── Unix socket read
│  └──────────────┘   └───────────────┘   │
└──────────┬───────────────┬──────────────┘
           │ spawn         │ sees events
           ▼               │
   ┌──────────────────────┐│
   │  pianobar (subproc)  ├┘
   │  reads FIFO ──►      │
   │  runs event_command ─┘
   │  → event_bridge.sh   │
   │  → events.sock       │
   └──────────┬───────────┘
              │ HTTPS + audio
              ▼
       Pandora API + libao
```

Key invariants:

- **pianobar is bundled inside the `.app`** at
  `Contents/MacOS/pianobar`. The user never installs it separately.
- **Isolated config** at
  `~/Library/Application Support/PianobarGUI/pianobar/`. We set
  `XDG_CONFIG_HOME` when spawning pianobar so we never touch a user's
  existing pianobar setup.
- **State is unidirectional:** UI → `PianobarCtrl` → FIFO → pianobar →
  event → `PlaybackState` → UI. No back-channel. UI waits for the event
  before reflecting a change (no optimistic updates in v1).

## Components

Swift modules, each with a single responsibility.

### `PianobarProcess`

Owns the pianobar child process lifecycle.

- `start()` / `stop()` / `restart()`.
- Sets `XDG_CONFIG_HOME` to our isolated config dir, sets a clean `PATH`,
  launches `Contents/MacOS/pianobar`.
- Supervises the process. On unexpected exit, emits a failure event and
  auto-restarts with exponential backoff (1, 2, 4, 8, 16, 30s). After
  5 consecutive failures, stops retrying and surfaces a persistent
  "Playback stopped" banner with a manual Retry button.
- Captures stdout/stderr into a rolling log file
  (`~/Library/Logs/PianobarGUI/pianobar.log`, capped at a few MB). Not
  used for event parsing — debug only.

### `PianobarCtrl`

Writes commands to the control FIFO. Serialized via an actor so writes
never interleave.

Public API:

```swift
func play()
func pause()
func togglePlay()
func next()
func love()
func ban()
func tired()
func bookmarkSong()
func bookmarkArtist()
func switchStation(id: String)
func createStationFromSong()
func createStationFromArtist()
func createStationFromSearch(_ query: String)
func deleteStation(id: String)
func renameStation(id: String, to newName: String)
func setVolume(_ zeroToOneHundred: Int)
func quit()
```

Each maps to pianobar's documented FIFO protocol (`p`, `n`, `+`, `-`,
`t`, `b`, `s<N>\n`, etc.).

### `EventBridge`

Receives events from pianobar.

- On app launch, opens a Unix domain socket at
  `~/Library/Application Support/PianobarGUI/events.sock`.
- Installs `event_bridge.sh` in the config dir and points pianobar's
  `event_command` at it. The script is trivial: it reads stdin and
  writes `"$1\n$(cat)\n\x1e"` to the socket using `nc -U` (or a bundled
  tiny helper if `nc` differs across macOS versions — see Testing
  section for verification).
- The Swift side accepts each connection, reads the payload until `\x1e`,
  parses `event_type` and the key=value payload into a typed enum:

```swift
enum PianobarEvent {
    case songStart(SongInfo)
    case songFinish(SongInfo)
    case songLove, songBan, songShelf, songBookmark, artistBookmark
    case stationsChanged([Station])
    case stationCreated(Station)
    case stationDeleted(id: String)
    case stationRenamed(id: String, newName: String)
    case userLogin(success: Bool, message: String)
    case pandoraError(code: Int, message: String)
    case networkError(message: String)
}
```

- Publishes events via an `AsyncStream<PianobarEvent>`. Exactly one
  consumer: `PlaybackState`.

### `PlaybackState`

`@MainActor final class PlaybackState: ObservableObject`. Single source
of truth.

Published properties:

```swift
@Published var currentSong: SongInfo?
@Published var currentStation: Station?
@Published var stations: [Station] = []
@Published var history: [SongInfo] = []   // bounded, last 50
@Published var isPlaying: Bool = false
@Published var volume: Int = 50            // 0..100
@Published var progressSeconds: Int = 0
@Published var errorBanner: ErrorBanner?
```

Behavior:

- Subscribes to `EventBridge.events` on init; applies mutations.
- Owns the progress ticker: a 1 Hz `Timer` that increments
  `progressSeconds` while `isPlaying`; reset to 0 on `songStart`; clamped
  at `currentSong.durationSeconds`.
- On `songStart`, appends previous song (if any) to `history`, trims to
  last 50.
- On auth failure, clears Keychain and posts an `.authRequired`
  notification the scene graph observes to show `LoginView`.

### `KeychainStore`

Thin wrapper over `SecItem*` APIs. `kSecClassGenericPassword`, service
name derived from the app's bundle identifier (e.g. if bundle id is
`org.pianobar-gui.PianobarGUI`, service is
`org.pianobar-gui.PianobarGUI.pandora`), account = email.

```swift
func save(email: String, password: String) throws
func load() -> (email: String, password: String)?
func delete()
```

### `ConfigManager`

Writes the pianobar config file at each app launch from Keychain
credentials and user preferences.

Generated config template:

```ini
user = <email>
password = <password>
audio_quality = high
autoselect = 1
event_command = <app support>/pianobar/event_bridge.sh
fifo = <app support>/pianobar/ctl
```

File is written with mode `0600`. The config dir itself is mode `0700`.

### `NowPlayingBridge`

System integration.

- Registers handlers on `MPRemoteCommandCenter` for `playCommand`,
  `pauseCommand`, `togglePlayPauseCommand`, `nextTrackCommand`,
  `likeCommand`, `dislikeCommand`. Disables `previousTrackCommand`,
  `changePlaybackPositionCommand`.
- Publishes to `MPNowPlayingInfoCenter.default().nowPlayingInfo`
  whenever `PlaybackState.currentSong` or progress changes. Includes
  title, artist, album, artwork (`MPMediaItemArtwork` built from the
  fetched cover image), elapsed playback time, duration, and playback
  rate (0.0 when paused, 1.0 when playing). This is what makes the app
  appear in Control Center's Now Playing widget and respond to AirPods
  pause-resume, Bluetooth headset buttons, and the F7/F8/F9 keys.

### `NotificationPresenter`

On `songStart`, posts a `UNNotificationRequest` via
`UNUserNotificationCenter`. Category has action buttons for thumbs up,
thumbs down, skip (routed to `PianobarCtrl`). Clicking the banner
activates the main window. Respects a "Notify on song change"
preference (default on).

### `MenuBarController`

- `NSStatusItem` with variable length.
- Title: `"♪ {artist} — {title}"`, truncated to a configurable max width
  (default 40 chars) with middle-ellipsis so the artist stays visible.
- Left-click: activate app and focus the main window; create it if it
  doesn't exist.
- Right-click / option-click: `NSMenu` with:
  - Play/Pause (⌘P)
  - Next Track (⌘→)
  - Thumbs Up (⌘↑) / Thumbs Down (⌘↓)
  - (separator)
  - Stations ▸ submenu; checkmark on current.
  - (separator)
  - Show PianobarGUI
  - Preferences…
  - Quit PianobarGUI

## Data Flow

### Launch sequence (happy path)

1. `PianobarGUIApp` creates the menu bar item immediately for instant
   visible feedback.
2. `KeychainStore.load()`. If nil → present `LoginView` sheet; block
   further startup until credentials are saved.
3. `ConfigManager.writeConfig(credentials, prefs)`.
4. `EventBridge.start()`: create and listen on the Unix socket.
5. `PianobarProcess.start()`.
6. pianobar logs in, fetches stations, fires `usergetstations` → state
   `.stations` populated.
7. pianobar auto-selects last station and begins playback → `songstart`
   → state `.currentSong` populated, progress timer starts, NowPlaying
   info published, notification fired, menu bar title updated.

### User action → pianobar (example: thumbs up)

1. SwiftUI button → `playbackState.love()`.
2. `PlaybackState.love()` → `PianobarCtrl.love()` → writes `+\n` to FIFO.
3. pianobar processes command, fires `songlove` event.
4. `EventBridge` parses → `PlaybackState.currentSong.rating = .loved`.
5. UI reflects filled thumb.

Same pattern for every command. One-way, event-confirmed.

### pianobar → app (events)

`event_bridge.sh` receives event type as `$1` and key=value payload on
stdin. Forwards `"$1\n<stdin>\n\x1e"` over the Unix socket. EventBridge
reads, splits, parses into typed events. Single consumer:
`PlaybackState`.

Events handled at MVP:

| pianobar event | Effect |
|---|---|
| `songstart` | Replace current song, reset progress timer, push Now Playing, fire notification |
| `songfinish` | Append finished song to history |
| `songlove` / `songban` / `songshelf` / `songbookmark` / `artistbookmark` | Update current-song flags |
| `stationfetchplaylist` | Surface short "Buffering…" hint |
| `usergetstations` | Replace stations list |
| `stationcreate` / `stationdelete` / `stationrename` / `stationaddmusic` | Mutate stations list |
| `userlogin` | If `pRet != 1`: clear Keychain, show login; else mark authenticated |

Any event with `pRet != 1` (Pandora error) or `wRet != 0` (network
error) sets `errorBanner` with the `pRetStr`/`wRetStr` message and
appropriate severity.

### Pause semantics

pianobar's `p` is a toggle with no confirming event. `PlaybackState`
flips `isPlaying` locally when the command is sent. If it ever desyncs
(e.g., user quit pianobar via menu), the next `songstart` will
resynchronize.

## UI Layout

### Main window

Single `NSWindow`, titled, resizable. Min size 680×420. Remembers last
size and position via `NSWindow.FrameAutosaveName`.

Two-pane split view:

- **Left sidebar — `StationsSidebarView`:** source-list styled `List`.
  Filter field at top, sortable by name or recently added. Row shows
  station name + a speaker-dot indicator on the currently playing one.
  Right-click context: Switch, Rename, Delete. Keyboard: ⌫ delete (with
  confirm), ⏎ switch, F2 rename inline. Toolbar with `+` (create-
  station sheet) and `⟳` refresh.

- **Right pane — `NowPlayingView`:** album art (clickable → opens
  Pandora page via `detailUrl`), song/artist/album stack, transport
  row (disabled prev, play/pause, skip, thumbs down, thumbs up,
  overflow menu with Bookmark Song, Bookmark Artist, Tired of Track,
  Open in Pandora), read-only progress bar with elapsed/total, volume
  slider.

Bottom collapsible drawer — `HistoryView`: one-line collapsed (most
recent), expanded shows last ~50 songs with rating icons. Right-click
on a row → Create Station from Song/Artist, Bookmark (actions grayed
out for songs no longer in pianobar's buffer).

### Login sheet — `LoginView`

Email, password, "Remember me in Keychain" (default on), Sign In.
Shown when Keychain has no credentials or on auth failure.

### Preferences window — `PreferencesView`

Tabs:

- **General:** start at login, audio quality (low/medium/high),
  explicit content filter.
- **Menu Bar:** show song title, show artist, max width, marquee scroll.
- **Notifications:** enable/disable song-change banner, show action
  buttons.
- **Hotkeys:** global shortcuts for play/pause, next, thumbs up,
  thumbs down. Implemented via `MASShortcut` (or equivalent Carbon
  `RegisterEventHotKey` wrapper).
- **Account:** current user, Sign Out (clears Keychain, restarts
  pianobar).

### Menu bar

See `MenuBarController` above.

### Empty / error states

- No stations yet → main pane shows "Create your first station" CTA.
- pianobar process died → non-blocking top banner: "Playback stopped.
  Reconnecting… [Retry]". Auto-retry with backoff.
- Auth failed → kick to `LoginView` with banner "Sign-in failed:
  <reason>".

## Error Handling

| Failure mode | Response |
|---|---|
| pianobar process exits non-zero | Log stderr tail, restart with exponential backoff (1/2/4/8/16/30s). After 5 consecutive failures, show persistent banner with manual Retry. |
| Auth failure (`userlogin` with `pRet != 1`) | Clear Keychain, present `LoginView`, show the error message from `pRetStr`. |
| Pandora API error (`pRet != 1` on non-login event) | Transient banner with `pRetStr`; retry only if the failed command is retryable (e.g., love/ban). Don't retry station-mutating commands automatically. |
| Network error (`wRet != 0`) | Transient banner with `wRetStr` and a Retry action. pianobar itself retries internally; we just surface the transient. |
| FIFO write fails (EPIPE / no such file) | Treat as pianobar-dead, trigger `PianobarProcess.restart()`. |
| Event socket accept fails | Log and continue — affected event is lost but next event re-establishes. No user-facing banner (common during normal startup races). |
| Keychain access denied | Show explanation in `LoginView`: "macOS blocked Keychain access. Grant permission and retry." |
| Bundled pianobar binary missing or unsigned | Fail loud at startup: "Installation is damaged. Reinstall PianobarGUI." |

Crashing the Swift app is never correct recovery. All recoverable
failures surface through `PlaybackState.errorBanner`.

## Testing Strategy

Three layers.

### Unit tests (`PianobarGUITests`)

- **Event parsing:** feed canned payloads (captured from real pianobar
  runs) to `EventBridge`'s parser, assert the produced typed event.
  One payload per event type plus a few malformed ones.
- **State mutations:** drive `PlaybackState` with sequences of typed
  events, assert published property values. Pure — no pianobar needed.
- **Command encoding:** verify `PianobarCtrl` produces the exact bytes
  pianobar expects for each command (snapshot test against a fake FIFO
  that's just a pipe).
- **Keychain:** round-trip save / load / delete against a real
  Keychain in a test-scoped service name.

### Integration test (`PianobarGUIIntegrationTests`)

- A **mock pianobar** shell script that honors the FIFO-command
  contract and emits canned events via `event_command`. Swift test
  spawns it the same way `PianobarProcess` would, drives it through
  login → stations → play → love → skip → quit, asserts
  `PlaybackState` progresses as expected. Verifies the full IPC stack
  without hitting Pandora.
- Verify `event_bridge.sh` works with the macOS `nc` that ships on the
  minimum supported OS version. If `nc -U` has compatibility issues,
  replace the shell script with a tiny bundled helper binary written
  in Swift (single `main.swift` that connects and forwards stdin).

### Manual QA checklist

Automated tests can't verify media-key integration, Now Playing widget,
or notification UX. A living checklist in
`docs/superpowers/qa-checklist.md` covers:

- Play/pause/skip via F7/F8/F9, AirPods, Bluetooth headset.
- Control Center Now Playing widget shows current song with artwork.
- Notification banner on song change; action buttons work.
- Menu bar title updates within 1s of song change; truncation looks
  right for long titles.
- Global hotkeys trigger from a frontmost non-focused app.
- Sign out clears Keychain; next launch shows Login.
- First-run onboarding works from a fresh account (no existing config).

Run manually before every release.

## Distribution & Packaging

### Build

- Xcode project with two targets: `PianobarGUI` (the app) and
  `PianobarGUITests`.
- `pianobar` and its runtime deps (`libao`, `libfaad`, `libgcrypt`,
  `libgnutls`, `libjson-c`) built from source in a reproducible CI
  step (GitHub Actions on `macos-14` + `macos-15` runners). Pinned
  commit / release for each.
- All dylibs embedded in `Contents/Frameworks/`. `install_name_tool`
  rewrites library references to `@rpath/...`. `LC_RPATH` in the
  pianobar binary points at `@executable_path/../Frameworks`. Verified
  by `otool -L Contents/MacOS/pianobar` showing only `@rpath` and
  system libs.
- Universal binary (arm64 + x86_64) so the app works on Intel and
  Apple Silicon Macs.

### Signing & Notarization

- Code-signed with a Developer ID Application certificate. Every
  bundled Mach-O — the app, `pianobar`, every dylib in
  `Contents/Frameworks/` — is signed individually with the same
  identity before the outer app is signed. Hardened runtime enabled.
  Entitlements kept minimal; the bundled pianobar needs
  `com.apple.security.cs.allow-unsigned-executable-memory` only if a
  dep requires it — verified at build, not assumed.
- Notarized via `notarytool submit --wait` in CI. Staple the ticket
  to the `.app` and the `.dmg`.
- Distributed as a signed, notarized `.dmg` attached to GitHub
  Releases. Also publish a Homebrew cask formula pointing at the same
  release artifact.

### Auto-update

- Sparkle 2.x. Appcast hosted from GitHub Pages (or the release's
  `appcast.xml`). EdDSA-signed updates.

### Minimum supported macOS

macOS 13 Ventura (covers SwiftUI features we need, MediaPlayer APIs,
UNUserNotificationCenter; keeps the audience reasonable without
accumulating ancient-OS workarounds).

## Out of Scope / Future Work

- Last.fm or ListenBrainz scrobbling.
- Sleep timer.
- Lyrics panel.
- iCloud sync of preferences.
- iPad / iOS companion.
- Replace pianobar with a native Swift Pandora client. Only worth it
  if pianobar becomes unmaintained and the community doesn't fork it.

## Open Questions

- Does Apple's current notarization flow accept the bundled pianobar +
  its dylibs cleanly? First end-to-end notarization run during
  packaging setup is the verification.
- Exact MPNowPlayingInfoCenter behavior when the app is not frontmost —
  needs device testing on macOS 15 (Control Center UX varies by OS
  version).
