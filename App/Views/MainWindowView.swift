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
    @AppStorage("historyExpanded") private var historyExpanded: Bool = false

    private static let collapseThreshold: CGFloat = 520
    /// Below this window height the history drawer is hidden entirely.
    private static let historyThreshold: CGFloat = 300

    /// Width actually available to the detail pane. `geo.size` is the whole
    /// split view, so passing it straight through made NowPlayingView compute
    /// its disclosure thresholds against the wrong width while the sidebar was
    /// open.
    private func detailSize(in geo: GeometryProxy) -> CGSize {
        let sidebarWidth: CGFloat = visibility == .detailOnly ? 0 : Self.assumedSidebarWidth
        return CGSize(width: max(0, geo.size.width - sidebarWidth), height: geo.size.height)
    }

    private static let assumedSidebarWidth: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $visibility) {
                StationsSidebarView(state: state, ctrl: ctrl)
            } detail: {
                VStack(spacing: 0) {
                    NowPlayingView(state: state, ctrl: ctrl, windowSize: detailSize(in: geo))
                    // Hidden at small heights, in keeping with the window's
                    // progressive-disclosure behavior — the drawer would
                    // otherwise crowd out the transport in Minimal mode.
                    if geo.size.height >= Self.historyThreshold {
                        HistoryView(state: state, isExpanded: $historyExpanded)
                    }
                }
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
