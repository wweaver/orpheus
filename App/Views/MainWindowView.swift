import SwiftUI
import AppKit
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
    /// Fixed sidebar width, so growing the window by exactly this amount
    /// leaves the player pane the size it was before the sidebar appeared.
    static let sidebarWidth: CGFloat = 220
    /// Height the history drawer occupies: divider + header row, plus the list
    /// when it's expanded (see HistoryView's fixed content height).
    private static let collapsedHistoryHeight: CGFloat = 34
    private static let expandedHistoryHeight: CGFloat = 34 + 181

    @State private var window: NSWindow?
    /// Tracks what the window width has already been adjusted for, so repeated
    /// `onChange` deliveries don't stack multiple resizes.
    @State private var widthIncludesSidebar: Bool?

    /// Space actually available to the player pane. `geo.size` is the whole
    /// split view including the sidebar and the history drawer, so passing it
    /// straight through made NowPlayingView lay out against room it doesn't
    /// have — which is how the volume slider ended up under the drawer.
    private func detailSize(in geo: GeometryProxy) -> CGSize {
        let sidebar: CGFloat = visibility == .detailOnly ? 0 : Self.sidebarWidth
        let history: CGFloat = showHistory(in: geo)
            ? (historyExpanded ? Self.expandedHistoryHeight : Self.collapsedHistoryHeight)
            : 0
        return CGSize(width: max(0, geo.size.width - sidebar),
                      height: max(0, geo.size.height - history))
    }

    private func showHistory(in geo: GeometryProxy) -> Bool {
        geo.size.height >= Self.historyThreshold
    }

    /// Grow the window when the sidebar appears and shrink it when it goes
    /// away, instead of dividing a fixed width between the two panes. At the
    /// small sizes this window is designed for, splitting the existing width
    /// squeezed the player down to an unusable sliver.
    private func syncWindowWidth(to newVisibility: NavigationSplitViewVisibility) {
        let wantsSidebar = newVisibility != .detailOnly
        guard widthIncludesSidebar != wantsSidebar else { return }
        let previous = widthIncludesSidebar
        widthIncludesSidebar = wantsSidebar
        // Nothing to do on first observation — just record the starting state.
        guard previous != nil, let window else { return }
        // Not animated: an animated resize reports intermediate widths to the
        // GeometryReader, and the ones below `collapseThreshold` would trip
        // auto-collapse mid-flight and fight the toggle that started it.
        WindowResizer.adjustWidth(of: window,
                                  by: wantsSidebar ? Self.sidebarWidth : -Self.sidebarWidth,
                                  animated: false)
    }

    var body: some View {
        GeometryReader { geo in
            NavigationSplitView(columnVisibility: $visibility) {
                StationsSidebarView(state: state, ctrl: ctrl)
                    .navigationSplitViewColumnWidth(Self.sidebarWidth)
            } detail: {
                VStack(spacing: 0) {
                    NowPlayingView(state: state, ctrl: ctrl, availableSize: detailSize(in: geo))
                    // Hidden at small heights, in keeping with the window's
                    // progressive-disclosure behavior — the drawer would
                    // otherwise crowd out the transport in Minimal mode.
                    if showHistory(in: geo) {
                        HistoryView(state: state, isExpanded: $historyExpanded)
                    }
                }
            }
            .background(WindowAccessor { window = $0 })
            .onChange(of: geo.size) { newSize in
                windowSize = newSize
                applyAutoCollapse(width: newSize.width)
            }
            .onChange(of: visibility) { newValue in
                rememberManualToggle(width: geo.size.width, newVisibility: newValue)
                syncWindowWidth(to: newValue)
            }
            .onAppear {
                windowSize = geo.size
                applyAutoCollapse(width: geo.size.width)
                syncWindowWidth(to: visibility)
            }
        }
    }

    private func applyAutoCollapse(width: CGFloat) {
        if userOverrideRaw == "hidden" {
            if visibility != .detailOnly { setVisibilityWithoutResizing(.detailOnly) }
            return
        }
        if userOverrideRaw == "visible" {
            // Dragging the window narrower than the threshold overrides a
            // previous "keep it open": at that width the sidebar would squeeze
            // the player into a sliver, which is the thing we're avoiding.
            if width < Self.collapseThreshold {
                userOverrideRaw = ""
                setVisibilityWithoutResizing(.detailOnly)
                return
            }
            if visibility != .all { setVisibilityWithoutResizing(.all) }
            return
        }
        let target: NavigationSplitViewVisibility =
            width < Self.collapseThreshold ? .detailOnly : .all
        if visibility != target { setVisibilityWithoutResizing(target) }
    }

    /// Change the sidebar without the window growing or shrinking to match.
    ///
    /// Auto-collapse reacts to a width the window *already* has — dragging past
    /// the threshold reveals the sidebar because there's now room for it.
    /// Resizing again on top of that would widen the window a second time for
    /// a sidebar the user never asked to toggle. Recording the new state up
    /// front makes the `syncWindowWidth` that follows a no-op.
    private func setVisibilityWithoutResizing(_ newValue: NavigationSplitViewVisibility) {
        widthIncludesSidebar = newValue != .detailOnly
        visibility = newValue
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
