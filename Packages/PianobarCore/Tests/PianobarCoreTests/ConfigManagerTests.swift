import XCTest
@testable import PianobarCore

final class ConfigManagerTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testWritesConfigWithExpectedKeys() throws {
        let mgr = ConfigManager(configDir: tmp)
        try mgr.writeConfig(
            email: "user@example.com",
            password: "hunter2",
            audioQuality: .high,
            eventBridgePath: tmp.appendingPathComponent("event_bridge.sh").path,
            fifoPath: tmp.appendingPathComponent("ctl").path
        )
        let contents = try String(contentsOf: tmp.appendingPathComponent("config"))
        XCTAssertTrue(contents.contains("user = user@example.com"))
        XCTAssertTrue(contents.contains("password = hunter2"))
        XCTAssertTrue(contents.contains("audio_quality = high"))
        XCTAssertTrue(contents.contains("event_command = \(tmp.appendingPathComponent("event_bridge.sh").path)"))
        XCTAssertTrue(contents.contains("fifo = \(tmp.appendingPathComponent("ctl").path)"))
    }

    func testConfigFileHas0600Permissions() throws {
        let mgr = ConfigManager(configDir: tmp)
        try mgr.writeConfig(email: "a@b.com", password: "p",
                            audioQuality: .medium,
                            eventBridgePath: "/tmp/x", fifoPath: "/tmp/y")
        let attrs = try FileManager.default.attributesOfItem(
            atPath: tmp.appendingPathComponent("config").path)
        let perms = attrs[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
    }

    func testCreatesDirectoryIfMissing() throws {
        let nested = tmp.appendingPathComponent("newdir")
        let mgr = ConfigManager(configDir: nested)
        try mgr.writeConfig(email: "a@b.com", password: "p",
                            audioQuality: .low,
                            eventBridgePath: "/tmp/x", fifoPath: "/tmp/y")
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("config").path))
    }

    func testAutostartStationIncludedWhenProvided() throws {
        let mgr = ConfigManager(configDir: tmp)
        try mgr.writeConfig(email: "a@b.com", password: "p",
                            audioQuality: .high,
                            eventBridgePath: "/tmp/x", fifoPath: "/tmp/y",
                            autostartStationId: "4242")
        let contents = try String(contentsOf: tmp.appendingPathComponent("config"))
        XCTAssertTrue(contents.contains("autostart_station = 4242"))
    }

    func testAutostartStationOmittedWhenNil() throws {
        let mgr = ConfigManager(configDir: tmp)
        try mgr.writeConfig(email: "a@b.com", password: "p",
                            audioQuality: .high,
                            eventBridgePath: "/tmp/x", fifoPath: "/tmp/y",
                            autostartStationId: nil)
        let contents = try String(contentsOf: tmp.appendingPathComponent("config"))
        XCTAssertFalse(contents.contains("autostart_station"))
    }
}
