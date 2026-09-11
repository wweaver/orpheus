import SwiftUI
import AppKit

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
    /// Grow or shrink `window` horizontally by `delta`, keeping it on screen.
    ///
    /// Grows to the right where there's room, otherwise moves the window left
    /// so the extra width stays on the visible screen. Shrinking always takes
    /// the width off the right edge, so the window doesn't appear to jump.
    static func adjustWidth(of window: NSWindow, by delta: CGFloat, animated: Bool = true) {
        guard delta != 0 else { return }
        let current = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame

        var target = current
        target.size.width = max(window.minSize.width, current.width + delta)
        // Never exceed the screen.
        if let visible {
            target.size.width = min(target.size.width, visible.width)
        }
        // Keep the title bar anchored: AppKit frames are bottom-left origin, so
        // holding maxY fixed keeps the top edge where it was.
        target.origin.y = current.maxY - target.height

        if let visible, target.maxX > visible.maxX {
            target.origin.x = max(visible.minX, visible.maxX - target.width)
        }

        guard target != current else { return }
        window.setFrame(target, display: true, animate: animated)
    }
}
