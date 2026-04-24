import SwiftUI
import PianobarCore

struct PreferencesView: View {
    @EnvironmentObject var bootstrap: AppBootstrap
    @AppStorage(Prefs.Keys.audioQuality) var audioQuality: String = "high"
    @AppStorage(Prefs.Keys.showNotifications) var showNotifications: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowArtist) var menuBarShowArtist: Bool = true
    @AppStorage(Prefs.Keys.menuBarShowTitle)  var menuBarShowTitle: Bool = true
    @AppStorage(Prefs.Keys.menuBarMaxWidth)   var menuBarMaxWidth: Int = 40

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            menuBar.tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            notifications.tabItem { Label("Notifications", systemImage: "bell") }
            hotkeys.tabItem { Label("Hotkeys", systemImage: "keyboard") }
            account.tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .frame(width: 460, height: 300)
        .padding(20)
    }

    private var general: some View {
        Form {
            Picker("Audio quality", selection: $audioQuality) {
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
        }
    }

    private var menuBar: some View {
        Form {
            Toggle("Show artist", isOn: $menuBarShowArtist)
            Toggle("Show title",  isOn: $menuBarShowTitle)
            Stepper(value: $menuBarMaxWidth, in: 10...100) {
                Text("Max width: \(menuBarMaxWidth)")
            }
        }
    }

    private var notifications: some View {
        Form {
            Toggle("Notify on song change", isOn: $showNotifications)
        }
    }

    private var hotkeys: some View {
        Form {
            Text("Hotkey configuration coming soon. To set a hotkey manually, "
                 + "write `<keyCode>,<modifierMask>` to the `hotkey.<action>` "
                 + "UserDefaults key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var account: some View {
        Form {
            Button("Sign Out") {
                bootstrap.signOut()
            }
        }
    }
}
