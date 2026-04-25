import SwiftUI
import AppKit
import PianobarCore

@main
struct PianobarGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        Prefs.registerDefaults()
        // Touch the registry so its atexit handler is installed before any
        // pianobar child is spawned.
        _ = PianobarPIDRegistry.shared
    }

    var body: some Scene {
        WindowGroup("Orpheus", id: "main") {
            RootView()
                .environmentObject(bootstrap)
                .task { await bootstrap.start() }
                .frame(minWidth: 480, minHeight: 360, maxHeight: 640)
        }
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView().environmentObject(bootstrap)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(bootstrap)
        } label: {
            MenuBarLabel()
                .environmentObject(bootstrap)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Small wrapper so SwiftUI can re-create the main window content when the
/// WindowGroup opens a fresh instance. Keeps bootstrap-driven branching here.
struct RootView: View {
    @EnvironmentObject var bootstrap: AppBootstrap

    var body: some View {
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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep the app alive when the last window is closed so the menu bar stays put.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
