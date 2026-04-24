import Foundation
import SwiftUI
import Darwin
import AppKit
import PianobarCore

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var needsLogin = false
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

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PianobarGUI")
    }
    private var configDir: URL { appSupportDir.appendingPathComponent("pianobar") }
    private var socketPath: String { appSupportDir.appendingPathComponent("events.sock").path }
    private var fifoPath:   String { configDir.appendingPathComponent("ctl").path }
    private var pidFilePath: String { appSupportDir.appendingPathComponent("pianobar.pid").path }

    func start() async {
        guard let creds = keychain.load() else {
            needsLogin = true
            return
        }
        await launch(email: creds.email, password: creds.password)
    }

    func saveCredentials(email: String, password: String) {
        try? keychain.save(email: email, password: password)
        needsLogin = false
        Task { await launch(email: email, password: password) }
    }

    func signOut() {
        keychain.delete()
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationName)
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationId)
        stationTracker?.cancel()
        stationTracker = nil
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
            self?.handleWillTerminate()
        }
    }

    private func handleWillTerminate() {
        guard UserDefaults.standard.bool(forKey: Prefs.Keys.keepPianobarAlive),
              let state = playbackState
        else {
            SessionStore.clear()
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
            Self.writeFifoSync("p\n", at: fifoPath)
        }
    }

    /// Synchronous write of a short command directly to pianobar's FIFO.
    /// Safe to call from notification observers / terminate hooks where we
    /// can't await the PianobarCtrl actor.
    private static func writeFifoSync(_ command: String, at path: String) {
        let fd = open(path, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = command.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr))
        }
    }

    private func launch(email: String, password: String) async {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        let keepAlive = UserDefaults.standard.bool(forKey: Prefs.Keys.keepPianobarAlive)
        // The atexit hook reads this flag at process exit. Setting it here lets
        // the user toggle the pref mid-session; the next quit honors the new
        // choice.
        PianobarPIDRegistry.shared.setExitAction(keepAlive ? .keepAlive : .kill)
        installTerminationHook()

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
        // And forget any saved session — it only makes sense when we reattach.
        SessionStore.clear()

        // Resolve pianobar path. Dev builds use Homebrew.
        let pianobarPath = resolvePianobarPath() ?? "/opt/homebrew/bin/pianobar"

        let eventBridgePath = PianobarCoreResources.eventBridgeScriptURL.path

        // Pianobar's event_command on this version only emits station names,
        // not the Pandora station IDs that `autostart_station` needs. Instead
        // of setting that config key, we let pianobar land at its first-run
        // "Select station:" prompt and then auto-answer it below, once the
        // stations list has been reported.
        let audioQuality = ConfigManager.AudioQuality(
            rawValue: UserDefaults.standard.string(forKey: Prefs.Keys.audioQuality) ?? "high"
        ) ?? .high
        try? ConfigManager(configDir: configDir).writeConfig(
            email: email, password: password, audioQuality: audioQuality,
            eventBridgePath: eventBridgePath, fifoPath: fifoPath,
            autostartStationId: nil)
        // Clean up any legacy id we previously wrote — it was just the list
        // index and never actually worked for auto-resume.
        UserDefaults.standard.removeObject(forKey: Prefs.Keys.lastStationId)

        // Make FIFO
        unlink(fifoPath)
        _ = mkfifo(fifoPath, 0o600)

        // Start event bridge
        guard let b = try? EventBridge(socketPath: socketPath) else { return }
        try? await b.start()
        bridge = b

        // Wire up state
        let state = PlaybackState(events: b.events)
        playbackState = state

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
        try? await proc.start()
        process = proc
        watchSupervisor(proc, state: state)

        // Commands
        ctrl = PianobarCtrl(fifoPath: fifoPath)

        if let state = playbackState, let ctrl = ctrl {
            nowPlayingBridge = NowPlayingBridge(state: state, ctrl: ctrl)
            notificationPresenter = NotificationPresenter(state: state, ctrl: ctrl)
            globalHotkeys = GlobalHotkeys(state: state, ctrl: ctrl)
            trackCurrentStation(state)
            autoResumeLastStation(state: state, ctrl: ctrl)
        }
    }

    /// Attach to a pianobar process left running by a previous app session
    /// (Prefs.Keys.keepPianobarAlive). We don't own the Process object, so
    /// there's no supervisor; commands still flow via the FIFO and events via
    /// a freshly-bound socket at the same path.
    private func attachToRunning(pid: pid_t) async {
        // Re-create the event socket at the same path — event_bridge.sh will
        // connect there on pianobar's next event. The FIFO lives on disk and
        // still has pianobar as reader, so we just open the writer end.
        guard let b = try? EventBridge(socketPath: socketPath) else { return }
        try? await b.start()
        bridge = b

        let state = PlaybackState(events: b.events)
        playbackState = state

        // Rehydrate from the snapshot taken at last quit so the UI isn't
        // blank while we wait for pianobar's next event.
        let snapshot = SessionStore.load()
        if let snap = snapshot {
            let advancedProgress = snap.wasPlaying
                ? min((snap.currentSong?.durationSeconds ?? 0),
                      snap.progressSeconds + snap.elapsedSinceSavedSeconds)
                : snap.progressSeconds
            state.restoreSnapshot(
                stations: snap.stations,
                currentStation: snap.currentStation,
                currentSong: snap.currentSong,
                progressSeconds: advancedProgress,
                isPlaying: false  // pianobar is currently paused; we'll flip below.
            )
        }

        ctrl = PianobarCtrl(fifoPath: fifoPath)
        // Reach across: no PianobarProcess, so no supervisor. The pid is
        // tracked by the registry so ⌘Q still honors the keepAlive pref.

        if let state = playbackState, let ctrl = ctrl {
            nowPlayingBridge = NowPlayingBridge(state: state, ctrl: ctrl)
            notificationPresenter = NotificationPresenter(state: state, ctrl: ctrl)
            globalHotkeys = GlobalHotkeys(state: state, ctrl: ctrl)
            trackCurrentStation(state)
            // Resume playback if we paused it on the prior quit. Pianobar's
            // `p` is a toggle, so one press flips paused → playing.
            if snapshot?.wasPlaying == true {
                Task { try? await ctrl.togglePlay(); state.setPlaying(true) }
            }
        }

        // Consume the snapshot so we don't double-apply it next time.
        SessionStore.clear()
    }

    private func trackCurrentStation(_ state: PlaybackState) {
        stationTracker?.cancel()
        stationTracker = Task { @MainActor [weak state] in
            var lastSaved: String?
            while !Task.isCancelled {
                let name = state?.currentStation?.name
                if let name, name != lastSaved {
                    UserDefaults.standard.set(name, forKey: Prefs.Keys.lastStationName)
                    lastSaved = name
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
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
                    // Already playing a song (e.g. a previous session left
                    // pianobar in runtime mode somehow) — nothing to do.
                    if s.currentSong != nil { return }
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
                state?.setErrorBanner("pianobar stopped responding. Click Retry to reconnect.")
                self?.playbackState = nil  // force UI to show a "Starting…" or retry state
                break
            }
        }
    }

    private func resolvePianobarPath() -> String? {
        for candidate in ["/opt/homebrew/bin/pianobar", "/usr/local/bin/pianobar"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
