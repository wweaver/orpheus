import Foundation
import SwiftUI

/// Single source of truth for user preferences. Backed by `UserDefaults`.
enum Prefs {
    enum Keys {
        static let audioQuality = "audioQuality"               // String: "low"|"medium"|"high"
        static let showNotifications = "showNotifications"     // Bool
        static let menuBarShowArtist = "menuBarShowArtist"     // Bool
        static let menuBarShowTitle  = "menuBarShowTitle"      // Bool
        static let menuBarMaxWidth   = "menuBarMaxWidth"       // Int (chars)
        static let autostartLastStation = "autostartLastStation" // Bool
        static let lastStationName   = "lastStationName"       // String (station display name)
        static let lastStationId     = "lastStationId"         // legacy, kept for migration/cleanup
        static let stationClickCount = "stationClickCount"     // Int (1 or 2)
        static let eventDebugLog     = "eventDebugLog"         // Bool
        static let keepPianobarAlive = "keepPianobarAlive"     // Bool (experimental)
        static let wasPlayingOnQuit  = "wasPlayingOnQuit"      // Bool (internal)
    }

    /// Defaults applied once at first launch if the key is missing.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.audioQuality: "high",
            Keys.showNotifications: true,
            Keys.menuBarShowArtist: true,
            Keys.menuBarShowTitle: true,
            Keys.menuBarMaxWidth: 40,
            Keys.autostartLastStation: true,
            Keys.stationClickCount: 2,
            Keys.eventDebugLog: false,
            Keys.keepPianobarAlive: false,
        ])
    }
}
