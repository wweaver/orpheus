import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        NavigationSplitView {
            StationsSidebarView(state: state, ctrl: ctrl)
        } detail: {
            NowPlayingView(state: state, ctrl: ctrl)
        }
    }
}
