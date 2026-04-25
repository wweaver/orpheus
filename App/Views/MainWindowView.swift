import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var historyVisible: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if let msg = state.errorBanner {
                ErrorBanner(message: msg, onRetry: nil,
                            onDismiss: { state.dismissErrorBanner() })
            }
            NavigationSplitView {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                detailWithOptionalHistory
            }
        }
    }

    /// Player on the left, History pane on the right. The pane is always part
    /// of the layout — its width animates between 0 and 260pt — which avoids
    /// a SwiftUI HStack-cache crash that triggered when toggling its presence
    /// conditionally with .transition.
    private var detailWithOptionalHistory: some View {
        HStack(spacing: 0) {
            NowPlayingView(state: state, ctrl: ctrl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 0) {
                Divider()
                HistoryView(state: state, ctrl: ctrl)
            }
            .frame(width: historyVisible ? 260 : 0)
            .clipped()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        historyVisible.toggle()
                    }
                } label: {
                    Image(systemName: historyVisible
                          ? "sidebar.trailing"
                          : "clock.arrow.circlepath")
                }
                .help(historyVisible ? "Hide history" : "Show history")
            }
        }
    }
}
