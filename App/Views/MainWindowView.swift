import SwiftUI
import PianobarCore

struct MainWindowView: View {
    @ObservedObject var state: PlaybackState
    let ctrl: PianobarCtrl

    @State private var visibility: NavigationSplitViewVisibility = .all
    /// User's last explicit choice. nil = follow auto-collapse rule, true = stay
    /// hidden, false = stay visible.
    @AppStorage("sidebarUserOverride") private var userOverrideRaw: String = ""

    private static let collapseThreshold: CGFloat = 520

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $visibility) {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                NowPlayingView(state: state, ctrl: ctrl)
            }
            .onChange(of: geo.size.width) { newWidth in
                applyAutoCollapse(width: newWidth)
            }
            .onChange(of: visibility) { newValue in
                rememberManualToggle(width: geo.size.width, newVisibility: newValue)
            }
            .onAppear {
                applyAutoCollapse(width: geo.size.width)
            }
        }
    }

    private func applyAutoCollapse(width: CGFloat) {
        // If user has an explicit preference, honor it.
        if userOverrideRaw == "hidden" {
            if visibility != .detailOnly { visibility = .detailOnly }
            return
        }
        if userOverrideRaw == "visible" {
            if visibility != .all { visibility = .all }
            return
        }
        // Otherwise auto-toggle by width.
        let target: NavigationSplitViewVisibility =
            width < Self.collapseThreshold ? .detailOnly : .all
        if visibility != target { visibility = target }
    }

    private func rememberManualToggle(width: CGFloat, newVisibility: NavigationSplitViewVisibility) {
        // If the visibility now matches what auto would have chosen for this
        // width, treat that as "user agrees with auto" — clear the override.
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
