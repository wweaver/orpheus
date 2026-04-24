# PianobarGUI Plan 2 — System Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make PianobarGUI feel native — menu-bar presence, system Now Playing widget, media-key control, song-change notifications, play history, global hotkeys, preferences, and resilient pianobar-process supervision. At the end, the app is a first-class macOS music client; only packaging (Plan 3) remains before release.

**Architecture:** Adds one new PianobarCore module (supervisor backoff in `PianobarProcess`) and a set of app-layer system bridges under `App/System/`. Preferences persist via `@AppStorage` + `UserDefaults`. Global hotkeys use Carbon `RegisterEventHotKey` wrapped in a small Swift façade. Each bridge is independent and observes `PlaybackState` / calls `PianobarCtrl`.

**Tech Stack:** MediaPlayer framework (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), `UserNotifications`, AppKit (`NSStatusItem`), Carbon Events (`RegisterEventHotKey`), SwiftUI `Settings` scene.

---

## Prerequisites

Plan 1 complete and merged to `main`. `xcodegen generate` + `xcodebuild -scheme PianobarGUI build` both succeed; `cd Packages/PianobarCore && swift test` shows 26/26 tests passing.

## File Structure

New files in this plan:

```
App/
├── System/                                (new directory)
│   ├── NowPlayingBridge.swift
│   ├── NotificationPresenter.swift
│   ├── MenuBarController.swift
│   └── GlobalHotkeys.swift
├── Views/
│   ├── HistoryView.swift                  (new)
│   └── PreferencesView.swift              (new)
└── Prefs.swift                            (new — @AppStorage-backed settings namespace)

Packages/PianobarCore/Sources/PianobarCore/
└── Pianobar/
    └── PianobarProcess.swift              (modified — add supervisor/backoff)

Packages/PianobarCore/Tests/PianobarCoreTests/
└── PianobarProcessSupervisionTests.swift  (new)
```

Modified files in this plan:
- `App/PianobarGUIApp.swift` — register the Settings scene, install app-level system bridges.
- `App/AppBootstrap.swift` — use the supervised `PianobarProcess`, expose `signOut()`.
- `App/Views/MainWindowView.swift` — attach the history drawer; wire error-banner dismissal.
- `Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift` — add `dismissErrorBanner()`.

---

### Task 1: PianobarProcess supervision (auto-restart with backoff)

Today's `PianobarProcess.start()` just spawns the child. If pianobar dies mid-song, nothing notices. This task adds a supervisor loop that watches the process and restarts it with exponential backoff (1, 2, 4, 8, 16, 30s), giving up after 5 consecutive failures and emitting a `supervisionFailed` signal.

**Files:**
- Modify: `Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarProcess.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/PianobarProcessSupervisionTests.swift`

- [ ] **Step 1: Write failing tests**

`Packages/PianobarCore/Tests/PianobarCoreTests/PianobarProcessSupervisionTests.swift`:

```swift
import XCTest
@testable import PianobarCore

final class PianobarProcessSupervisionTests: XCTestCase {
    private var workDir: URL!
    private var fifoPath: String!
    private var socketPath: String!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        socketPath = workDir.appendingPathComponent("s.sock").path
        let cfgDir = workDir.appendingPathComponent("pianobar")
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        fifoPath = cfgDir.appendingPathComponent("ctl").path
        _ = mkfifo(fifoPath, 0o600)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// A script that exits immediately with failure — simulates pianobar crashing on startup.
    private func writeCrashingMock() throws -> String {
        let path = workDir.appendingPathComponent("crashing.sh").path
        try "#!/bin/sh\nexit 42\n".write(toFile: path, atomically: true, encoding: .utf8)
        _ = chmod(path, 0o755)
        return path
    }

    func testSupervisorRetriesAndEventuallyGivesUp() async throws {
        let proc = PianobarProcess(
            executablePath: try writeCrashingMock(),
            xdgConfigHome: workDir.path,
            eventSocketPath: socketPath,
            supervisorBackoff: [0.05, 0.05, 0.05, 0.05, 0.05]  // fast for testing
        )

        var failureReceived = false
        let failureTask = Task {
            for await _ in proc.supervisorFailures { failureReceived = true; break }
        }

        try await proc.start()

        // Give the supervisor loop time to exhaust retries.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        XCTAssertTrue(failureReceived, "expected supervisorFailures stream to emit after max retries")
        XCTAssertEqual(await proc.state, .crashed)
        failureTask.cancel()
    }

    func testSuccessfulStartResetsRetryCount() async throws {
        // A script that runs and sleeps — simulates a healthy pianobar.
        let healthyPath = workDir.appendingPathComponent("healthy.sh").path
        try "#!/bin/sh\nsleep 10\n".write(toFile: healthyPath, atomically: true, encoding: .utf8)
        _ = chmod(healthyPath, 0o755)

        let proc = PianobarProcess(
            executablePath: healthyPath,
            xdgConfigHome: workDir.path,
            eventSocketPath: socketPath,
            supervisorBackoff: [0.05]
        )
        try await proc.start()
        // Let it run briefly, then confirm it's still running (not restarted).
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(await proc.state, .running)
        try await proc.stop()
    }
}
```

- [ ] **Step 2: Confirm compile failure**

Run: `cd Packages/PianobarCore && swift test --filter PianobarProcessSupervisionTests`
Expected: FAIL — `supervisorBackoff`, `supervisorFailures` not defined.

- [ ] **Step 3: Extend `PianobarProcess.swift`**

Replace contents with:

```swift
import Foundation

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private let logFileURL: URL?
    private let supervisorBackoff: [TimeInterval]
    private var process: Process?
    private(set) var state: State = .stopped
    private var shouldStopSupervising = false
    private var supervisorTask: Task<Void, Never>?

    private let failureContinuation: AsyncStream<Void>.Continuation
    public let supervisorFailures: AsyncStream<Void>

    /// Default backoff: 1, 2, 4, 8, 16, 30s. After 5 consecutive crashes, give up.
    public init(executablePath: String,
                xdgConfigHome: String,
                eventSocketPath: String,
                logFileURL: URL? = nil,
                supervisorBackoff: [TimeInterval] = [1, 2, 4, 8, 16, 30]) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
        self.logFileURL = logFileURL
        self.supervisorBackoff = supervisorBackoff

        var cont: AsyncStream<Void>.Continuation!
        self.supervisorFailures = AsyncStream { cont = $0 }
        self.failureContinuation = cont
    }

    public func start() async throws {
        if state == .running { return }
        shouldStopSupervising = false
        supervisorTask = Task { [weak self] in
            await self?.superviseLoop()
        }
    }

    public func stop() async throws {
        shouldStopSupervising = true
        supervisorTask?.cancel()
        supervisorTask = nil
        guard let p = process else { state = .stopped; return }
        p.terminate()
        p.waitUntilExit()
        process = nil
        state = .stopped
    }

    private func superviseLoop() async {
        var failureIndex = 0
        while !shouldStopSupervising {
            do {
                try spawn()
            } catch {
                await handleFailure(&failureIndex)
                continue
            }
            state = .running
            // Block until the process exits.
            await waitForExit()
            if shouldStopSupervising { return }
            // Unexpected exit.
            await handleFailure(&failureIndex)
        }
    }

    private func spawn() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "XDG_CONFIG_HOME": xdgConfigHome,
            "PIANOBAR_GUI_SOCK": eventSocketPath,
        ]
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let logHandle: FileHandle
        if let url = logFileURL {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            logHandle = (try? FileHandle(forWritingTo: url))
                ?? FileHandle(forWritingAtPath: "/dev/null")!
            logHandle.seekToEndOfFile()
        } else {
            logHandle = FileHandle(forWritingAtPath: "/dev/null")!
        }
        p.standardOutput = logHandle
        p.standardError = logHandle
        do {
            try p.run()
        } catch {
            throw Error.spawnFailed(String(describing: error))
        }
        process = p
    }

    private func waitForExit() async {
        guard let p = process else { return }
        await withCheckedContinuation { cont in
            Task.detached {
                p.waitUntilExit()
                cont.resume()
            }
        }
        process = nil
    }

    private func handleFailure(_ failureIndex: inout Int) async {
        if failureIndex >= supervisorBackoff.count {
            state = .crashed
            failureContinuation.yield(())
            shouldStopSupervising = true
            return
        }
        let delay = supervisorBackoff[failureIndex]
        failureIndex += 1
        let nanos = UInt64(max(delay, 0) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanos)
    }
}
```

- [ ] **Step 4: Run tests; confirm pass**

Run: `cd Packages/PianobarCore && swift test --filter PianobarProcessSupervisionTests`
Expected: PASS, 2 tests.

Also run full suite — the existing `PianobarProcessTests` must still pass (ensure its `.userLogin` event arrival still works with the new supervisor flow):

Run: `cd Packages/PianobarCore && swift test`
Expected: 28 tests total (26 from Plan 1 + 2 new), all pass.

If `PianobarProcessTests.testStartsMockAndReceivesLoginEvent` now fails, the supervisor loop may be shutting down before the event arrives. Check: does the healthy mock keep running? Debug by lengthening its sleep. Report BLOCKED with findings rather than guessing at fixes.

- [ ] **Step 5: Commit**

```bash
cd /Users/williamweaver/git/pianobar-gui
git add Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarProcess.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/PianobarProcessSupervisionTests.swift
git commit -m "Supervise pianobar with exponential-backoff restart and failure stream"
```

---

### Task 2: Prefs namespace

Central `@AppStorage`-backed settings struct used across the app.

**Files:**
- Create: `App/Prefs.swift`

- [ ] **Step 1: Write `Prefs.swift`**

```swift
import Foundation
import SwiftUI

/// Single source of truth for user preferences. Backed by `UserDefaults`.
enum Prefs {
    enum Keys {
        static let audioQuality = "audioQuality"           // String: "low"|"medium"|"high"
        static let showNotifications = "showNotifications" // Bool
        static let menuBarShowArtist = "menuBarShowArtist" // Bool
        static let menuBarShowTitle  = "menuBarShowTitle"  // Bool
        static let menuBarMaxWidth   = "menuBarMaxWidth"   // Int (chars)
    }

    /// Defaults applied once at first launch if the key is missing.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.audioQuality: "high",
            Keys.showNotifications: true,
            Keys.menuBarShowArtist: true,
            Keys.menuBarShowTitle: true,
            Keys.menuBarMaxWidth: 40,
        ])
    }
}
```

- [ ] **Step 2: Call `Prefs.registerDefaults()` at app init**

Edit `App/PianobarGUIApp.swift`, inside the `PianobarGUIApp` struct, add an initializer:

```swift
@main
struct PianobarGUIApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        Prefs.registerDefaults()
    }

    // body unchanged
```

- [ ] **Step 3: Build**

```bash
cd /Users/williamweaver/git/pianobar-gui
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/Prefs.swift App/PianobarGUIApp.swift PianobarGUI.xcodeproj
git commit -m "Add Prefs namespace with UserDefaults defaults registration"
```

---

### Task 3: NowPlayingBridge (system widget + media keys)

Bridges `PlaybackState` to `MPNowPlayingInfoCenter` (Control Center / Lock Screen display) and registers `MPRemoteCommandCenter` handlers for play/pause/skip/like/dislike so F7/F8/F9, AirPods, and Bluetooth headsets route correctly.

**Files:**
- Create: `App/System/NowPlayingBridge.swift`
- Modify: `App/AppBootstrap.swift` — instantiate and retain a `NowPlayingBridge`.

- [ ] **Step 1: Write `NowPlayingBridge.swift`**

```swift
import Foundation
import MediaPlayer
import Combine
import PianobarCore

@MainActor
final class NowPlayingBridge {
    private let state: PlaybackState
    private let ctrl: PianobarCtrl
    private var subs = Set<AnyCancellable>()

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        registerCommands()
        observeState()
    }

    private func registerCommands() {
        let c = MPRemoteCommandCenter.shared()

        c.playCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.play(); self?.state.setPlaying(true) }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.pause(); self?.state.setPlaying(false) }
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { try? await self.ctrl.togglePlay(); self.state.setPlaying(!self.state.isPlaying) }
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.next() }
            return .success
        }
        c.likeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.love() }
            return .success
        }
        c.dislikeCommand.addTarget { [weak self] _ in
            Task { try? await self?.ctrl.ban() }
            return .success
        }

        // Disable what we can't support.
        c.previousTrackCommand.isEnabled = false
        c.changePlaybackPositionCommand.isEnabled = false
        c.seekForwardCommand.isEnabled = false
        c.seekBackwardCommand.isEnabled = false
    }

    private func observeState() {
        state.$currentSong
            .combineLatest(state.$progressSeconds, state.$isPlaying)
            .sink { [weak self] song, elapsed, playing in
                self?.publish(song: song, elapsed: elapsed, playing: playing)
            }
            .store(in: &subs)
    }

    private func publish(song: SongInfo?, elapsed: Int, playing: Bool) {
        guard let song else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyAlbumTitle: song.album,
            MPMediaItemPropertyPlaybackDuration: Double(song.durationSeconds),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(elapsed),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
        if let url = song.coverArtURL {
            Task {
                if let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    await MainActor.run {
                        var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                        current[MPMediaItemPropertyArtwork] = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                    }
                }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
```

- [ ] **Step 2: Wire into `AppBootstrap.swift`**

In `AppBootstrap`:

Add property near `private var process: PianobarProcess?`:
```swift
private var nowPlayingBridge: NowPlayingBridge?
```

At the end of `launch(email:password:)`, after `ctrl = PianobarCtrl(...)`:
```swift
if let state = playbackState, let ctrl = ctrl {
    nowPlayingBridge = NowPlayingBridge(state: state, ctrl: ctrl)
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/System/NowPlayingBridge.swift App/AppBootstrap.swift PianobarGUI.xcodeproj
git commit -m "Bridge PlaybackState to MPNowPlayingInfoCenter and media keys"
```

---

### Task 4: NotificationPresenter (song-change banners)

Fires a `UNNotificationRequest` each time `songStart` lands. Action buttons route back to `PianobarCtrl`.

**Files:**
- Create: `App/System/NotificationPresenter.swift`
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Write `NotificationPresenter.swift`**

```swift
import Foundation
import UserNotifications
import Combine
import PianobarCore

@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let state: PlaybackState
    private let ctrl: PianobarCtrl
    private var subs = Set<AnyCancellable>()
    private var lastSongTitleFired: String?

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        super.init()
        configureCategories()
        requestAuthorization()
        observeSongChanges()
        UNUserNotificationCenter.current().delegate = self
    }

    private func configureCategories() {
        let love = UNNotificationAction(identifier: "love", title: "👍", options: [])
        let ban  = UNNotificationAction(identifier: "ban",  title: "👎", options: [])
        let skip = UNNotificationAction(identifier: "skip", title: "⏭", options: [])
        let category = UNNotificationCategory(
            identifier: "song.change",
            actions: [love, ban, skip],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func observeSongChanges() {
        state.$currentSong
            .sink { [weak self] song in
                guard let self, let song,
                      song.title != self.lastSongTitleFired else { return }
                self.lastSongTitleFired = song.title
                self.fire(for: song)
            }
            .store(in: &subs)
    }

    private func fire(for song: SongInfo) {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.showNotifications) else { return }
        let content = UNMutableNotificationContent()
        content.title = song.title
        content.body  = "\(song.artist) — \(song.album)"
        content.categoryIdentifier = "song.change"
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionID = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(); return }
            switch actionID {
            case "love": try? await self.ctrl.love()
            case "ban":  try? await self.ctrl.ban()
            case "skip": try? await self.ctrl.next()
            default: break
            }
            completionHandler()
        }
    }
}
```

- [ ] **Step 2: Wire into `AppBootstrap.swift`**

Add property:
```swift
private var notificationPresenter: NotificationPresenter?
```

After `nowPlayingBridge = ...`:
```swift
notificationPresenter = NotificationPresenter(state: state, ctrl: ctrl)
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/System/NotificationPresenter.swift App/AppBootstrap.swift PianobarGUI.xcodeproj
git commit -m "Fire UNUserNotification banners on song changes with action buttons"
```

---

### Task 5: MenuBarController (NSStatusItem)

`NSStatusItem` showing the current song. Left-click activates the main window; right-click shows play/skip/thumbs commands and a Stations submenu.

**Files:**
- Create: `App/System/MenuBarController.swift`
- Modify: `App/PianobarGUIApp.swift` — own the `MenuBarController` via an `AppDelegate`.

- [ ] **Step 1: Write `MenuBarController.swift`**

```swift
import AppKit
import Combine
import PianobarCore

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private weak var bootstrap: AppBootstrap?
    private var subs = Set<AnyCancellable>()

    init(bootstrap: AppBootstrap) {
        self.bootstrap = bootstrap
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(primaryClick(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        observe()
    }

    private func observe() {
        guard let bootstrap else { return }
        bootstrap.$playbackState
            .compactMap { $0 }
            .sink { [weak self] state in
                state.$currentSong.sink { [weak self] _ in self?.refreshTitle() }
                    .store(in: &self!.subs)
            }
            .store(in: &subs)
    }

    private func refreshTitle() {
        guard let song = bootstrap?.playbackState?.currentSong else {
            statusItem.button?.title = "♪"
            return
        }
        let showTitle  = UserDefaults.standard.bool(forKey: Prefs.Keys.menuBarShowTitle)
        let showArtist = UserDefaults.standard.bool(forKey: Prefs.Keys.menuBarShowArtist)
        let maxWidth   = max(10, UserDefaults.standard.integer(forKey: Prefs.Keys.menuBarMaxWidth))
        var parts: [String] = []
        if showArtist { parts.append(song.artist) }
        if showTitle  { parts.append(song.title) }
        let raw = parts.joined(separator: " — ")
        let truncated = raw.count > maxWidth
            ? String(raw.prefix(maxWidth - 1)) + "…"
            : raw
        statusItem.button?.title = "♪ " + truncated
    }

    @objc private func primaryClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            presentMenu()
        } else {
            activateMainWindow()
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.title.contains("PianobarGUI") || $0.canBecomeKey }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func presentMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        guard let bootstrap, let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl else {
            let item = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(NSMenuItem(title: "Quit PianobarGUI",
                                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            return menu
        }

        let playTitle = state.isPlaying ? "Pause" : "Play"
        menu.addItem(commandItem(title: playTitle, key: "p") {
            Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
        })
        menu.addItem(commandItem(title: "Next", key: "") {
            Task { try? await ctrl.next() }
        })
        menu.addItem(commandItem(title: "Thumbs Up", key: "") {
            Task { try? await ctrl.love() }
        })
        menu.addItem(commandItem(title: "Thumbs Down", key: "") {
            Task { try? await ctrl.ban() }
        })
        menu.addItem(.separator())

        let stationsItem = NSMenuItem(title: "Stations", action: nil, keyEquivalent: "")
        let stationsMenu = NSMenu()
        for (idx, station) in state.stations.enumerated() {
            let item = commandItem(title: station.name, key: "") {
                Task { try? await ctrl.switchStation(index: idx) }
            }
            if station.id == state.currentStation?.id { item.state = .on }
            stationsMenu.addItem(item)
        }
        stationsItem.submenu = stationsMenu
        menu.addItem(stationsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show PianobarGUI",
                                action: #selector(activateMainWindowSelector),
                                keyEquivalent: ""))
        menu.items.last?.target = self
        menu.addItem(NSMenuItem(title: "Quit PianobarGUI",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func commandItem(title: String, key: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runClosure(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = ClosureBox(action)
        return item
    }

    @objc private func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? ClosureBox)?.run()
    }

    @objc private func activateMainWindowSelector() { activateMainWindow() }
}

private final class ClosureBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { action() }
}
```

- [ ] **Step 2: Install an AppDelegate to own the MenuBarController**

Edit `App/PianobarGUIApp.swift`:

```swift
import SwiftUI
import AppKit
import PianobarCore

@main
struct PianobarGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        Prefs.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("PianobarGUI") {
            Group {
                if bootstrap.needsLogin {
                    LoginView(onSubmit: { email, password in
                        bootstrap.saveCredentials(email: email, password: password)
                    })
                } else if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
                    MainWindowView(state: state, ctrl: ctrl)
                } else {
                    ProgressView("Starting…").padding()
                }
            }
            .task {
                appDelegate.attach(bootstrap: bootstrap)
                await bootstrap.start()
            }
            .frame(minWidth: 680, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func attach(bootstrap: AppBootstrap) {
        if menuBar == nil {
            menuBar = MenuBarController(bootstrap: bootstrap)
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/System/MenuBarController.swift App/PianobarGUIApp.swift PianobarGUI.xcodeproj
git commit -m "Add MenuBarController NSStatusItem with current-song title and stations submenu"
```

---

### Task 6: HistoryView (collapsible bottom drawer)

Shows the last 50 songs. Collapsed: one-line summary of the most recent. Expanded: scrollable list with rating icons and per-row context menu for "Create Station from Song/Artist" and "Bookmark".

**Files:**
- Create: `App/Views/HistoryView.swift`
- Modify: `App/Views/MainWindowView.swift` — attach the drawer at the bottom of the stack.

- [ ] **Step 1: Write `HistoryView.swift`**

```swift
import SwiftUI
import PianobarCore

struct HistoryView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if expanded {
                Divider()
                list
            }
        }
        .background(.background)
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                Text("History").bold()
                Spacer()
                if let most = state.history.first {
                    Text("\(most.title) · \(most.artist)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.history.enumerated()), id: \.offset) { _, song in
                    row(song).padding(.horizontal, 12).padding(.vertical, 6)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 220)
    }

    private func row(_ song: SongInfo) -> some View {
        HStack(spacing: 8) {
            icon(for: song.rating)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).lineLimit(1)
                Text("\(song.artist) · \(song.album)")
                    .foregroundStyle(.secondary).font(.caption).lineLimit(1)
            }
        }
        .contextMenu {
            if let url = song.detailURL {
                Button("Open in Pandora") { NSWorkspace.shared.open(url) }
            }
        }
    }

    @ViewBuilder private func icon(for rating: Rating) -> some View {
        switch rating {
        case .loved:   Image(systemName: "hand.thumbsup.fill").foregroundStyle(.green)
        case .banned:  Image(systemName: "hand.thumbsdown.fill").foregroundStyle(.red)
        case .unrated: Image(systemName: "music.note").foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 2: Attach to `MainWindowView.swift`**

Replace contents with:

```swift
import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 0) {
            if let msg = state.errorBanner {
                ErrorBanner(message: msg, onRetry: nil,
                            onDismiss: { state.dismissErrorBanner() })
            }
            NavigationSplitView {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl)
            }
            Divider()
            HistoryView(state: state, ctrl: ctrl)
        }
    }
}
```

- [ ] **Step 3: Add `dismissErrorBanner()` to `PlaybackState`**

In `Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift`, add this method:

```swift
public func dismissErrorBanner() {
    errorBanner = nil
}
```

- [ ] **Step 4: Verify**

```bash
cd Packages/PianobarCore && swift test 2>&1 | tail -3
cd /Users/williamweaver/git/pianobar-gui
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: 28 tests pass; `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/Views/HistoryView.swift App/Views/MainWindowView.swift \
        Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift \
        PianobarGUI.xcodeproj
git commit -m "Add collapsible HistoryView drawer and error-banner dismiss"
```

---

### Task 7: Global hotkeys

Carbon `RegisterEventHotKey` wrapped in a Swift façade. Four hotkeys: play/pause, next, thumbs up, thumbs down. Defaults inert until user configures them in Preferences.

**Files:**
- Create: `App/System/GlobalHotkeys.swift`
- Modify: `App/AppBootstrap.swift` — create a `GlobalHotkeys` instance; wire to `PianobarCtrl`.

Hotkeys are encoded as `(virtualKey: UInt32, modifiers: UInt32)` stored in `UserDefaults`. A `nil` binding is inert.

- [ ] **Step 1: Write `GlobalHotkeys.swift`**

```swift
import AppKit
import Carbon
import Combine
import PianobarCore

@MainActor
final class GlobalHotkeys {
    enum Action: String, CaseIterable {
        case playPause, next, love, ban

        var prefsKey: String { "hotkey.\(rawValue)" }

        /// Stable 1-indexed Carbon hotkey id.
        var hotKeyId: UInt32 {
            UInt32(Action.allCases.firstIndex(of: self)! + 1)
        }
    }

    private let ctrl: PianobarCtrl
    private let state: PlaybackState
    private var handlers: [Action: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private static var shared: GlobalHotkeys?  // for Carbon C callback

    init(state: PlaybackState, ctrl: PianobarCtrl) {
        self.state = state
        self.ctrl = ctrl
        GlobalHotkeys.shared = self
        installCarbonHandler()
        reloadAllBindings()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reloadAllBindings() }
        }
    }

    func reloadAllBindings() {
        for action in Action.allCases {
            unregister(action: action)
            if let (key, mods) = readBinding(action) {
                register(action: action, keyCode: key, modifiers: mods)
            }
        }
    }

    private func readBinding(_ action: Action) -> (UInt32, UInt32)? {
        let encoded = UserDefaults.standard.string(forKey: action.prefsKey)
        guard let encoded, !encoded.isEmpty else { return nil }
        let parts = encoded.split(separator: ",").compactMap { UInt32($0) }
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    private func register(action: Action, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x50475549), // "PGUI"
                                     id: action.hotKeyId)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr, let ref = hotKeyRef {
            handlers[action] = ref
        }
    }

    private func unregister(action: Action) {
        if let ref = handlers[action] {
            UnregisterEventHotKey(ref)
            handlers.removeValue(forKey: action)
        }
    }

    private func installCarbonHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, event, _) -> OSStatus in
                                var hotKeyID = EventHotKeyID()
                                GetEventParameter(event, OSType(kEventParamDirectObject),
                                                  OSType(typeEventHotKeyID),
                                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                                Task { @MainActor in
                                    GlobalHotkeys.shared?.dispatch(id: hotKeyID.id)
                                }
                                return noErr
                            }, 1, &spec, nil, &handlerRef)
    }

    private func dispatch(id: UInt32) {
        for action in Action.allCases where action.hotKeyId == id {
            fire(action)
        }
    }

    private func fire(_ action: Action) {
        Task { [weak self] in
            guard let self else { return }
            switch action {
            case .playPause:
                try? await self.ctrl.togglePlay()
                self.state.setPlaying(!self.state.isPlaying)
            case .next: try? await self.ctrl.next()
            case .love: try? await self.ctrl.love()
            case .ban:  try? await self.ctrl.ban()
            }
        }
    }
}
```

NOTE: Hotkey ids are stable integer positions in `Action.allCases`, which Carbon accepts in its 32-bit id space.

- [ ] **Step 2: Wire into AppBootstrap**

Add:
```swift
private var globalHotkeys: GlobalHotkeys?
```

At the end of `launch`:
```swift
globalHotkeys = GlobalHotkeys(state: state, ctrl: ctrl)
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add App/System/GlobalHotkeys.swift App/AppBootstrap.swift PianobarGUI.xcodeproj
git commit -m "Add GlobalHotkeys wrapper over Carbon RegisterEventHotKey"
```

---

### Task 8: PreferencesView + Settings scene

Tab-based preferences window. For Plan 2 we ship General, Menu Bar, Notifications, Account tabs. Hotkeys recording UI is basic (read-only display of what's bound, Clear button); a full key-recorder is future work.

**Files:**
- Create: `App/Views/PreferencesView.swift`
- Modify: `App/PianobarGUIApp.swift` — add a `Settings` scene.
- Modify: `App/AppBootstrap.swift` — add a `signOut()` method.

- [ ] **Step 1: Add `signOut()` to `AppBootstrap`**

```swift
func signOut() {
    keychain.delete()
    Task {
        try? await process?.stop()
        await bridge?.stop()
        playbackState = nil
        ctrl = nil
        bridge = nil
        process = nil
        nowPlayingBridge = nil
        notificationPresenter = nil
        globalHotkeys = nil
        needsLogin = true
    }
}
```

- [ ] **Step 2: Write `PreferencesView.swift`**

```swift
import SwiftUI
import PianobarCore

struct PreferencesView: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @AppStorage(Prefs.Keys.audioQuality) var audioQuality: String = "high"
    @AppStorage(Prefs.Keys.showNotifications) var showNotifications: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowArtist) var menuBarShowArtist: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowTitle)  var menuBarShowTitle: Bool = true
    @AppStorage(Prefs.Keys.menuBarMaxWidth)   var menuBarMaxWidth: Int = 40

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            hotkeys.tabItem { Label("Hotkeys", systemImage: "keyboard") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460, height: 300)
        .padding(20)
    }

    private var general: some View {
        Form {
            Picker("Audio quality", selection: $audioQuality) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
        }
    }

    private var menuBar: some View {
        Form {
            Toggle("Show artist", isOn: $menuBarShowArtist)
            Toggle("Show title",  isOn: $menuBarShowTitle)
            Stepper(value: $menuBarMaxWidth, in: 10...100) {
                Text("Max width: \(menuBarMaxWidth)")
            }
        }
    }

    private var notifications: some View {
        Form {
            Toggle("Notify on song change", isOn: $showNotifications)
        }
    }

    private var hotkeys: some View {
        Form {
            Text("Hotkey configuration coming soon. To set a hotkey manually, "
                 + "write `<keyCode>,<modifierMask>` to the `hotkey.<action>` "
                 + "UserDefaults key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var account: some View {
        Form {
            Button("Sign Out") {
                bootstrap.signOut()
            }
        }
    }
}
```

- [ ] **Step 3: Register the Settings scene**

Edit `App/PianobarGUIApp.swift`, add after the `WindowGroup`:

```swift
Settings {
    PreferencesView().environmentObject(bootstrap)
}
```

- [ ] **Step 4: Build**

```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/Views/PreferencesView.swift App/PianobarGUIApp.swift App/AppBootstrap.swift PianobarGUI.xcodeproj
git commit -m "Add PreferencesView (General/Menu Bar/Notifications/Hotkeys/Account) and Settings scene"
```

---

### Task 9: Wire supervisor failures into ErrorBanner

If pianobar dies permanently after backoff retries, surface it in the UI so the user can click a "Retry" button that restarts the bootstrap.

**Files:**
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Observe supervisor failures**

Add to `AppBootstrap`:

```swift
private var supervisorWatch: Task<Void, Never>?

private func watchSupervisor(_ proc: PianobarProcess, state: PlaybackState) {
    supervisorWatch?.cancel()
    supervisorWatch = Task { @MainActor [weak self, weak state] in
        for await _ in proc.supervisorFailures {
            state?.setErrorBanner("pianobar stopped responding. Click Retry to reconnect.")
            self?.playbackState = nil  // force UI to show a "Starting…" or retry state
            break
        }
    }
}
```

- [ ] **Step 2: Expose `setErrorBanner` on PlaybackState**

In `Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift`, add:

```swift
public func setErrorBanner(_ message: String) {
    errorBanner = message
}
```

- [ ] **Step 3: Call the watcher from `launch`**

After `process = proc`:

```swift
watchSupervisor(proc, state: state)
```

- [ ] **Step 4: Verify**

```bash
cd Packages/PianobarCore && swift test 2>&1 | tail -3
cd /Users/williamweaver/git/pianobar-gui
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: 28 tests pass; `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add App/AppBootstrap.swift Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift PianobarGUI.xcodeproj
git commit -m "Surface supervisor failures as an error banner in the main window"
```

---

### Task 10: Plan 2 QA checklist

**Files:**
- Create: `docs/superpowers/qa-checklist-plan-2.md`
- Modify: `README.md` (brief mention of new features if helpful)

- [ ] **Step 1: Write the QA checklist**

```markdown
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

- [ ] Setting `defaults write org.pianobar-gui.PianobarGUI hotkey.playPause "49,768"` binds ⌘-Space-ish (keyCode 49 = space, mods 768 = ⌘⇧) — verify the hotkey triggers play/pause from any frontmost app.
- [ ] Clearing the `hotkey.playPause` key stops the hotkey from triggering.

## Preferences

- [ ] Opening Preferences (⌘,) shows 5 tabs.
- [ ] Changing Audio quality is saved (restart, verify persisted).
- [ ] Toggles update immediately in their respective behaviors.
- [ ] Sign Out clears credentials and returns to LoginView.

## Supervisor

- [ ] Kill pianobar via Activity Monitor once — playback resumes automatically within a few seconds.
- [ ] Rename `/opt/homebrew/bin/pianobar` temporarily so it can't spawn — after 5 fast failures, error banner appears with Retry. Restore the binary and Retry works.
```

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/qa-checklist-plan-2.md
git commit -m "Add Plan 2 QA checklist"
```

---

## Plan 2 Done Criteria

- All 10 tasks' commits landed on the working branch.
- `swift test` in `Packages/PianobarCore` passes (28 tests).
- `xcodebuild … build` succeeds.
- Every item in `docs/superpowers/qa-checklist-plan-2.md` checked.

When green, hand off to Plan 3 (packaging — bundle pianobar, sign, notarize, DMG + Sparkle auto-update).
