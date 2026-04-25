import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl
    @State private var historyPresented: Bool = false

    var body: some View {
        NavigationSplitView {
            StationsSidebarView(state: state, ctrl: ctrl)
        } detail: {
            NowPlayingView(state: state, ctrl: ctrl)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            historyPresented = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .help("Show history")
                    }
                }
                .sheet(isPresented: $historyPresented) {
                    NavigationStack {
                        HistoryView(state: state, ctrl: ctrl)
                            .frame(minWidth: 320, minHeight: 420)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { historyPresented = false }
                                }
                            }
                    }
                }
        }
    }
}
