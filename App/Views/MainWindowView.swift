import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    @State private var visibility: NavigationSplitViewVisibility = .all
    @State private var windowSize: CGSize = .zero
    /// User's last explicit choice. nil = follow auto-collapse rule, true = stay
    /// hidden, false = stay visible.
    @AppStorage("sidebarUserOverride") private var userOverrideRaw: String = ""

    private static let collapseThreshold: CGFloat = 520

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $visibility) {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl, windowSize: windowSize)
            }
            .onChange(of: geo.size) { newSize in
                windowSize = newSize
                applyAutoCollapse(width: newSize.width)
            }
            .onChange(of: visibility) { newValue in
                rememberManualToggle(width: geo.size.width, newVisibility: newValue)
            }
            .onAppear {
                windowSize = geo.size
                applyAutoCollapse(width: geo.size.width)
            }
        }
    }

    private func applyAutoCollapse(width: CGFloat) {
        if userOverrideRaw == "hidden" {
            if visibility != .detailOnly { visibility = .detailOnly }
            return
        }
        if userOverrideRaw == "visible" {
            if visibility != .all { visibility = .all }
            return
        }
        let target: NavigationSplitViewVisibility =
            width < Self.collapseThreshold ? .detailOnly : .all
        if visibility != target { visibility = target }
    }

    private func rememberManualToggle(width: CGFloat, newVisibility: NavigationSplitViewVisibility) {
        let autoTarget: NavigationSplitViewVisibility =
            width < Self.collapseThreshold ? .detailOnly : .all
        if newVisibility == autoTarget {
            userOverrideRaw = ""
        } else if newVisibility == .detailOnly {
            userOverrideRaw = "hidden"
        } else {
            userOverrideRaw = "visible"
        }
    }
}
