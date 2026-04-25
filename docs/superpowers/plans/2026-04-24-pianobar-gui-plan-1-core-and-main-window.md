# Orpheus Plan 1 — Core Library + Main Window

> Drafted under the working title PianobarGUI; ships as Orpheus.
> Package and source-tree names retain "PianobarGUI" / "PianobarCore".

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a working macOS Pandora client with a main window — login, station switching, play/pause/skip/thumbs, album art, progress. Requires `brew install pianobar` on the dev machine; native menu bar integration and packaging come in Plans 2–3.

**Architecture:** Two-module Swift project. A **SwiftPM package** (`PianobarCore`) contains all testable logic: event parser, FIFO writer, event socket, process supervisor, Keychain, config writer, playback state. A thin **Xcode app target** (`PianobarGUI`) depends on the package and contains only SwiftUI views and app-level wiring. Project files are generated from `project.yml` via `xcodegen` so nothing in the `.xcodeproj` is hand-edited.

**Tech Stack:** Swift 5.9+, SwiftUI, SwiftPM, XCTest, xcodegen, pianobar 2022.04.01+.

---

## Prerequisites

Before starting Task 1, confirm the dev machine has:

```bash
xcode-select -p          # Xcode command-line tools present
brew install pianobar xcodegen
xcrun swift --version    # 5.9+
```

The plan assumes macOS 13 or later and a paid Apple developer account is **not** required for Plan 1 (only for Plan 3 notarization).

## File Structure

Created during this plan:

```
PianobarGUI/
├── .gitignore
├── README.md
├── project.yml                                       # xcodegen input
├── PianobarGUI.xcodeproj                             # generated, committed
├── App/                                              # Xcode app target sources
│   ├── PianobarGUIApp.swift
│   ├── AppBootstrap.swift
│   └── Views/
│       ├── LoginView.swift
│       ├── MainWindowView.swift
│       ├── StationsSidebarView.swift
│       ├── NowPlayingView.swift
│       └── ErrorBanner.swift
└── Packages/
    └── PianobarCore/
        ├── Package.swift
        ├── Sources/PianobarCore/
        │   ├── Models/
        │   │   ├── SongInfo.swift
        │   │   ├── Station.swift
        │   │   └── Rating.swift
        │   ├── Events/
        │   │   ├── PianobarEvent.swift
        │   │   └── EventParser.swift
        │   ├── Pianobar/
        │   │   ├── PianobarCtrl.swift
        │   │   ├── EventBridge.swift
        │   │   ├── PianobarProcess.swift
        │   │   └── ConfigManager.swift
        │   ├── State/
        │   │   └── PlaybackState.swift
        │   ├── System/
        │   │   └── KeychainStore.swift
        │   └── Resources/
        │       └── event_bridge.sh
        └── Tests/PianobarCoreTests/
            ├── EventParserTests.swift
            ├── KeychainStoreTests.swift
            ├── ConfigManagerTests.swift
            ├── PianobarCtrlTests.swift
            ├── EventBridgeTests.swift
            ├── PianobarProcessTests.swift
            ├── PlaybackStateTests.swift
            ├── IntegrationTests.swift
            └── Fixtures/
                ├── mock_pianobar.sh
                └── event_payloads/
                    ├── songstart.txt
                    ├── usergetstations.txt
                    ├── userlogin_ok.txt
                    └── userlogin_fail.txt
```

Each file has a single responsibility. Tests live next to the code they cover. The SwiftPM package exposes only what the app needs (see `PackageExports` at the top of each module if additional access is required).

---

### Task 1: Bootstrap repo and SwiftPM package

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `project.yml`
- Create: `Packages/PianobarCore/Package.swift`
- Create: `Packages/PianobarCore/Sources/PianobarCore/PianobarCore.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/SmokeTest.swift`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
# Xcode
build/
DerivedData/
*.pbxuser
!default.pbxuser
*.xcworkspace/xcuserdata
*.xcodeproj/xcuserdata
*.xcodeproj/project.xcworkspace/xcuserdata

# SwiftPM
.build/
.swiftpm/
Package.resolved

# macOS
.DS_Store

# Logs
*.log
```

- [ ] **Step 2: Write `project.yml` for xcodegen**

```yaml
name: PianobarGUI
options:
  deploymentTarget:
    macOS: "13.0"
  createIntermediateGroups: true
packages:
  PianobarCore:
    path: Packages/PianobarCore
targets:
  PianobarGUI:
    type: application
    platform: macOS
    sources:
      - App
    dependencies:
      - package: PianobarCore
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: PianobarGUI
        LSApplicationCategoryType: public.app-category.music
        LSMinimumSystemVersion: "13.0"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: org.pianobar-gui.PianobarGUI
        GENERATE_INFOPLIST_FILE: YES
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        DEVELOPMENT_TEAM: ""
        SWIFT_VERSION: 5.9
        MACOSX_DEPLOYMENT_TARGET: "13.0"
```

- [ ] **Step 3: Write `Packages/PianobarCore/Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PianobarCore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PianobarCore", targets: ["PianobarCore"]),
    ],
    targets: [
        .target(
            name: "PianobarCore",
            resources: [.copy("Resources/event_bridge.sh")]
        ),
        .testTarget(
            name: "PianobarCoreTests",
            dependencies: ["PianobarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
```

- [ ] **Step 4: Write a placeholder source and smoke test**

`Packages/PianobarCore/Sources/PianobarCore/PianobarCore.swift`:

```swift
import Foundation

public enum PianobarCore {
    public static let version = "0.1.0"
}

/// Exposes package-bundle resources to dependent targets. `Bundle.module`
/// is generated by SwiftPM but is internal to the package; this helper
/// re-exports what the app target needs.
public enum PianobarCoreResources {
    public static var eventBridgeScriptURL: URL {
        guard let url = Bundle.module.url(
            forResource: "event_bridge", withExtension: "sh")
        else {
            fatalError("event_bridge.sh missing from PianobarCore resources")
        }
        return url
    }
}
```

`Packages/PianobarCore/Tests/PianobarCoreTests/SmokeTest.swift`:

```swift
import XCTest
@testable import PianobarCore

final class SmokeTest: XCTestCase {
    func testVersionExists() {
        XCTAssertEqual(PianobarCore.version, "0.1.0")
    }
}
```

- [ ] **Step 5: Write `README.md`**

```markdown
# PianobarGUI

Native macOS Pandora client built on [pianobar](https://github.com/promyloph/pianobar).

## Development

Prerequisites:

    brew install pianobar xcodegen

Generate the Xcode project and run tests:

    xcodegen generate
    cd Packages/PianobarCore && swift test

Open `PianobarGUI.xcodeproj` in Xcode to build and run the app.
```

- [ ] **Step 6: Generate the Xcode project and verify it builds**

Run:
```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: final line contains `BUILD SUCCEEDED`.

- [ ] **Step 7: Run the package tests**

Run:
```bash
cd Packages/PianobarCore && swift test
```

Expected: `Test Suite 'All tests' passed`, 1 test.

- [ ] **Step 8: Commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add .gitignore README.md project.yml PianobarGUI.xcodeproj Packages/
git commit -m "Scaffold PianobarGUI app and PianobarCore package"
```

---

### Task 2: Core model types

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Models/Rating.swift`
- Create: `Packages/PianobarCore/Sources/PianobarCore/Models/SongInfo.swift`
- Create: `Packages/PianobarCore/Sources/PianobarCore/Models/Station.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write failing tests in `ModelsTests.swift`**

```swift
import XCTest
@testable import PianobarCore

final class ModelsTests: XCTestCase {
    func testRatingFromPianobarInt() {
        XCTAssertEqual(Rating(pianobarInt: 0), .unrated)
        XCTAssertEqual(Rating(pianobarInt: 1), .loved)
        XCTAssertEqual(Rating(pianobarInt: -1), .banned)
        XCTAssertEqual(Rating(pianobarInt: 99), .unrated) // unknown → unrated
    }

    func testSongInfoEquality() {
        let a = SongInfo(title: "Shivers", artist: "Ed Sheeran", album: "=",
                         coverArtURL: nil, durationSeconds: 228, rating: .unrated,
                         detailURL: nil, stationName: "Imagine Dragons Radio")
        let b = a
        XCTAssertEqual(a, b)
    }

    func testStationEquality() {
        let s = Station(id: "4", name: "Bad Bunny 360° Radio", isQuickMix: false)
        XCTAssertEqual(s, Station(id: "4", name: "Bad Bunny 360° Radio", isQuickMix: false))
        XCTAssertNotEqual(s, Station(id: "5", name: "Bad Bunny 360° Radio", isQuickMix: false))
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `cd Packages/PianobarCore && swift test --filter ModelsTests`
Expected: FAIL — `Rating`, `SongInfo`, `Station` not defined.

- [ ] **Step 3: Implement `Rating.swift`**

```swift
import Foundation

public enum Rating: Equatable, Sendable {
    case unrated
    case loved
    case banned

    public init(pianobarInt: Int) {
        switch pianobarInt {
        case 1:  self = .loved
        case -1: self = .banned
        default: self = .unrated
        }
    }
}
```

- [ ] **Step 4: Implement `SongInfo.swift`**

```swift
import Foundation

public struct SongInfo: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var coverArtURL: URL?
    public var durationSeconds: Int
    public var rating: Rating
    public var detailURL: URL?
    public var stationName: String

    public init(
        title: String,
        artist: String,
        album: String,
        coverArtURL: URL?,
        durationSeconds: Int,
        rating: Rating,
        detailURL: URL?,
        stationName: String
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.coverArtURL = coverArtURL
        self.durationSeconds = durationSeconds
        self.rating = rating
        self.detailURL = detailURL
        self.stationName = stationName
    }
}
```

- [ ] **Step 5: Implement `Station.swift`**

```swift
import Foundation

public struct Station: Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var isQuickMix: Bool

    public init(id: String, name: String, isQuickMix: Bool) {
        self.id = id
        self.name = name
        self.isQuickMix = isQuickMix
    }
}
```

- [ ] **Step 6: Run tests to confirm pass**

Run: `cd Packages/PianobarCore && swift test --filter ModelsTests`
Expected: PASS, 3 tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Models Packages/PianobarCore/Tests/PianobarCoreTests/ModelsTests.swift
git commit -m "Add Rating, SongInfo, Station models"
```

---

### Task 3: Event types and parser

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Events/PianobarEvent.swift`
- Create: `Packages/PianobarCore/Sources/PianobarCore/Events/EventParser.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/event_payloads/songstart.txt`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/event_payloads/usergetstations.txt`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/event_payloads/userlogin_ok.txt`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/event_payloads/userlogin_fail.txt`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/EventParserTests.swift`

The parser is a pure function `(eventType: String, payload: String) -> PianobarEvent?`. It's the single most important testing target because it defines our contract with pianobar's event stream.

- [ ] **Step 1: Capture fixture payloads**

These are real payload formats pianobar emits. Write verbatim — keys are literal.

`Fixtures/event_payloads/songstart.txt`:
```
artist=Ed Sheeran
title=Shivers
album==
coverArt=https://example.com/cover.jpg
stationName=Imagine Dragons Radio
songStationName=Imagine Dragons Radio
pRet=1
pRetStr=Everything is fine :)
wRet=0
wRetStr=OK
songDuration=228
songPlayed=0
rating=0
detailUrl=https://pandora.com/song/shivers
```

`Fixtures/event_payloads/usergetstations.txt`:
```
station0=Imagine Dragons Radio
stationId0=123
station1=Bad Bunny 360° Radio
stationId1=456
station2=The Beatles Radio
stationId2=789
pRet=1
pRetStr=Everything is fine :)
wRet=0
wRetStr=OK
```

`Fixtures/event_payloads/userlogin_ok.txt`:
```
pRet=1
pRetStr=Everything is fine :)
wRet=0
wRetStr=OK
```

`Fixtures/event_payloads/userlogin_fail.txt`:
```
pRet=13
pRetStr=Invalid login
wRet=0
wRetStr=OK
```

- [ ] **Step 2: Write failing tests in `EventParserTests.swift`**

```swift
import XCTest
@testable import PianobarCore

final class EventParserTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: "event_payloads/\(name)",
                                    withExtension: "txt")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesSongStart() throws {
        let payload = try loadFixture("songstart")
        let event = EventParser.parse(eventType: "songstart", payload: payload)
        guard case .songStart(let song) = event else {
            return XCTFail("expected .songStart, got \(String(describing: event))")
        }
        XCTAssertEqual(song.title, "Shivers")
        XCTAssertEqual(song.artist, "Ed Sheeran")
        XCTAssertEqual(song.album, "=")
        XCTAssertEqual(song.durationSeconds, 228)
        XCTAssertEqual(song.rating, .unrated)
        XCTAssertEqual(song.stationName, "Imagine Dragons Radio")
        XCTAssertEqual(song.coverArtURL?.absoluteString, "https://example.com/cover.jpg")
    }

    func testParsesUserGetStations() throws {
        let payload = try loadFixture("usergetstations")
        let event = EventParser.parse(eventType: "usergetstations", payload: payload)
        guard case .stationsChanged(let stations) = event else {
            return XCTFail()
        }
        XCTAssertEqual(stations.count, 3)
        XCTAssertEqual(stations[0], Station(id: "123", name: "Imagine Dragons Radio", isQuickMix: false))
        XCTAssertEqual(stations[1], Station(id: "456", name: "Bad Bunny 360° Radio", isQuickMix: false))
        XCTAssertEqual(stations[2], Station(id: "789", name: "The Beatles Radio", isQuickMix: false))
    }

    func testUserLoginSuccess() throws {
        let payload = try loadFixture("userlogin_ok")
        let event = EventParser.parse(eventType: "userlogin", payload: payload)
        guard case .userLogin(let success, _) = event else { return XCTFail() }
        XCTAssertTrue(success)
    }

    func testUserLoginFailure() throws {
        let payload = try loadFixture("userlogin_fail")
        let event = EventParser.parse(eventType: "userlogin", payload: payload)
        guard case .userLogin(let success, let message) = event else { return XCTFail() }
        XCTAssertFalse(success)
        XCTAssertEqual(message, "Invalid login")
    }

    func testSimpleEventTypes() {
        XCTAssertEqual(EventParser.parse(eventType: "songfinish", payload: ""),
                       .songFinish)
        XCTAssertEqual(EventParser.parse(eventType: "songlove", payload: ""),
                       .songLove)
        XCTAssertEqual(EventParser.parse(eventType: "songban", payload: ""),
                       .songBan)
        XCTAssertEqual(EventParser.parse(eventType: "songshelf", payload: ""),
                       .songShelf)
    }

    func testUnknownEventTypeReturnsNil() {
        XCTAssertNil(EventParser.parse(eventType: "somethingWeird", payload: ""))
    }

    func testMalformedPayloadDoesNotCrash() {
        let event = EventParser.parse(eventType: "songstart", payload: "nonsense\n===")
        // parser should return nil or a .songStart with best-effort fields
        // but must not crash
        _ = event
    }
}
```

- [ ] **Step 3: Run tests; expect compile failure**

Run: `cd Packages/PianobarCore && swift test --filter EventParserTests`
Expected: FAIL — `PianobarEvent`, `EventParser` not defined.

- [ ] **Step 4: Implement `PianobarEvent.swift`**

```swift
import Foundation

public enum PianobarEvent: Equatable, Sendable {
    case songStart(SongInfo)
    case songFinish
    case songLove
    case songBan
    case songShelf
    case songBookmark
    case artistBookmark
    case stationFetchPlaylist
    case stationsChanged([Station])
    case stationCreated(Station)
    case stationDeleted(id: String)
    case stationRenamed(id: String, newName: String)
    case userLogin(success: Bool, message: String)
    case pandoraError(code: Int, message: String)
    case networkError(message: String)
}
```

- [ ] **Step 5: Implement `EventParser.swift`**

```swift
import Foundation

public enum EventParser {
    /// Parse a pianobar event. Returns nil if the event is unknown or the payload
    /// is unusable. Never throws.
    public static func parse(eventType: String, payload: String) -> PianobarEvent? {
        let kv = parseKeyValues(payload)

        // Check Pandora/network result codes first — if a command failed entirely
        // with a network error, surface it instead of the nominal event.
        if let wRet = kv["wRet"].flatMap(Int.init), wRet != 0 {
            return .networkError(message: kv["wRetStr"] ?? "Network error")
        }

        switch eventType {
        case "songstart":
            return songStart(from: kv)
        case "songfinish":
            return .songFinish
        case "songlove":
            return .songLove
        case "songban":
            return .songBan
        case "songshelf":
            return .songShelf
        case "songbookmark":
            return .songBookmark
        case "artistbookmark":
            return .artistBookmark
        case "stationfetchplaylist":
            return .stationFetchPlaylist
        case "usergetstations":
            return .stationsChanged(stations(from: kv))
        case "userlogin":
            let ok = (kv["pRet"].flatMap(Int.init) ?? 0) == 1
            return .userLogin(success: ok, message: kv["pRetStr"] ?? "")
        default:
            return nil
        }
    }

    private static func parseKeyValues(_ payload: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in payload.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            out[key] = value
        }
        return out
    }

    private static func songStart(from kv: [String: String]) -> PianobarEvent? {
        guard let title = kv["title"], let artist = kv["artist"] else { return nil }
        let song = SongInfo(
            title: title,
            artist: artist,
            album: kv["album"] ?? "",
            coverArtURL: kv["coverArt"].flatMap(URL.init),
            durationSeconds: kv["songDuration"].flatMap(Int.init) ?? 0,
            rating: Rating(pianobarInt: kv["rating"].flatMap(Int.init) ?? 0),
            detailURL: kv["detailUrl"].flatMap(URL.init),
            stationName: kv["stationName"] ?? ""
        )
        return .songStart(song)
    }

    private static func stations(from kv: [String: String]) -> [Station] {
        var list: [Station] = []
        var i = 0
        while let name = kv["station\(i)"] {
            let id = kv["stationId\(i)"] ?? String(i)
            list.append(Station(id: id, name: name, isQuickMix: false))
            i += 1
        }
        return list
    }
}
```

- [ ] **Step 6: Run tests; confirm all pass**

Run: `cd Packages/PianobarCore && swift test --filter EventParserTests`
Expected: PASS, 7 tests.

- [ ] **Step 7: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Events \
        Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures \
        Packages/PianobarCore/Tests/PianobarCoreTests/EventParserTests.swift
git commit -m "Add PianobarEvent types and EventParser with fixture-driven tests"
```

---

### Task 4: KeychainStore

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/System/KeychainStore.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/KeychainStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run and verify it fails to compile**

Run: `cd Packages/PianobarCore && swift test --filter KeychainStoreTests`
Expected: FAIL — `KeychainStore` not defined.

- [ ] **Step 3: Implement `KeychainStore.swift`**

```swift
import Foundation
import Security

public struct KeychainStore {
    public enum Error: Swift.Error { case status(OSStatus) }

    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func save(email: String, password: String) throws {
        delete() // replace any existing entry

        let data = Data("\(email)\n\(password)".utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: email,
            kSecValueData as String:   data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    public func load() -> (email: String, password: String)? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let decoded = String(data: data, encoding: .utf8)
        else { return nil }
        let parts = decoded.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    public func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

- [ ] **Step 4: Run tests — confirm pass**

Run: `cd Packages/PianobarCore && swift test --filter KeychainStoreTests`
Expected: PASS, 4 tests. Note: `swift test` spawns a host process that has Keychain access on macOS. If prompts appear interactively, click "Always Allow" for this one session.

- [ ] **Step 5: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/System/KeychainStore.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/KeychainStoreTests.swift
git commit -m "Add KeychainStore for Pandora credentials"
```

---

### Task 5: ConfigManager

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Pianobar/ConfigManager.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/ConfigManagerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
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
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd Packages/PianobarCore && swift test --filter ConfigManagerTests`
Expected: FAIL — `ConfigManager` not defined.

- [ ] **Step 3: Implement `ConfigManager.swift`**

```swift
import Foundation

public struct ConfigManager {
    public enum AudioQuality: String { case low, medium, high }

    private let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    public func writeConfig(
        email: String,
        password: String,
        audioQuality: AudioQuality,
        eventBridgePath: String,
        fifoPath: String
    ) throws {
        try FileManager.default.createDirectory(
            at: configDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        let body = """
        user = \(email)
        password = \(password)
        audio_quality = \(audioQuality.rawValue)
        autoselect = 1
        event_command = \(eventBridgePath)
        fifo = \(fifoPath)
        """

        let configFile = configDir.appendingPathComponent("config")
        try body.write(to: configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: configFile.path)
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

Run: `cd Packages/PianobarCore && swift test --filter ConfigManagerTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Pianobar/ConfigManager.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/ConfigManagerTests.swift
git commit -m "Add ConfigManager that writes pianobar config file"
```

---

### Task 6: PianobarCtrl (FIFO writer)

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarCtrl.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/PianobarCtrlTests.swift`

`PianobarCtrl` is an actor that opens the FIFO for writing and serializes command bytes. Tests use `mkfifo(2)` to create a real FIFO in a temp dir, spawn a background reader, and assert exact bytes.

- [ ] **Step 1: Write failing tests**

```swift
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
```

(The volume syntax `(N` is what pianobar uses to set an absolute volume; if
pianobar on your platform uses a different key, adjust `setVolume`'s encoding
and this assertion together.)

- [ ] **Step 2: Confirm failure**

Run: `cd Packages/PianobarCore && swift test --filter PianobarCtrlTests`
Expected: FAIL — `PianobarCtrl` not defined.

- [ ] **Step 3: Implement `PianobarCtrl.swift`**

```swift
import Foundation

public actor PianobarCtrl {
    public enum Error: Swift.Error {
        case openFailed(String)
        case writeFailed(Int32)
    }

    private let fifoPath: String
    private var handle: FileHandle?

    public init(fifoPath: String) {
        self.fifoPath = fifoPath
    }

    public func play()          async throws { try write("p\n") }
    public func pause()         async throws { try write("p\n") } // pianobar toggles
    public func togglePlay()    async throws { try write("p\n") }
    public func next()          async throws { try write("n\n") }
    public func love()          async throws { try write("+\n") }
    public func ban()           async throws { try write("-\n") }
    public func tired()         async throws { try write("t\n") }
    public func bookmarkSong()  async throws { try write("b\n") }
    public func bookmarkArtist() async throws { try write("b\na\n") }

    public func switchStation(index: Int) async throws {
        try write("s\(index)\n")
    }

    public func createStationFromSong()   async throws { try write("c\n") }
    public func createStationFromArtist() async throws { try write("v\n") }
    public func deleteStation()           async throws { try write("d\n") }
    public func renameStation(_ newName: String) async throws {
        try write("r\(newName)\n")
    }
    public func setVolume(_ v: Int) async throws {
        let clamped = max(0, min(100, v))
        try write("(\(clamped)\n")
    }
    public func quit() async throws { try write("q\n") }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    private func write(_ cmd: String) throws {
        if handle == nil {
            // Opening a FIFO for writing blocks until a reader is present.
            // Use O_WRONLY; caller is responsible for the reader (pianobar).
            let fd = open(fifoPath, O_WRONLY)
            guard fd >= 0 else { throw Error.openFailed(String(cString: strerror(errno))) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        guard let data = cmd.data(using: .utf8) else { return }
        do {
            try handle!.write(contentsOf: data)
        } catch {
            throw Error.writeFailed(errno)
        }
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

Run: `cd Packages/PianobarCore && swift test --filter PianobarCtrlTests`
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarCtrl.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/PianobarCtrlTests.swift
git commit -m "Add PianobarCtrl actor for FIFO command writes"
```

---

### Task 7: EventBridge (Unix socket listener)

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Resources/event_bridge.sh`
- Create: `Packages/PianobarCore/Sources/PianobarCore/Pianobar/EventBridge.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/EventBridgeTests.swift`

The bridge opens a Unix domain socket, accepts connections, reads framed
records (`event_type\n<payload>\n\x1e`), parses them into typed events, and
exposes them as an `AsyncStream<PianobarEvent>`.

- [ ] **Step 1: Write `event_bridge.sh`**

```sh
#!/bin/sh
# Forwards a pianobar event to the PianobarGUI app via a Unix domain socket.
# pianobar invokes this with the event name as $1 and the key=value payload on stdin.
# PIANOBAR_GUI_SOCK must be exported in the environment by PianobarProcess.
set -eu
if [ -z "${PIANOBAR_GUI_SOCK:-}" ]; then exit 0; fi
# Record format: "$1\n<stdin>\n\x1e". Use printf for portability.
{
  printf '%s\n' "$1"
  cat
  printf '\036'
} | /usr/bin/nc -U "$PIANOBAR_GUI_SOCK" >/dev/null 2>&1 || true
```

Make it executable in the step below (tests rely on the executable bit).

- [ ] **Step 2: Write failing tests**

```swift
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
```

- [ ] **Step 3: Confirm failure**

Run: `cd Packages/PianobarCore && chmod +x Sources/PianobarCore/Resources/event_bridge.sh && swift test --filter EventBridgeTests`
Expected: FAIL — `EventBridge` not defined.

- [ ] **Step 4: Implement `EventBridge.swift`**

```swift
import Foundation

public final class EventBridge: @unchecked Sendable {
    public enum Error: Swift.Error { case socketFailed(String) }

    public let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    private let continuation: AsyncStream<PianobarEvent>.Continuation
    public let events: AsyncStream<PianobarEvent>

    public init(socketPath: String) throws {
        self.socketPath = socketPath
        var cont: AsyncStream<PianobarEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    public func start() async throws {
        unlink(socketPath)
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw Error.socketFailed("socket: \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) {
                    strncpy($0, src, MemoryLayout.size(ofValue: addr.sun_path) - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, size) }
        }
        guard bindResult == 0 else {
            throw Error.socketFailed("bind: \(String(cString: strerror(errno)))")
        }
        guard listen(listenFD, 8) == 0 else {
            throw Error.socketFailed("listen: \(String(cString: strerror(errno)))")
        }

        acceptTask = Task.detached { [weak self] in
            await self?.acceptLoop()
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
        continuation.finish()
    }

    private func acceptLoop() async {
        while !Task.isCancelled {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            handleClient(fd: fd)
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(tmp, count: n)
            if buf.last == 0x1e { break } // record separator
        }
        // Strip trailing separator, split first line from payload.
        if buf.last == 0x1e { buf.removeLast() }
        if buf.last == 0x0a { buf.removeLast() }
        guard let text = String(data: buf, encoding: .utf8) else { return }
        guard let newline = text.firstIndex(of: "\n") else { return }
        let eventType = String(text[..<newline])
        let payload = String(text[text.index(after: newline)...])
        if let event = EventParser.parse(eventType: eventType, payload: payload) {
            continuation.yield(event)
        }
    }
}
```

- [ ] **Step 5: Run tests; expect pass**

Run: `cd Packages/PianobarCore && swift test --filter EventBridgeTests`
Expected: PASS, 1 test.

- [ ] **Step 6: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Pianobar/EventBridge.swift \
        Packages/PianobarCore/Sources/PianobarCore/Resources/event_bridge.sh \
        Packages/PianobarCore/Tests/PianobarCoreTests/EventBridgeTests.swift
git commit -m "Add EventBridge Unix socket listener and event_bridge.sh helper"
```

---

### Task 8: PianobarProcess supervisor

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarProcess.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/mock_pianobar.sh`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/PianobarProcessTests.swift`

The supervisor spawns pianobar with `XDG_CONFIG_HOME` pointing at an isolated
config dir, wires through `PIANOBAR_GUI_SOCK`, and watches for exit. For tests
we use a small shell script that pretends to be pianobar.

- [ ] **Step 1: Write `mock_pianobar.sh`**

```sh
#!/bin/sh
# Minimal pianobar stand-in for tests.
# Honors $XDG_CONFIG_HOME/pianobar/config for fifo and event_command paths.
# On start, fires a "userlogin" event. Then reads FIFO forever; on 'q' exits 0.
set -eu

CFG="$XDG_CONFIG_HOME/pianobar/config"
FIFO=$(grep '^fifo = ' "$CFG" | head -n1 | sed 's/^fifo = //')
EVT=$(grep '^event_command = ' "$CFG" | head -n1 | sed 's/^event_command = //')

# Fire userlogin ok.
printf 'pRet=1\npRetStr=OK\nwRet=0\nwRetStr=OK\n' | "$EVT" userlogin

# Read commands forever.
while IFS= read -r cmd < "$FIFO"; do
  case "$cmd" in
    q) exit 0 ;;
    *) : ;;
  esac
done
```

- [ ] **Step 2: Write failing tests**

```swift
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
        let scriptPath = PianobarCoreResources.eventBridgeScriptURL.path

        try ConfigManager(configDir: cfgDir).writeConfig(
            email: "a@b.com", password: "p", audioQuality: .low,
            eventBridgePath: scriptPath, fifoPath: fifoPath)

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
```

- [ ] **Step 3: Confirm failure**

Run: `cd Packages/PianobarCore && chmod +x Tests/PianobarCoreTests/Fixtures/mock_pianobar.sh && swift test --filter PianobarProcessTests`
Expected: FAIL — `PianobarProcess` not defined.

- [ ] **Step 4: Implement `PianobarProcess.swift`**

```swift
import Foundation

public actor PianobarProcess {
    public enum Error: Swift.Error { case notRunning, spawnFailed(String) }

    public enum State: Equatable { case stopped, running, crashed }

    private let executablePath: String
    private let xdgConfigHome: String
    private let eventSocketPath: String
    private var process: Process?
    private(set) var state: State = .stopped

    public init(executablePath: String, xdgConfigHome: String, eventSocketPath: String) {
        self.executablePath = executablePath
        self.xdgConfigHome = xdgConfigHome
        self.eventSocketPath = eventSocketPath
    }

    public func start() async throws {
        if state == .running { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executablePath)
        p.environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
            "XDG_CONFIG_HOME": xdgConfigHome,
            "PIANOBAR_GUI_SOCK": eventSocketPath,
        ]
        // Discard stdout/stderr to /dev/null for now. Plan 2 will pipe to log file.
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError  = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try p.run()
        } catch {
            throw Error.spawnFailed(String(describing: error))
        }
        process = p
        state = .running
    }

    public func stop() async throws {
        guard let p = process else { throw Error.notRunning }
        p.terminate()
        p.waitUntilExit()
        process = nil
        state = .stopped
    }
}
```

- [ ] **Step 5: Run tests; expect pass**

Run: `cd Packages/PianobarCore && swift test --filter PianobarProcessTests`
Expected: PASS, 1 test.

- [ ] **Step 6: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/Pianobar/PianobarProcess.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/mock_pianobar.sh \
        Packages/PianobarCore/Tests/PianobarCoreTests/PianobarProcessTests.swift
git commit -m "Add PianobarProcess supervisor with mock-driven test"
```

---

### Task 9: PlaybackState

**Files:**
- Create: `Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift`
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/PlaybackStateTests.swift`

`PlaybackState` is the single source of truth. It consumes events from an
`AsyncSequence` and publishes observable state for SwiftUI.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
import Combine
@testable import PianobarCore

@MainActor
final class PlaybackStateTests: XCTestCase {
    private var subs = Set<AnyCancellable>()

    // AsyncStream.makeStream() is macOS 14+; we support macOS 13.
    // Capture the continuation manually.
    private func makeEventStream() -> (AsyncStream<PianobarEvent>, AsyncStream<PianobarEvent>.Continuation) {
        var cont: AsyncStream<PianobarEvent>.Continuation!
        let stream = AsyncStream<PianobarEvent> { cont = $0 }
        return (stream, cont)
    }

    func testSongStartUpdatesCurrentSong() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)

        let song = SongInfo(title: "Shivers", artist: "Ed Sheeran", album: "=",
                            coverArtURL: nil, durationSeconds: 228,
                            rating: .unrated, detailURL: nil,
                            stationName: "Imagine Dragons Radio")
        cont.yield(.songStart(song))

        await waitUntil { state.currentSong?.title == "Shivers" }
        XCTAssertEqual(state.currentSong, song)
        XCTAssertEqual(state.progressSeconds, 0)
        XCTAssertTrue(state.isPlaying)
        cont.finish()
    }

    func testSongStartAppendsPreviousToHistory() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        let a = makeSong(title: "A")
        let b = makeSong(title: "B")
        cont.yield(.songStart(a))
        await waitUntil { state.currentSong?.title == "A" }
        cont.yield(.songStart(b))
        await waitUntil { state.currentSong?.title == "B" }
        XCTAssertEqual(state.history.map(\.title), ["A"])
        cont.finish()
    }

    func testStationsChangedReplacesList() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        cont.yield(.stationsChanged([
            Station(id: "1", name: "A", isQuickMix: false),
            Station(id: "2", name: "B", isQuickMix: false)
        ]))
        await waitUntil { state.stations.count == 2 }
        XCTAssertEqual(state.stations.map(\.name), ["A", "B"])
        cont.finish()
    }

    func testUserLoginFailureClearsAuth() async {
        let (stream, cont) = makeEventStream()
        let state = PlaybackState(events: stream)
        cont.yield(.userLogin(success: false, message: "Invalid login"))
        await waitUntil { state.authFailure != nil }
        XCTAssertEqual(state.authFailure, "Invalid login")
        cont.finish()
    }

    // Helpers
    private func makeSong(title: String) -> SongInfo {
        SongInfo(title: title, artist: "x", album: "x", coverArtURL: nil,
                 durationSeconds: 100, rating: .unrated, detailURL: nil,
                 stationName: "x")
    }

    private func waitUntil(timeout: Double = 2,
                           _ cond: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition never became true")
    }
}
```

- [ ] **Step 2: Confirm failure**

Run: `cd Packages/PianobarCore && swift test --filter PlaybackStateTests`
Expected: FAIL — `PlaybackState` not defined.

- [ ] **Step 3: Implement `PlaybackState.swift`**

```swift
import Foundation
import Combine

@MainActor
public final class PlaybackState: ObservableObject {
    @Published public private(set) var currentSong: SongInfo?
    @Published public private(set) var currentStation: Station?
    @Published public private(set) var stations: [Station] = []
    @Published public private(set) var history: [SongInfo] = []
    @Published public private(set) var isPlaying: Bool = false
    @Published public var volume: Int = 50
    @Published public private(set) var progressSeconds: Int = 0
    @Published public private(set) var errorBanner: String?
    @Published public private(set) var authFailure: String?

    private var consumeTask: Task<Void, Never>?
    private var ticker: Timer?

    public init<E: AsyncSequence>(events: E) where E.Element == PianobarEvent {
        consumeTask = Task { [weak self] in
            do {
                for try await event in events {
                    await self?.apply(event)
                }
            } catch {
                // AsyncStream never throws; other sequences may.
            }
        }
        startTicker()
    }

    deinit {
        consumeTask?.cancel()
        ticker?.invalidate()
    }

    // Intent methods — UI calls these. Routing to PianobarCtrl is done at the
    // app wiring layer in Task 11; PlaybackState is protocol-independent here.

    public func apply(_ event: PianobarEvent) {
        switch event {
        case .songStart(let song):
            if let prev = currentSong {
                history.insert(prev, at: 0)
                if history.count > 50 { history.removeLast(history.count - 50) }
            }
            currentSong = song
            currentStation = stations.first { $0.name == song.stationName }
                              ?? currentStation
            progressSeconds = 0
            isPlaying = true
        case .songFinish:
            break // song will be appended when next songStart fires
        case .songLove:     currentSong?.rating = .loved
        case .songBan:      currentSong?.rating = .banned
        case .songShelf:    break
        case .songBookmark, .artistBookmark: break
        case .stationFetchPlaylist: break
        case .stationsChanged(let s):
            stations = s
            currentStation = stations.first { $0.name == currentSong?.stationName }
        case .stationCreated(let s):
            if !stations.contains(where: { $0.id == s.id }) { stations.append(s) }
        case .stationDeleted(let id):
            stations.removeAll { $0.id == id }
        case .stationRenamed(let id, let name):
            if let i = stations.firstIndex(where: { $0.id == id }) {
                stations[i].name = name
            }
        case .userLogin(let ok, let msg):
            authFailure = ok ? nil : (msg.isEmpty ? "Sign-in failed" : msg)
        case .pandoraError(_, let msg), .networkError(let msg):
            errorBanner = msg
        }
    }

    public func setPlaying(_ playing: Bool) { isPlaying = playing }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying,
                      let dur = self.currentSong?.durationSeconds,
                      self.progressSeconds < dur
                else { return }
                self.progressSeconds += 1
            }
        }
    }
}
```

- [ ] **Step 4: Run tests; expect pass**

Run: `cd Packages/PianobarCore && swift test --filter PlaybackStateTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/PianobarCore/Sources/PianobarCore/State/PlaybackState.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/PlaybackStateTests.swift
git commit -m "Add PlaybackState with event-driven mutations and progress ticker"
```

---

### Task 10: App bootstrap and LoginView

**Files:**
- Create: `App/PianobarGUIApp.swift`
- Create: `App/AppBootstrap.swift`
- Create: `App/Views/LoginView.swift`
- Modify: `project.yml` (already correct; regenerate project)

- [ ] **Step 1: Write `PianobarGUIApp.swift`**

```swift
import SwiftUI
import PianobarCore

@main
struct PianobarGUIApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup("PianobarGUI") {
            Group {
                if bootstrap.needsLogin {
                    LoginView(onSubmit: { email, password in
                        bootstrap.saveCredentials(email: email, password: password)
                    })
                } else if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
                    MainWindowView(state: state, ctrl: ctrl)
                } else {
                    ProgressView("Starting…").padding()
                }
            }
            .task { await bootstrap.start() }
            .frame(minWidth: 680, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
    }
}
```

- [ ] **Step 2: Write `AppBootstrap.swift`**

```swift
import Foundation
import SwiftUI
import PianobarCore

@MainActor
final class AppBootstrap: ObservableObject {
    @Published var needsLogin = false
    @Published private(set) var playbackState: PlaybackState?
    @Published private(set) var ctrl: PianobarCtrl?

    private let keychain = KeychainStore(service: "org.pianobar-gui.PianobarGUI.pandora")
    private var bridge: EventBridge?
    private var process: PianobarProcess?

    private var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PianobarGUI")
    }
    private var configDir: URL { appSupportDir.appendingPathComponent("pianobar") }
    private var socketPath: String { appSupportDir.appendingPathComponent("events.sock").path }
    private var fifoPath:   String { configDir.appendingPathComponent("ctl").path }

    func start() async {
        guard let creds = keychain.load() else {
            needsLogin = true
            return
        }
        await launch(email: creds.email, password: creds.password)
    }

    func saveCredentials(email: String, password: String) {
        try? keychain.save(email: email, password: password)
        needsLogin = false
        Task { await launch(email: email, password: password) }
    }

    private func launch(email: String, password: String) async {
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Resolve pianobar path. Dev builds use Homebrew.
        let pianobarPath = resolvePianobarPath() ?? "/opt/homebrew/bin/pianobar"

        let eventBridgePath = PianobarCoreResources.eventBridgeScriptURL.path

        // Write config
        try? ConfigManager(configDir: configDir).writeConfig(
            email: email, password: password, audioQuality: .high,
            eventBridgePath: eventBridgePath, fifoPath: fifoPath)

        // Make FIFO
        unlink(fifoPath)
        _ = mkfifo(fifoPath, 0o600)

        // Start event bridge
        guard let b = try? EventBridge(socketPath: socketPath) else { return }
        try? await b.start()
        bridge = b

        // Wire up state
        let state = PlaybackState(events: b.events)
        playbackState = state

        // Start pianobar
        let proc = PianobarProcess(
            executablePath: pianobarPath,
            xdgConfigHome: appSupportDir.path,
            eventSocketPath: socketPath
        )
        try? await proc.start()
        process = proc

        // Commands
        ctrl = PianobarCtrl(fifoPath: fifoPath)
    }

    private func resolvePianobarPath() -> String? {
        for candidate in ["/opt/homebrew/bin/pianobar", "/usr/local/bin/pianobar"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

```

- [ ] **Step 3: Write `Views/LoginView.swift`**

```swift
import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    let onSubmit: (String, String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Sign in to Pandora").font(.title2)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            Button("Sign In") { onSubmit(email, password) }
                .keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty)
        }
        .padding(40)
    }
}
```

- [ ] **Step 4: Regenerate Xcode project and build**

Run:
```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `BUILD SUCCEEDED`. (Main window will be blank until Task 13.)

- [ ] **Step 5: Commit**

```bash
git add App/ project.yml PianobarGUI.xcodeproj
git commit -m "Scaffold SwiftUI app, AppBootstrap, and LoginView"
```

---

### Task 11: StationsSidebarView

**Files:**
- Create: `App/Views/StationsSidebarView.swift`

- [ ] **Step 1: Write `StationsSidebarView.swift`**

```swift
import SwiftUI
import PianobarCore

struct StationsSidebarView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var filter: String = ""

    var filtered: [Station] {
        guard !filter.isEmpty else { return state.stations }
        return state.stations.filter {
            $0.name.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List(selection: Binding(
                get: { state.currentStation?.id },
                set: { newID in
                    if let id = newID,
                       let idx = state.stations.firstIndex(where: { $0.id == id }) {
                        Task { try? await ctrl.switchStation(index: idx) }
                    }
                })) {
                ForEach(filtered) { station in
                    HStack {
                        if state.currentStation?.id == station.id {
                            Image(systemName: "speaker.wave.2.fill")
                                .foregroundStyle(.secondary)
                        }
                        Text(station.name)
                    }.tag(station.id)
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 200)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodegen generate
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Views/StationsSidebarView.swift PianobarGUI.xcodeproj
git commit -m "Add StationsSidebarView with filter and selection"
```

---

### Task 12: NowPlayingView

**Files:**
- Create: `App/Views/NowPlayingView.swift`

- [ ] **Step 1: Write `NowPlayingView.swift`**

```swift
import SwiftUI
import PianobarCore

struct NowPlayingView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 20) {
            albumArt
                .frame(width: 240, height: 240)
            if let song = state.currentSong {
                VStack(spacing: 4) {
                    Text(song.title).font(.title3).bold()
                    Text(song.artist).font(.body).foregroundStyle(.secondary)
                    Text(song.album).font(.callout).foregroundStyle(.tertiary)
                }
            } else {
                Text("Not playing").foregroundStyle(.secondary)
            }

            controls

            progress

            volume
        }
        .padding(24)
        .frame(minWidth: 380)
    }

    @ViewBuilder private var albumArt: some View {
        if let url = state.currentSong?.coverArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default: placeholderArt
                }
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.2))
            .overlay(Image(systemName: "music.note").font(.system(size: 64))
                .foregroundStyle(.secondary))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            button(systemName: state.isPlaying ? "pause.fill" : "play.fill") {
                Task { try? await ctrl.togglePlay(); state.setPlaying(!state.isPlaying) }
            }
            button(systemName: "forward.fill") {
                Task { try? await ctrl.next() }
            }
            button(systemName: "hand.thumbsdown",
                   active: state.currentSong?.rating == .banned) {
                Task { try? await ctrl.ban() }
            }
            button(systemName: "hand.thumbsup",
                   active: state.currentSong?.rating == .loved) {
                Task { try? await ctrl.love() }
            }
            Menu {
                Button("Bookmark Song")   { Task { try? await ctrl.bookmarkSong() } }
                Button("Bookmark Artist") { Task { try? await ctrl.bookmarkArtist() } }
                Button("Tired of Track")  { Task { try? await ctrl.tired() } }
                if let url = state.currentSong?.detailURL {
                    Button("Open in Pandora") { NSWorkspace.shared.open(url) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
        }
    }

    private func button(systemName: String, active: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
    }

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(state.progressSeconds),
                         total: Double(max(state.currentSong?.durationSeconds ?? 1, 1)))
            HStack {
                Text(format(state.progressSeconds))
                Spacer()
                Text(format(state.currentSong?.durationSeconds ?? 0))
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private var volume: some View {
        HStack {
            Image(systemName: "speaker.fill").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(state.volume) },
                set: { state.volume = Int($0)
                       Task { try? await ctrl.setVolume(Int($0)) } }),
                   in: 0...100)
            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
        }
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run:
```bash
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add App/Views/NowPlayingView.swift
git commit -m "Add NowPlayingView with controls, art, progress, volume"
```

---

### Task 13: MainWindowView and error banner

**Files:**
- Create: `App/Views/MainWindowView.swift`
- Create: `App/Views/ErrorBanner.swift`

- [ ] **Step 1: Write `ErrorBanner.swift`**

```swift
import SwiftUI

struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).lineLimit(2)
            Spacer()
            if let retry = onRetry {
                Button("Retry", action: retry).buttonStyle(.borderless)
            }
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.15))
    }
}
```

- [ ] **Step 2: Write `MainWindowView.swift`**

```swift
import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 0) {
            if let msg = state.errorBanner {
                ErrorBanner(message: msg, onRetry: nil,
                            onDismiss: { /* Plan 2: add dismiss on state */ })
            }
            NavigationSplitView {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl)
            }
        }
    }
}
```

- [ ] **Step 3: Build and run the app manually**

Run:
```bash
xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' build 2>&1 | tail -5
open -b org.pianobar-gui.PianobarGUI || \
  xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI -destination 'platform=macOS' -configuration Debug -derivedDataPath build build
# Then run the .app from build/Build/Products/Debug/PianobarGUI.app
open build/Build/Products/Debug/PianobarGUI.app
```

Expected: App launches, LoginView shown (first run) or MainWindowView populated with stations and now-playing once pianobar connects.

- [ ] **Step 4: Commit**

```bash
git add App/Views/MainWindowView.swift App/Views/ErrorBanner.swift
git commit -m "Add MainWindowView split layout and ErrorBanner"
```

---

### Task 14: End-to-end integration test

**Files:**
- Create: `Packages/PianobarCore/Tests/PianobarCoreTests/IntegrationTests.swift`
- Modify: `Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/mock_pianobar.sh` (add more events)

The goal: drive the full PianobarCore stack (Process → FIFO → Events → State)
end to end, without the UI, using the mock pianobar shell script.

- [ ] **Step 1: Extend `mock_pianobar.sh` to honor more commands**

Replace contents with:

```sh
#!/bin/sh
set -eu
CFG="$XDG_CONFIG_HOME/pianobar/config"
FIFO=$(grep '^fifo = ' "$CFG" | head -n1 | sed 's/^fifo = //')
EVT=$(grep '^event_command = ' "$CFG" | head -n1 | sed 's/^event_command = //')

fire() {
  evt=$1
  body=$2
  printf '%s' "$body" | "$EVT" "$evt"
}

fire userlogin "pRet=1
pRetStr=OK
wRet=0
wRetStr=OK"

fire usergetstations "station0=Radio A
stationId0=111
station1=Radio B
stationId1=222
pRet=1
wRet=0"

fire songstart "title=Song1
artist=Artist1
album=Album1
songDuration=180
rating=0
stationName=Radio A
pRet=1
wRet=0"

while IFS= read -r cmd < "$FIFO"; do
  case "$cmd" in
    q) exit 0 ;;
    +) fire songlove "pRet=1
wRet=0" ;;
    -) fire songban "pRet=1
wRet=0" ;;
    n) fire songfinish ""
       fire songstart "title=Song2
artist=Artist2
album=Album2
songDuration=200
rating=0
stationName=Radio A
pRet=1
wRet=0" ;;
    s*) idx=${cmd#s}
        case "$idx" in
          0) name="Radio A" ;;
          *) name="Radio B" ;;
        esac
        fire songstart "title=NewSong
artist=NewArtist
album=NewAlbum
songDuration=120
rating=0
stationName=$name
pRet=1
wRet=0" ;;
    *) : ;;
  esac
done
```

- [ ] **Step 2: Write `IntegrationTests.swift`**

```swift
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
        try ConfigManager(configDir: cfgDir).writeConfig(
            email: "a@b.com", password: "p", audioQuality: .low,
            eventBridgePath: PianobarCoreResources.eventBridgeScriptURL.path,
            fifoPath: fifoPath)
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
```

- [ ] **Step 3: Run tests**

Run: `cd Packages/PianobarCore && swift test --filter IntegrationTests`
Expected: PASS, 1 test.

- [ ] **Step 4: Run the entire test suite to confirm nothing regressed**

Run: `cd Packages/PianobarCore && swift test`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/PianobarCore/Tests/PianobarCoreTests/IntegrationTests.swift \
        Packages/PianobarCore/Tests/PianobarCoreTests/Fixtures/mock_pianobar.sh
git commit -m "Add end-to-end IntegrationTests driving full core stack via mock pianobar"
```

---

### Task 15: Manual QA checklist and README polish

**Files:**
- Create: `docs/superpowers/qa-checklist-plan-1.md`
- Modify: `README.md`

- [ ] **Step 1: Write `docs/superpowers/qa-checklist-plan-1.md`**

```markdown
# QA Checklist — Plan 1

Do these manual checks against a real Pandora account on a dev Mac with
`brew install pianobar` before declaring Plan 1 done.

## First-run
- [ ] Fresh Application Support dir (delete `~/Library/Application Support/PianobarGUI/` if present).
- [ ] Launch app → LoginView appears.
- [ ] Enter valid credentials, click Sign In.
- [ ] Main window opens. Within ~5 seconds, stations populate and a song starts.

## Playback
- [ ] Album art loads for the current song.
- [ ] Song title, artist, album displayed correctly.
- [ ] Progress bar advances approximately in real time.
- [ ] Play/pause toggles; pause stops the progress timer.
- [ ] Skip loads the next song within a second or two.

## Rating
- [ ] Thumbs-up highlights; reverting via thumbs-down updates immediately.
- [ ] Overflow menu: Tired of Track skips and doesn't replay the song soon.
- [ ] Overflow menu: Bookmark Song, Bookmark Artist complete without error.

## Stations
- [ ] Sidebar lists all stations.
- [ ] Clicking a different station starts a new song from that station within a few seconds.
- [ ] Filter field narrows the list instantly.

## Volume
- [ ] Slider adjusts playback volume audibly.

## Second launch
- [ ] Close the app, relaunch. Skips LoginView, auto-resumes last station.

## Sign out (via Keychain)
- [ ] Manually delete Keychain entry (via Keychain Access.app, search the
      app's service name). Restart app → LoginView returns.

## Failure modes
- [ ] Disable Wi-Fi; trigger a skip. An error banner appears with an
      informative message. Re-enable Wi-Fi, click Retry (or next action);
      playback resumes without restarting the app.
- [ ] Kill `pianobar` via Activity Monitor. Error banner appears; Plan 2
      adds auto-restart — for now, quit and relaunch.
```

- [ ] **Step 2: Update README development section**

Add to `README.md` after the existing Development block:

```markdown
## Running the app (Plan 1 scope)

The app requires pianobar to be installed on the dev machine until Plan 3
bundles it. With `brew install pianobar` in place, run:

    xcodegen generate
    xcodebuild -project PianobarGUI.xcodeproj -scheme PianobarGUI \
               -destination 'platform=macOS' -configuration Debug \
               -derivedDataPath build build
    open build/Build/Products/Debug/PianobarGUI.app

Credentials are stored in the macOS Keychain under the service
`org.pianobar-gui.PianobarGUI.pandora`.

## Running tests

    cd Packages/PianobarCore
    swift test
```

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/qa-checklist-plan-1.md README.md
git commit -m "Add Plan 1 QA checklist and README running instructions"
```

---

## Plan 1 Done Criteria

- All 15 tasks' commits landed on the working branch.
- `swift test` in `Packages/PianobarCore` passes cleanly.
- `xcodebuild … build` succeeds for the `PianobarGUI` scheme.
- Every item in `docs/superpowers/qa-checklist-plan-1.md` checked against a real Pandora account.

When those are green, hand off to Plan 2 (menu bar, notifications, Now Playing, history, hotkeys, preferences).
