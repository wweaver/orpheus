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
        let finalState = await proc.state
        XCTAssertEqual(finalState, .crashed)
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
        let runningState = await proc.state
        XCTAssertEqual(runningState, .running)
        try await proc.stop()
    }
}
