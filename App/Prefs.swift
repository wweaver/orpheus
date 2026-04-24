import Foundation
import SwiftUI

/// Single source of truth for user preferences. Backed by `UserDefaults`.
enum Prefs {
    enum Keys {
        static let audioQuality = "audioQuality"           // String: "low"|"medium"|"high"
        static let showNotifications = "showNotifications" // Bool
        static let menuBarShowArtist = "menuBarShowArtist" // Bool
        static let menuBarShowTitle  = "menuBarShowTitle"  // Bool
        static let menuBarMaxWidth   = "menuBarMaxWidth"   // Int (chars)
    }

    /// Defaults applied once at first launch if the key is missing.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.audioQuality: "high",
            Keys.showNotifications: true,
            Keys.menuBarShowArtist: true,
            Keys.menuBarShowTitle: true,
            Keys.menuBarMaxWidth: 40,
        ])
    }
}
