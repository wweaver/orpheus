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
        try await ctrl.setVolume(75)
        await ctrl.close()

        await fulfillment(of: [exp], timeout: 2)
        let result = try await reader.value
        // Exact byte sequence pianobar expects.
        XCTAssertEqual(result, "p\nn\n+\n-\nt\nb\ns3\n(75\n")
    }
}
