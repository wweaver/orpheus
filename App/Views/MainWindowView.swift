import SwiftUI
import PianobarCore

/// Test 1: NowPlayingView only — no sidebar, no NavigationSplitView.
/// If this is stable, the bug is in StationsSidebarView and/or
/// NavigationSplitView and we know how to compose around them.
struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    var body: some View {
        NowPlayingView(state: state, ctrl: ctrl)
    }
}
