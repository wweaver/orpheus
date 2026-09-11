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
                // Only a minimum. No upper bound, because the previous
                // 780x560 cap stopped anyone on a large display making the
                // player bigger; and no ideal, because `defaultSize` below
                // decides the opening size.
                .frame(minWidth: 320, minHeight: 120)
        }
        // `.contentMinSize`, not `.contentSize`. With `.contentSize` the window
        // is pinned to whatever size the content reports, and the player's
        // scrollable region is happy to be tiny — so the window opened as a
        // bare transport strip instead of showing the song. This honors the
        // minimum above while letting `defaultSize` set the opening frame and
        // the user resize freely from there.
        .windowResizability(.contentMinSize)
        // Tall enough to show album art, metadata, transport, progress, volume
        // and the history drawer at once; narrow, because the player reads
        // better as a column than a wide box.
        .defaultSize(width: 380, height: 660)
        .commands { PlaybackCommands(bootstrap: bootstrap) }

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
