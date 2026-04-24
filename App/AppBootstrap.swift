import Foundation
import SwiftUI
import PianobarCore

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var needsLogin = false
    @Published private(set) var playbackState: PlaybackState?
    @Published private(set) var ctrl: PianobarCtrl?

    private let keychain = KeychainStore(service: "org.pianobar-gui.PianobarGUI.pandora")
    private var bridge: EventBridge?
    private var process: PianobarProcess?

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PianobarGUI")
    }
    private var configDir: URL { appSupportDir.appendingPathComponent("pianobar") }
    private var socketPath: String { appSupportDir.appendingPathComponent("events.sock").path }
    private var fifoPath:   String { configDir.appendingPathComponent("ctl").path }

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

    private func launch(email: String, password: String) async {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Resolve pianobar path. Dev builds use Homebrew.
        let pianobarPath = resolvePianobarPath() ?? "/opt/homebrew/bin/pianobar"

        let eventBridgePath = PianobarCoreResources.eventBridgeScriptURL.path

        // Write config
        try? ConfigManager(configDir: configDir).writeConfig(
            email: email, password: password, audioQuality: .high,
            eventBridgePath: eventBridgePath, fifoPath: fifoPath)

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
        let proc = PianobarProcess(
            executablePath: pianobarPath,
            xdgConfigHome: appSupportDir.path,
            eventSocketPath: socketPath
        )
        try? await proc.start()
        process = proc

        // Commands
        ctrl = PianobarCtrl(fifoPath: fifoPath)
    }

    private func resolvePianobarPath() -> String? {
        for candidate in ["/opt/homebrew/bin/pianobar", "/usr/local/bin/pianobar"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}
