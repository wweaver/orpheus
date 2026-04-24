import XCTest
@testable import PianobarCore

final class EventBridgeTests: XCTestCase {
    private var socketPath: String!

    override func setUpWithError() throws {
        socketPath = NSTemporaryDirectory() + "pgui-\(UUID().uuidString).sock"
    }

    override func tearDownWithError() throws {
        unlink(socketPath)
    }

    /// Invokes event_bridge.sh the way pianobar would.
    private func invokeBridge(event: String, payload: String) throws {
        // The script lives in the main-target resource bundle; use the public helper.
        let scriptPath = PianobarCoreResources.eventBridgeScriptURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptPath, event]
        p.environment = ["PIANOBAR_GUI_SOCK": socketPath]
        let stdin = Pipe()
        p.standardInput = stdin
        try p.run()
        stdin.fileHandleForWriting.write(payload.data(using: .utf8)!)
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
    }

    func testReceivesAndParsesOneEvent() async throws {
        let bridge = try EventBridge(socketPath: socketPath)
        try await bridge.start()

        let received = Task { () -> PianobarEvent? in
            for await e in bridge.events { return e }
            return nil
        }

        // Small delay to ensure accept() is ready. 20ms is enough locally.
        try await Task.sleep(nanoseconds: 20_000_000)

        try invokeBridge(event: "songfinish", payload: "")

        let event = try await withTimeout(seconds: 2) { await received.value }
        XCTAssertEqual(event, .songFinish)
        await bridge.stop()
    }

    // Generic helper; define inline so tests stay self-contained.
    private func withTimeout<T: Sendable>(
        seconds: Double, _ op: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NSError(domain: "timeout", code: 0)
            }
            let result = try await g.next()!
            g.cancelAll()
            return result
        }
    }
}
