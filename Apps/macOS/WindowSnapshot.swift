// xcode: set sdk=macOS

#if DEBUG
import AppKit
import QuartzCore

/// Renders the app's own window to a PNG.
///
/// `screencapture` needs Screen Recording permission, which this environment does
/// not have. An app drawing itself needs none.
///
/// **Only trustworthy immediately after launch.** SwiftUI composites through
/// layers this cannot force to re-render, so a capture taken after a state change
/// reproduces the launch frame — forcing `displayIfNeeded`, flushing the
/// transaction, and spinning the run loop all failed to change that. It was
/// verified against a section switch that visibly happened and did not appear in
/// the bitmap. Use it for launch-state layout only; anything interactive needs
/// Screen Recording granted so `screencapture -l <windowID>` can be used instead.
///
/// Debug-only: a development instrument, not a feature.
@MainActor
enum WindowSnapshot {

    static func capture(to path: String, window match: String? = nil) {
        // A hint targets a specific scene — the player, say — rather than
        // whichever window happens to be first.
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        let window = match.flatMap { hint in
            candidates.first { $0.identifier?.rawValue.contains(hint) == true }
        } ?? candidates.first
        guard let window else { return }

        // The theme frame rather than the content view: the toolbar and traffic
        // lights live in the title bar, which is not inside `contentView`.
        guard let frame = window.contentView?.superview else { return }

        // SwiftUI draws asynchronously, so a capture taken straight after a state
        // change rendered the previous frame. Forcing a display pass and letting
        // the run loop turn is what makes the bitmap match what is on screen.
        frame.setNeedsDisplay(frame.bounds)
        frame.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        frame.displayIfNeeded()

        guard let representation = frame.bitmapImageRepForCachingDisplay(in: frame.bounds)
        else { return }

        // Layer rendering, not `cacheDisplay`. SwiftUI hosts its content in
        // layer-backed views, and `cacheDisplay` returned a stale composite —
        // it kept showing the screen as it was at launch, so a navigation push
        // looked like it had never happened.
        if let layer = frame.layer,
           let context = NSGraphicsContext(bitmapImageRep: representation) {
            layer.render(in: context.cgContext)
        } else {
            frame.cacheDisplay(in: frame.bounds, to: representation)
        }

        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}
#endif
