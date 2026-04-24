import SwiftUI
import PianobarCore

@main
struct PianobarGUIApp: App {
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
            .task { await bootstrap.start() }
            .frame(minWidth: 680, minHeight: 420)
        }
        .windowResizability(.contentMinSize)
    }
}
