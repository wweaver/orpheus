import SwiftUI
import PianobarCore

struct PreferencesView: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @AppStorage(Prefs.Keys.audioQuality) var audioQuality: String = "high"
    @AppStorage(Prefs.Keys.showNotifications) var showNotifications: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowArtist) var menuBarShowArtist: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowTitle)  var menuBarShowTitle: Bool = true
    @AppStorage(Prefs.Keys.menuBarMaxWidth)   var menuBarMaxWidth: Int = 40
    @AppStorage(Prefs.Keys.autostartLastStation) var autostartLastStation: Bool = true
    @AppStorage(Prefs.Keys.eventDebugLog)     var eventDebugLog: Bool = false
    @AppStorage(Prefs.Keys.keepPianobarAlive) var keepPianobarAlive: Bool = false
    @AppStorage(Prefs.Keys.pauseOnSleep)      var pauseOnSleep: Bool = true

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            hotkeys.tabItem { Label("Hotkeys", systemImage: "keyboard") }
            advanced.tabItem { Label("Advanced", systemImage: "ladybug") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 520, height: 380)
    }

    private var general: some View {
        tab {
            Form {
                Picker("Audio quality", selection: $audioQuality) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                }
                Toggle("Resume last station on launch", isOn: $autostartLastStation)
                Toggle("Pause when computer sleeps or screen is locked", isOn: $pauseOnSleep)
            }
            .formStyle(.grouped)
        }
    }

    private var menuBar: some View {
        tab {
            Form {
                Toggle("Show artist", isOn: $menuBarShowArtist)
                Toggle("Show title",  isOn: $menuBarShowTitle)
                Stepper(value: $menuBarMaxWidth, in: 10...100) {
                    Text("Max width: \(menuBarMaxWidth) characters")
                }
            }
            .formStyle(.grouped)
        }
    }

    private var notifications: some View {
        tab {
            Form {
                Toggle("Notify on song change", isOn: $showNotifications)
                Text("If notifications don't appear, make sure "
                     + "Orpheus is allowed to notify in "
                     + "System Settings → Notifications.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private var hotkeys: some View {
        tab {
            Form {
                Text("Hotkey configuration UI coming soon.")
                Text("To bind a hotkey manually, write "
                     + "`<keyCode>,<modifierMask>` to the "
                     + "`hotkey.<action>` UserDefaults key with the "
                     + "`defaults write` command.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private var advanced: some View {
        tab {
            Form {
                Toggle("Pause on quit, resume on launch", isOn: $keepPianobarAlive)
                Text("Experimental. When enabled, quitting Orpheus pauses "
                     + "pianobar and leaves it running in the background; "
                     + "relaunching reattaches to the same instance and "
                     + "resumes the paused song exactly where it left off. "
                     + "Disable and quit once to stop pianobar cleanly.")
                    .font(.caption).foregroundStyle(.secondary)

                Divider().padding(.vertical, 4)

                Toggle("Log pianobar event payloads", isOn: $eventDebugLog)
                Text("Writes every event payload (including coverArt) to "
                     + "~/Library/Logs/PianobarGUI/events.log. Restart the "
                     + "app after toggling. Leave off in normal use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    private var account: some View {
        tab {
            Form {
                Button(role: .destructive) {
                    bootstrap.signOut()
                } label: {
                    Text("Sign Out of Pandora")
                }
                Text("Signing out stops playback, clears the stored Pandora "
                     + "credentials from the macOS Keychain, and forgets your "
                     + "last station.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
        }
    }

    /// Shared layout for every tab — gives each a consistent padded frame.
    @ViewBuilder
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            content()
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}
