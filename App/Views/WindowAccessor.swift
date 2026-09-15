import SwiftUI
import AppKit
import QuartzCore

/// Hands the enclosing `NSWindow` back to SwiftUI.
///
/// SwiftUI's `Window` scene gives no direct access to the `NSWindow`, but
/// showing or hiding a sidebar should change the window's *width* rather than
/// redistribute a fixed width between the two panes — the AppKit convention
/// (Mail, Notes, Finder, Xcode) and the only one that works when the window is
/// only a little wider than the sidebar itself.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `window` is nil until the view joins the hierarchy.
        DispatchQueue.main.async {
            if let window = view.window { onResolve(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { onResolve(window) }
        }
    }
}

enum WindowResizer {
    /// Duration of the window resize. Chosen to sit alongside SwiftUI's own
    /// sidebar reveal so the two read as a single motion rather than a jump
    /// followed by a slide.
    static let sidebarAnimationDuration: TimeInterval = 0.25

    /// Widen or narrow `window` by `delta`, moving the **right** edge.
    ///
    /// The sidebar lives on the right, so growing that edge outward leaves the
    /// detail pane at exactly the same place on screen — the sidebar simply
    /// occupies space that didn't exist a moment ago. Growing the left edge
    /// instead shoves the player 220pt sideways as the sidebar claims the
    /// right of the split, which is the bulk of the jerkiness.
    ///
    /// Falls back to moving the left edge when there isn't room to the right,
    /// e.g. the window is already against the edge of the screen.
    static func adjustWidth(
        of window: NSWindow,
        by delta: CGFloat,
        duration: TimeInterval = sidebarAnimationDuration,
        completion: @escaping () -> Void = {}
    ) {
        guard delta != 0 else { completion(); return }
        let current = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame

        var target = current
        target.size.width = max(window.minSize.width, current.width + delta)
        if let visible {
            target.size.width = min(target.size.width, visible.width)
        }
        // AppKit frames are bottom-left origin, so holding maxY fixed keeps the
        // title bar where it is.
        target.origin.y = current.maxY - target.height

        // Move the right edge; the left edge stays put.
        target.origin.x = current.minX

        if let visible {
            // Not enough room on the right — take it from the left instead.
            if target.maxX > visible.maxX {
                target.origin.x = visible.maxX - target.width
            }
            if target.minX < visible.minX {
                target.origin.x = visible.minX
            }
        }

        guard target != current else { completion(); return }

        guard duration > 0 else {
            window.setFrame(target, display: true)
            completion()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(target, display: true)
        }, completionHandler: completion)
    }
}
