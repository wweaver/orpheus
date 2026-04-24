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
            .layoutPriority(1)  // Absorb flexible space, but let the history
                                // drawer keep its intrinsic size when tight.
            Divider()
            HistoryView(state: state, ctrl: ctrl)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
