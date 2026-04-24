import XCTest
@testable import PianobarCore

final class PianobarProcessTests: XCTestCase {
    private var workDir: URL!
    private var socketPath: String!
    private var bridge: EventBridge!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        socketPath = workDir.appendingPathComponent("events.sock").path

        let cfgDir = workDir.appendingPathComponent("pianobar")
        let fifoPath = cfgDir.appendingPathComponent("ctl").path

        try ConfigManager(configDir: cfgDir).writeConfig(
            email: "a@b.com", password: "p", audioQuality: .low,
            eventBridgePath: PianobarCoreResources.eventBridgeScriptURL.path,
            fifoPath: fifoPath)

        // Create the FIFO the supervisor expects pianobar to read from.
        _ = mkfifo(fifoPath, 0o600)

        bridge = try EventBridge(socketPath: socketPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    func testStartsMockAndReceivesLoginEvent() async throws {
        try await bridge.start()

        let mockURL = Bundle.module.url(forResource: "mock_pianobar",
                                        withExtension: "sh",
                                        subdirectory: "Fixtures")!
        let proc = PianobarProcess(
            executablePath: mockURL.path,
            xdgConfigHome: workDir.path,
            eventSocketPath: socketPath
        )
        try await proc.start()

        var got: PianobarEvent?
        for await e in bridge.events { got = e; break }
        XCTAssertEqual(got, .userLogin(success: true, message: "OK"))

        try await proc.stop()
        await bridge.stop()
    }
}
