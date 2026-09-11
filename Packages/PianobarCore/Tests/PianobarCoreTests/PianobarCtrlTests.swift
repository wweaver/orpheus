import XCTest
@testable import PianobarCore

final class PianobarCtrlTests: XCTestCase {
    private var fifoURL: URL!

    override func setUpWithError() throws {
        fifoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-\(UUID().uuidString)")
        let rc = mkfifo(fifoURL.path, 0o600)
        XCTAssertEqual(rc, 0, "mkfifo failed: \(String(cString: strerror(errno)))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fifoURL)
    }

    private func readAllBytes(_ expectation: XCTestExpectation) -> Task<String, Error> {
        let url = fifoURL!
        return Task.detached(priority: .userInitiated) {
            // Open in a background task and read until the writer closes.
            let handle = try FileHandle(forReadingFrom: url)
            var data = Data()
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                data.append(chunk)
            }
            try? handle.close()
            expectation.fulfill()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    func testCommandBytes() async throws {
        let exp = expectation(description: "reader done")
        let reader = readAllBytes(exp)

        let ctrl = PianobarCtrl(fifoPath: fifoURL.path)
        try await ctrl.play()
        try await ctrl.next()
        try await ctrl.love()
        try await ctrl.ban()
        try await ctrl.tired()
        try await ctrl.bookmarkSong()
        try await ctrl.switchStation(index: 3)
        await ctrl.close()

        await fulfillment(of: [exp], timeout: 2)
        let result = try await reader.value
        // Exact byte sequence pianobar expects. There is no volume command:
        // pianobar's FIFO has only relative steps, so the app drives macOS
        // output volume directly instead.
        XCTAssertEqual(result, "p\nn\n+\n-\nt\nb\ns3\n")
    }

    /// pianobar reads a command as a single character and then reads the rest
    /// of that same line as the answer to whatever prompt the command opens.
    /// Putting the answer on its own line means the newline gets consumed as
    /// the answer instead — which is how `d\n` silently declined
    /// `Really delete "..."? [yN]` and deleted nothing.
    func testPromptAnsweringCommandsKeepTheAnswerOnTheCommandLine() async throws {
        let exp = expectation(description: "reader done")
        let reader = readAllBytes(exp)

        let ctrl = PianobarCtrl(fifoPath: fifoURL.path)
        try await ctrl.deleteStation()
        try await ctrl.renameStation("Chill Radio")
        try await ctrl.createStationFromSearch("Bon Iver")
        await ctrl.close()

        await fulfillment(of: [exp], timeout: 2)
        let result = try await reader.value
        XCTAssertEqual(result, """
        dy
        rChill Radio
        cs
        Bon Iver
        0

        """)
    }
}
