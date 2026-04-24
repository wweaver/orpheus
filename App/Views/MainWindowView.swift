import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        VStack(spacing: 0) {
            if let msg = state.errorBanner {
                ErrorBanner(message: msg, onRetry: nil,
                            onDismiss: { state.dismissErrorBanner() })
            }
            NavigationSplitView {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl)
            }
        }
        // Anchor the history drawer to the bottom of the window; safeAreaInset
        // guarantees the split view's content never overlaps it and the drawer
        // never falls off-screen, regardless of window size.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HistoryView(state: state, ctrl: ctrl)
            }
            .background(.background)
        }
    }
}
