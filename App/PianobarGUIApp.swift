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
                    // MainWindowView is added in Task 13; for Task 10 the placeholder below is fine.
                    Text("Signed in. Waiting for MainWindowView (Task 13)…")
                        .padding()
                        .onAppear { _ = state; _ = ctrl }
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
