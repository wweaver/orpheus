import SwiftUI
import AppKit
import PianobarCore

@main
struct PianobarGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var bootstrap = AppBootstrap()

    init() {
        // Writing to a FIFO whose reader (pianobar) just died raises SIGPIPE,
        // whose default disposition terminates the process. Ignore it so the
        // write fails with EPIPE and PianobarCtrl can surface it instead.
        signal(SIGPIPE, SIG_IGN)
        Prefs.registerDefaults()
        // Touch the registry so its atexit handler is installed before any
        // pianobar child is spawned.
        _ = PianobarPIDRegistry.shared
    }

    var body: some Scene {
        Window("Orpheus", id: "main") {
            RootView()
                .environmentObject(bootstrap)
                .task { await bootstrap.start() }
                .frame(minWidth: 320, idealWidth: 560,  maxWidth: 780,
                       minHeight: 120, idealHeight: 560, maxHeight: 560)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 560)

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
                LoginView(errorMessage: bootstrap.loginError) { email, password in
                    bootstrap.saveCredentials(email: email, password: password)
                }
            } else if let state = bootstrap.playbackState, let ctrl = bootstrap.ctrl {
                // Runtime errors (network drops, Pandora-side failures) live on
                // PlaybackState and used to have no reader at all: the only
                // ErrorBanner sat in a later `else if`, unreachable once
                // playback existed. Overlay it here so a mid-session failure
                // is visible instead of just freezing the progress bar.
                MainWindowView(state: state, ctrl: ctrl)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let message = state.errorBanner {
                            ErrorBanner(
                                message: message,
                                onRetry: nil,
                                onDismiss: { state.dismissErrorBanner() }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: state.errorBanner)
            } else if let startupError = bootstrap.startupError {
                VStack(spacing: 0) {
                    ErrorBanner(
                        message: startupError,
                        onRetry: { bootstrap.retryPlayback() },
                        onDismiss: { bootstrap.dismissStartupError() }
                    )
                    Spacer(minLength: 0)
                }
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
