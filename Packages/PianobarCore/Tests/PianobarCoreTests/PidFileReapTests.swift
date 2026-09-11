import XCTest
@testable import PianobarCore

/// `reapOrphan` kills a process, so the identity check in front of it is the
/// part that matters: pids are recycled, and killing a stranger's process
/// because it inherited the number would be much worse than leaking an orphan.
final class PidFileReapTests: XCTestCase {
    private var workDir: URL!
    private var pidPath: String { workDir.appendingPathComponent("pianobar.pid").path }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Spawns a long-running process and returns it.
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testReapsAProcessMatchingTheExpectedExecutable() throws {
        let sleeper = try spawnSleeper()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        PianobarPidFile.write(sleeper.processIdentifier, to: pidPath)

        let reaped = PianobarPidFile.reapOrphan(at: pidPath, expecting: "/bin/sleep")

        XCTAssertTrue(reaped)
        // Give the signal a moment to land.
        let deadline = Date().addingTimeInterval(3)
        while sleeper.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(sleeper.isRunning, "the orphan should have been killed")
        XCTAssertNil(PianobarPidFile.read(at: pidPath), "pidfile should be cleared")
    }

    func testDoesNotKillAProcessThatIsNotTheExpectedExecutable() throws {
        // Simulates a recycled pid: the file points at a live process, but not
        // at pianobar.
        let bystander = try spawnSleeper()
        defer { if bystander.isRunning { bystander.terminate() } }
        PianobarPidFile.write(bystander.processIdentifier, to: pidPath)

        let reaped = PianobarPidFile.reapOrphan(
            at: pidPath, expecting: "/opt/homebrew/bin/pianobar")

        XCTAssertFalse(reaped)
        usleep(300_000)
        XCTAssertTrue(bystander.isRunning, "an unrelated process must be left alone")
        XCTAssertNil(PianobarPidFile.read(at: pidPath), "stale pidfile should still be cleared")
    }

    func testStalePidFileIsJustCleared() throws {
        let sleeper = try spawnSleeper()
        let pid = sleeper.processIdentifier
        sleeper.terminate()
        sleeper.waitUntilExit()
        PianobarPidFile.write(pid, to: pidPath)

        XCTAssertFalse(PianobarPidFile.reapOrphan(at: pidPath, expecting: "/bin/sleep"))
        XCTAssertNil(PianobarPidFile.read(at: pidPath))
    }

    /// The real-world case this got wrong: Homebrew installs
    /// `/opt/homebrew/bin/pianobar` as a symlink into `Cellar/`, and
    /// `proc_pidpath` reports the *resolved* path. Comparing raw strings meant
    /// the orphan was never recognised and never killed.
    func testMatchesThroughASymlinkedLaunchPath() throws {
        let link = workDir.appendingPathComponent("sleep-link").path
        try FileManager.default.createSymbolicLink(
            atPath: link, withDestinationPath: "/bin/sleep")

        let sleeper = try spawnSleeper()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        PianobarPidFile.write(sleeper.processIdentifier, to: pidPath)

        // Launched as /bin/sleep, but we only know it by the symlink path.
        XCTAssertTrue(PianobarPidFile.reapOrphan(at: pidPath, expecting: link))

        let deadline = Date().addingTimeInterval(3)
        while sleeper.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(sleeper.isRunning)
    }

    func testExecutablePathResolvesForALiveProcess() throws {
        let sleeper = try spawnSleeper()
        defer { if sleeper.isRunning { sleeper.terminate() } }
        XCTAssertEqual(PianobarPidFile.executablePath(of: sleeper.processIdentifier), "/bin/sleep")
    }
}
