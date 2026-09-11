import Foundation
import SwiftUI
import Darwin
import AppKit
import Combine
import PianobarCore

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var needsLogin = false
    /// Message from the last rejected sign-in, shown on the login screen.
    @Published private(set) var loginError: String?
    @Published private(set) var startupError: String?
    @Published private(set) var playbackState: PlaybackState?
    @Published private(set) var ctrl: PianobarCtrl?

    private let keychain = KeychainStore(service: "org.pianobar-gui.PianobarGUI.pandora")
    private var bridge: EventBridge?
    private var process: PianobarProcess?
    private var nowPlayingBridge: NowPlayingBridge?
    private var notificationPresenter: NotificationPresenter?
    private var globalHotkeys: GlobalHotkeys?
    private var supervisorWatch: Task<Void, Never>?
    private var stationTracker: Task<Void, Never>?
    private var willTerminateObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var screenLockedObserver: NSObjectProtocol?
    private var snapshotSubs = Set<AnyCancellable>()
    private var startInvoked: Bool = false

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PianobarGUI")
    }
    private var configDir: URL { appSupportDir.appendingPathComponent("pianobar") }
    private var socketPath: String { appSupportDir.appendingPathComponent("events.sock").path }
    private var fifoPath:   String { configDir.appendingPathComponent("ctl").path }
    private var pidFilePath: String { appSupportDir.appendingPathComponent("pianobar.pid").path }

    func start() async {
        // Strict idempotency. Set the flag BEFORE any await so two concurrent
        // .task invocations from SwiftUI (which can happen when the
        // WindowGroup's RootView is restored or re-attached) can't both pass
        // a `playbackState == nil` check before either has populated it.
        if startInvoked { return }
        startInvoked = true
        guard let creds = keychain.load() else {
            needsLogin = true
            return
        }
        await launch(email: creds.email, password: creds.password)
    }

    func saveCredentials(email: String, password: String) {
        do {
            try keychain.save(email: email, password: password)
        } catch {
            // `save` deletes the old item before adding the new one, so a
            // failure here has already discarded any previous credentials.
            // Saying so beats a session that works now and silently demands a
            // re-login on next launch.
            loginError = "Couldn't save your credentials to the Keychain: \(error.localizedDescription)"
            return
        }
        needsLogin = false
        loginError = nil
        startupError = nil
        Task { await launch(email: email, password: password) }
    }

    /// Pandora rejected the credentials. Clear them and go back to the login
    /// screen with the reason. Previously `authFailure` was recorded on
    /// PlaybackState and read by nothing, so a wrong password left the user in
    /// a permanently blank window with no route back except Preferences →
    /// Account → Sign Out.
    private func handleAuthFailure(_ message: String) {
        guard !needsLogin else { return }
        keychain.delete()
        loginError = message
        startInvoked = false
        Task {
            await teardownPlaybackStack()
            clearPlaybackIntegrations()
            needsLogin = true
        }
    }

    private func observeAuthFailure(_ state: PlaybackState) {
        state.$authFailure
            .compactMap { $0 }
            .sink { [weak self] message in
                self?.handleAuthFailure(message)
            }
            .store(in: &snapshotSubs)
    }

    func signOut() {
        keychain.delete()
        loginError = nil
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationName)
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationId)
        SessionStore.clear()
        startupError = nil
        startInvoked = false  // allow sign-in flow to call start() again.
        Task {
            await teardownPlaybackStack()
            removeSystemObservers()
            clearPlaybackIntegrations()
            needsLogin = true
        }
    }

    /// Stop pianobar and the event bridge and drop all derived state. Shared by
    /// sign-out and by `launch`, which must not build a second stack on top of
    /// a live one.
    private func teardownPlaybackStack() async {
        supervisorWatch?.cancel()
        supervisorWatch = nil
        stationTracker?.cancel()
        stationTracker = nil
        snapshotSubs.removeAll()

        // When `keepPianobarAlive` reattached us to an existing pianobar there
        // is no PianobarProcess to stop, so `process?.stop()` was a no-op and
        // music kept playing forever after sign-out — while Preferences
        // promises "Signing out stops playback". Quit it over the FIFO and
        // clear the pidfile so the orphan isn't re-adopted next launch.
        if process == nil {
            Self.writeFifoSync("q\n", at: fifoPath)
            PianobarPidFile.clear(at: pidFilePath)
        } else {
            try? await process?.stop()
        }
        await bridge?.stop()

        playbackState = nil
        ctrl = nil
        bridge = nil
        process = nil
    }

    /// The sleep/lock observers outlive a sign-out otherwise, and keep writing
    /// `p` to a now-stale FIFO path on every sleep or screen lock.
    private func removeSystemObservers() {
        if let obs = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            willSleepObserver = nil
        }
        if let obs = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
            screenLockedObserver = nil
        }
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
            willTerminateObserver = nil
        }
    }

    func retryPlayback() {
        startupError = nil
        startInvoked = false
        Task { await start() }
    }

    func dismissStartupError() {
        startupError = nil
    }

    /// Install a one-shot observer on NSApplication.willTerminateNotification
    /// that pauses pianobar (by writing `p` to the FIFO) and persists a
    /// SessionSnapshot so the next launch can restore the UI immediately.
    /// Only runs when `keepPianobarAlive` is on — otherwise the atexit hook
    /// kills the process anyway.
    private func installTerminationHook() {
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWillTerminate()
            }
        }
    }

    /// Hermes parity: pause pianobar when the Mac sleeps OR the screen is
    /// locked, and stay paused on wake/unlock. The user has to press play to
    /// resume, matching the original "doesn't resume on wake" behavior.
    /// Gated by Prefs.Keys.pauseOnSleep.
    private func installSleepHook() {
        if let obs = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseForSystemEvent()
            }
        }

        // Screen lock comes through DistributedNotificationCenter, not
        // NSWorkspace. Fires for Cmd+Ctrl+Q, hot corners, and screensaver.
        if let obs = screenLockedObserver {
            DistributedNotificationCenter.default().removeObserver(obs)
        }
        screenLockedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pauseForSystemEvent()
            }
        }
    }

    private func pauseForSystemEvent() {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.pauseOnSleep),
              let state = playbackState,
              state.isPlaying
        else { return }
        // Only reflect the pause in the UI if pianobar actually got the
        // command, so the transport doesn't desync into a state where the
        // button does nothing.
        if Self.writeFifoSync("p\n", at: fifoPath) {
            state.setPlaying(false)
        }
    }

    private func handleWillTerminate() {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.keepPianobarAlive),
              let state = playbackState
        else {
            SessionStore.clear()
            UserDefaults.standard.set(false, forKey: Prefs.Keys.pianobarWasPaused)
            return
        }

        // Snapshot BEFORE we toggle pianobar's play state so the recorded
        // `wasPlaying` reflects the user's actual situation.
        let snapshot = SessionSnapshot(
            stations: state.stations,
            currentStation: state.currentStation,
            currentSong: state.currentSong,
            progressSeconds: state.progressSeconds,
            wasPlaying: state.isPlaying,
            savedAt: Date()
        )
        SessionStore.save(snapshot)

        if state.isPlaying {
            // Record that WE explicitly paused pianobar, and only if the write
            // actually landed. The next launch looks at this flag (not the
            // snapshot) to decide whether to toggle on attach — claiming a
            // pause that never happened made that launch send a blind toggle
            // and *stop* the music the user expected to still be playing.
            let paused = Self.writeFifoSync("p\n", at: fifoPath)
            UserDefaults.standard.set(paused, forKey: Prefs.Keys.pianobarWasPaused)
        } else {
            UserDefaults.standard.set(false, forKey: Prefs.Keys.pianobarWasPaused)
        }
    }

    /// Synchronous write of a short command directly to pianobar's FIFO.
    /// Safe to call from notification observers / terminate hooks where we
    /// can't await the PianobarCtrl actor.
    /// Returns whether the command actually reached the FIFO. Callers record
    /// state based on this: `O_NONBLOCK` open returns ENXIO when pianobar isn't
    /// reading, and the write itself can fail or come up short, so "we tried"
    /// is not the same as "pianobar is now paused".
    @discardableResult
    private static func writeFifoSync(_ command: String, at path: String) -> Bool {
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return command.withCString { ptr -> Bool in
            let len = strlen(ptr)
            let written = Darwin.write(fd, ptr, len)
            return written == len
        }
    }

    private func launch(email: String, password: String) async {
        startupError = nil
        // Tear down any integrations from a prior launch (e.g. retryPlayback)
        // before creating new ones, so we don't leak the old GlobalHotkeys
        // instance and its registered Carbon event handler.
        clearPlaybackIntegrations()
        // And tear down the process/bridge too. Without this, re-entering
        // launch() unlinks and rebinds the event socket (orphaning the previous
        // EventBridge, its fd and its accept task), re-mkfifos the control FIFO
        // so the existing pianobar becomes uncommandable, and spawns a *second*
        // pianobar — two audio streams playing different songs, only one of
        // which responds to the UI.
        await teardownPlaybackStack()
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let keepAlive = UserDefaults.standard.bool(forKey: Prefs.Keys.keepPianobarAlive)
        // The atexit hook reads this flag at process exit. Setting it here lets
        // the user toggle the pref mid-session; the next quit honors the new
        // choice.
        PianobarPIDRegistry.shared.setExitAction(keepAlive ? .keepAlive : .kill)
        installTerminationHook()
        installSleepHook()

        // Fast path: an earlier session deliberately left pianobar running.
        // Reattach to it without rewriting config or spawning a new child.
        if keepAlive, let existingPid = PianobarPidFile.existingLivePid(at: pidFilePath) {
            PianobarPIDRegistry.shared.set(existingPid)
            await attachToRunning(pid: existingPid)
            return
        }

        // Either the pref is off, or the pidfile is stale / the process died.
        // Clean up any orphan pidfile so we don't keep thinking it's alive.
        PianobarPidFile.clear(at: pidFilePath)
        // Fresh pianobar means we definitely don't need to toggle play state.
        UserDefaults.standard.set(false, forKey: Prefs.Keys.pianobarWasPaused)

        // Resolve pianobar path. Dev builds use Homebrew.
        guard let pianobarPath = resolvePianobarPath() else {
            // Falling back to a hardcoded path that resolvePianobarPath just
            // proved absent bought ~61s of silent backoff and then a generic
            // "stopped responding". Say what's actually wrong.
            startupError = "pianobar isn't installed. Install it with `brew install pianobar`, then click Retry."
            return
        }

        let eventBridgePath = PianobarCoreResources.eventBridgeScriptURL.path

        // Pianobar's event_command on this version only emits station names,
        // not the Pandora station IDs that `autostart_station` needs. Instead
        // of setting that config key, we let pianobar land at its first-run
        // "Select station:" prompt and then auto-answer it below, once the
        // stations list has been reported.
        let audioQuality = ConfigManager.AudioQuality(
            rawValue: UserDefaults.standard.string(forKey: Prefs.Keys.audioQuality) ?? "high"
        ) ?? .high
        do {
            try ConfigManager(configDir: configDir).writeConfig(
                email: email, password: password, audioQuality: audioQuality,
                eventBridgePath: eventBridgePath, fifoPath: fifoPath,
                autostartStationId: nil)
        } catch ConfigManager.Error.invalidCredentials {
            startupError = "Your Pandora email or password contains an unsupported character (such as a line break). Sign out and re-enter your credentials."
            return
        } catch {
            startupError = "Couldn't write pianobar configuration: \(error.localizedDescription)"
            return
        }
        // Clean up any legacy id we previously wrote — it was just the list
        // index and never actually worked for auto-resume.
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationId)

        // Make FIFO
        unlink(fifoPath)
        if mkfifo(fifoPath, 0o600) != 0 {
            startupError = "Couldn't create the pianobar control channel: \(String(cString: strerror(errno)))"
            return
        }

        // Start event bridge. These failures used to be swallowed, which left
        // playbackState nil and the UI spinning on "Starting…" forever with no
        // error and no Retry button.
        let b: EventBridge
        do {
            b = try EventBridge(socketPath: socketPath)
            try await b.start()
        } catch {
            startupError = "Couldn't open the pianobar event channel: \(error.localizedDescription)"
            return
        }
        bridge = b

        // Wire up state. Pre-populate with the last saved snapshot (if any) so
        // the UI isn't blank during pianobar's startup; subsequent events
        // overwrite it with fresh data.
        let state = PlaybackState(events: b.events)
        restoreSnapshotIfAny(into: state, advanceProgress: false)
        playbackState = state
        startSnapshotPersistence(state)

        // Start pianobar
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/PianobarGUI")
        let logURL = logsDir.appendingPathComponent("pianobar.log")
        let eventLogURL: URL? = UserDefaults.standard.bool(forKey: Prefs.Keys.eventDebugLog)
            ? logsDir.appendingPathComponent("events.log")
            : nil
        let proc = PianobarProcess(
            executablePath: pianobarPath,
            xdgConfigHome: appSupportDir.path,
            eventSocketPath: socketPath,
            logFileURL: logURL,
            eventDebugLogURL: eventLogURL,
            pidFilePath: pidFilePath
        )
        do {
            try await proc.start()
        } catch {
            startupError = "Couldn't start pianobar: \(error.localizedDescription)"
            return
        }
        process = proc
        watchSupervisor(proc, state: state)

        // Commands
        ctrl = PianobarCtrl(fifoPath: fifoPath)

        if let state = playbackState, let ctrl = ctrl {
            nowPlayingBridge = NowPlayingBridge(state: state, ctrl: ctrl)
            notificationPresenter = NotificationPresenter(state: state, ctrl: ctrl)
            globalHotkeys = GlobalHotkeys(state: state, ctrl: ctrl)
            trackCurrentStation(state)
            observeAuthFailure(state)
            autoResumeLastStation(state: state, ctrl: ctrl)
        }
    }

    /// Attach to a pianobar process left running by a previous app session
    /// (Prefs.Keys.keepPianobarAlive). We don't own the Process object, so
    /// there's no supervisor; commands still flow via the FIFO and events via
    /// a freshly-bound socket at the same path.
    private func attachToRunning(pid: pid_t) async {
        // Tear down any integrations from a prior launch before creating new
        // ones, so the old GlobalHotkeys instance and its Carbon event handler
        // don't leak.
        clearPlaybackIntegrations()
        // Re-create the event socket at the same path — event_bridge.sh will
        // connect there on pianobar's next event. The FIFO lives on disk and
        // still has pianobar as reader, so we just open the writer end.
        let b: EventBridge
        do {
            b = try EventBridge(socketPath: socketPath)
            try await b.start()
        } catch {
            startupError = "Couldn't reattach to the running pianobar: \(error.localizedDescription)"
            return
        }
        bridge = b

        let state = PlaybackState(events: b.events)
        let wasPaused = UserDefaults.standard.bool(forKey: Prefs.Keys.pianobarWasPaused)
        restoreSnapshotIfAny(into: state, advanceProgress: wasPaused)
        playbackState = state
        startSnapshotPersistence(state)

        ctrl = PianobarCtrl(fifoPath: fifoPath)
        // No PianobarProcess; the pid stays in the registry so ⌘Q still
        // honors the keepAlive pref.

        if let state = playbackState, let ctrl = ctrl {
            nowPlayingBridge = NowPlayingBridge(state: state, ctrl: ctrl)
            notificationPresenter = NotificationPresenter(state: state, ctrl: ctrl)
            globalHotkeys = GlobalHotkeys(state: state, ctrl: ctrl)
            trackCurrentStation(state)
            observeAuthFailure(state)
            // Only resume if WE paused pianobar in our willTerminate. Other
            // exits (SIGTERM from killall, force quit, crash) leave pianobar
            // in whatever state it was in; toggling blindly would silence it.
            if wasPaused {
                Task { try? await ctrl.togglePlay(); state.setPlaying(true) }
                UserDefaults.standard.set(false, forKey: Prefs.Keys.pianobarWasPaused)
            } else {
                // Match what's on disk: pianobar kept playing through our
                // exit, so reflect that in the UI.
                state.setPlaying(true)
            }
        }
    }

    /// Continuously snapshot the things the UI cares about. If the app is
    /// idled out of memory, killed, or just relaunched, the next launch can
    /// restore from this and avoid a blank player.
    private func startSnapshotPersistence(_ state: PlaybackState) {
        snapshotSubs.removeAll()
        Publishers.CombineLatest3(state.$stations, state.$currentSong, state.$currentStation)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak state] _, _, _ in
                guard let s = state else { return }
                // Skip writing a snapshot that would erase real data with
                // emptiness — the cache should always reflect the best info
                // we've ever seen this session.
                guard !s.stations.isEmpty || s.currentSong != nil else { return }
                let snap = SessionSnapshot(
                    stations: s.stations,
                    currentStation: s.currentStation,
                    currentSong: s.currentSong,
                    progressSeconds: s.progressSeconds,
                    wasPlaying: s.isPlaying,
                    savedAt: Date()
                )
                SessionStore.save(snap)
            }
            .store(in: &snapshotSubs)
    }

    /// Apply the latest cached snapshot so the UI isn't blank between launch
    /// and pianobar's first event. Only clobbers fields that the snapshot has;
    /// progress is reset because a fresh spawn always restarts the song.
    private func restoreSnapshotIfAny(into state: PlaybackState, advanceProgress: Bool) {
        guard let snap = SessionStore.load() else { return }
        let progress = advanceProgress
            ? min(snap.currentSong?.durationSeconds ?? 0,
                  snap.progressSeconds + snap.elapsedSinceSavedSeconds)
            : 0
        state.restoreSnapshot(
            stations: snap.stations,
            currentStation: snap.currentStation,
            currentSong: snap.currentSong,
            progressSeconds: progress,
            isPlaying: false
        )
    }

    /// Mirror the current station name into defaults so the next launch can
    /// auto-resume it. Driven by the publisher rather than by a 2s polling loop
    /// that ran for the app's whole lifetime and churned `UserDefaults` (which
    /// in turn forced a global hotkey re-registration on every write).
    private func trackCurrentStation(_ state: PlaybackState) {
        stationTracker?.cancel()
        stationTracker = nil
        state.$currentStation
            .compactMap { $0?.name }
            .removeDuplicates()
            .sink { name in
                UserDefaults.standard.set(name, forKey: Prefs.Keys.lastStationName)
            }
            .store(in: &snapshotSubs)
    }

    /// After pianobar sends its stations list, look up the saved station by
    /// name and tell pianobar to select it. This bypasses the first-run
    /// "Select station:" prompt without needing a real Pandora station id.
    private func autoResumeLastStation(state: PlaybackState, ctrl: PianobarCtrl) {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.autostartLastStation),
              let savedName = UserDefaults.standard.string(forKey: Prefs.Keys.lastStationName),
              !savedName.isEmpty
        else { return }

        Task { @MainActor [weak state] in
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let s = state, !s.stations.isEmpty {
                    // pianobar has already started playing on its own (e.g. a
                    // reattached session left it in runtime mode) — nothing to
                    // do. Must test `hasLiveSong`, not `currentSong != nil`:
                    // restoreSnapshotIfAny runs before this and populates
                    // currentSong from the *previous* session's cache, so the
                    // old check was always true and auto-resume silently never
                    // fired after the first-ever launch.
                    if s.hasLiveSong { return }
                    if let idx = s.stations.firstIndex(where: { $0.name == savedName }) {
                        try? await ctrl.selectStationAtPrompt(index: idx)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func watchSupervisor(_ proc: PianobarProcess, state: PlaybackState) {
        supervisorWatch?.cancel()
        supervisorWatch = Task { @MainActor [weak self, weak state] in
            for await _ in proc.supervisorFailures {
                guard let self else { return }
                let message = "pianobar stopped responding. Click Retry to reconnect."
                state?.setErrorBanner(message)
                self.startupError = message
                self.playbackState = nil
                self.ctrl = nil
                self.process = nil
                self.clearPlaybackIntegrations()
                await self.bridge?.stop()
                self.bridge = nil
                self.startInvoked = false
                break
            }
        }
    }

    private func clearPlaybackIntegrations() {
        nowPlayingBridge?.invalidate()
        nowPlayingBridge = nil
        notificationPresenter = nil
        globalHotkeys?.invalidate()
        globalHotkeys = nil
    }

    private func resolvePianobarPath() -> String? {
        for candidate in ["/opt/homebrew/bin/pianobar", "/usr/local/bin/pianobar"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
