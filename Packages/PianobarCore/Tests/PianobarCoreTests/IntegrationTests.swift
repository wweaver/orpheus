import XCTest
@testable import PianobarCore

@MainActor
final class IntegrationTests: XCTestCase {
    func testLoginStationsPlayLoveSkipSwitchQuit() async throws {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let socketPath = work.appendingPathComponent("s.sock").path
        let cfgDir = work.appendingPathComponent("pianobar")
        let fifoPath = cfgDir.appendingPathComponent("ctl").path
        let scriptPath = PianobarCoreResources.eventBridgeScriptURL.path

        try ConfigManager(configDir: cfgDir).writeConfig(
            email: "a@b.com", password: "p", audioQuality: .low,
            eventBridgePath: scriptPath, fifoPath: fifoPath)
        _ = mkfifo(fifoPath, 0o600)

        let bridge = try EventBridge(socketPath: socketPath)
        try await bridge.start()
        defer { Task { await bridge.stop() } }

        let state = PlaybackState(events: bridge.events)

        let mockURL = Bundle.module.url(forResource: "mock_pianobar",
                                        withExtension: "sh",
                                        subdirectory: "Fixtures")!
        let proc = PianobarProcess(
            executablePath: mockURL.path,
            xdgConfigHome: work.path,
            eventSocketPath: socketPath
        )
        try await proc.start()

        let ctrl = PianobarCtrl(fifoPath: fifoPath)

        try await waitUntil { state.currentSong?.title == "Song1" }
        XCTAssertEqual(state.stations.map(\.name), ["Radio A", "Radio B"])

        try await ctrl.love()
        try await waitUntil { state.currentSong?.rating == .loved }

        try await ctrl.next()
        try await waitUntil { state.currentSong?.title == "Song2" }

        try await ctrl.switchStation(index: 1)
        try await waitUntil {
            state.currentSong?.stationName == "Radio B" &&
            state.currentSong?.title == "NewSong"
        }

        try await ctrl.quit()
        try await proc.stop()
    }

    private func waitUntil(timeout: Double = 3,
                           _ cond: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition never became true")
    }
}
