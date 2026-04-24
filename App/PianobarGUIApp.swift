import SwiftUI
import AppKit
import PianobarCore

@main
struct PianobarGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        Prefs.registerDefaults()
    }

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
            .task {
                appDelegate.attach(bootstrap: bootstrap)
                await bootstrap.start()
            }
            .frame(minWidth: 680, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    @MainActor
    func attach(bootstrap: AppBootstrap) {
        if menuBar == nil {
            menuBar = MenuBarController(bootstrap: bootstrap)
        }
    }
}
