import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 0) {
            if let msg = state.errorBanner {
                ErrorBanner(message: msg, onRetry: nil,
                            onDismiss: { /* Plan 2: add dismiss on state */ })
            }
            NavigationSplitView {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl)
            }
        }
    }
}
