import XCTest
@testable import PianobarCore

/// The control FIFO is the app's only path to pianobar, so its failure modes
/// decide whether the transport buttons keep working.
final class PianobarCtrlRecoveryTests: XCTestCase {
    private var fifoURL: URL!

    override func setUpWithError() throws {
        fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString)")
        XCTAssertEqual(mkfifo(fifoURL.path, 0o600), 0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fifoURL)
    }

    /// Opening a FIFO O_WRONLY blocks until a reader appears. Because
    /// PianobarCtrl is an actor, one such call used to wedge every later
    /// command behind it — the whole transport went dead until a force-quit.
    /// It must now fail in bounded time instead.
    func testWriteWithNoReaderFailsInsteadOfHangingForever() async throws {
        let ctrl = PianobarCtrl(fifoPath: fifoURL.path)
        let started = Date()
        do {
            try await ctrl.play()
            XCTFail("expected a failure with no reader attached")
        } catch {
            // expected
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 10, "open must not block indefinitely")
    }

    /// A later command must still work after an earlier one failed. The failed
    /// write used to leave a stale FileHandle cached, so every subsequent
    /// command failed forever — even after the supervisor restarted pianobar
    /// and recreated the FIFO.
    func testControlChannelRecoversAfterAFailedWrite() async throws {
        let ctrl = PianobarCtrl(fifoPath: fifoURL.path)

        // No reader yet: this fails.
        do {
            try await ctrl.play()
            XCTFail("expected a failure with no reader attached")
        } catch {}

        // Reader appears, as it would when the supervisor respawns pianobar.
        let exp = expectation(description: "reader got the command")
        let url = fifoURL!
        let reader = Task.detached(priority: .userInitiated) { () -> String in
            let handle = try FileHandle(forReadingFrom: url)
            var data = Data()
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                data.append(chunk)
            }
            try? handle.close()
            exp.fulfill()
            return String(data: data, encoding: .utf8) ?? ""
        }

        try await ctrl.next()
        await ctrl.close()

        await fulfillment(of: [exp], timeout: 5)
        let received = try await reader.value
        XCTAssertEqual(received, "n\n", "the channel must recover, not stay dead")
    }
}
