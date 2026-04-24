import XCTest
@testable import PianobarCore

final class KeychainStoreTests: XCTestCase {
    // Use a unique service name per run so tests don't clash with real creds.
    private func store() -> KeychainStore {
        KeychainStore(service: "org.pianobar-gui.tests.\(UUID().uuidString)")
    }

    func testRoundTrip() throws {
        let s = store()
        defer { s.delete() }

        try s.save(email: "user@example.com", password: "hunter2")
        let loaded = s.load()
        XCTAssertEqual(loaded?.email, "user@example.com")
        XCTAssertEqual(loaded?.password, "hunter2")
    }

    func testLoadWhenEmpty() {
        XCTAssertNil(store().load())
    }

    func testDelete() throws {
        let s = store()
        try s.save(email: "a@b.com", password: "p")
        s.delete()
        XCTAssertNil(s.load())
    }

    func testSaveOverwrites() throws {
        let s = store()
        defer { s.delete() }
        try s.save(email: "a@b.com", password: "first")
        try s.save(email: "a@b.com", password: "second")
        XCTAssertEqual(s.load()?.password, "second")
    }
}
