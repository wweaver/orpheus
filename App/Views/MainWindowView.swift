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

    /// Player on the left, optional History pane on the right. Toolbar
    /// button toggles the history pane in/out with an animation.
    private var detailWithOptionalHistory: some View {
        HStack(spacing: 0) {
            NowPlayingView(state: state, ctrl: ctrl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if historyVisible {
                Divider()
                HistoryView(state: state, ctrl: ctrl)
                    .frame(width: 260)
                    .transition(.move(edge: .trailing))
            }
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
