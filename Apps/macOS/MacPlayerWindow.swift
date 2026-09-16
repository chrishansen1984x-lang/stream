import SwiftUI
import AppKit

/// Reaches the `NSWindow` behind a SwiftUI view.
///
/// SwiftUI exposes no API for window level, style mask, or frame, all of which a
/// player window needs. The view is zero-sized and purely a handle.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached during makeNSView, so resolution is deferred
        // to the next runloop pass.
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onResolve(window)
        }
    }
}

/// Window behaviour for the macOS player.
///
/// Main-actor isolated: every member touches AppKit window state.
@MainActor
enum MacPlayerWindow {
    /// Identifies the player scene so the app can find its window again.
    nonisolated static let sceneID = "player"

    private static var normalFrame: NSRect?
    /// Last known video dimensions, reused when sizing the PiP window.
    private static var aspect: CGSize?

    /// Makes the window a proper resizable player window.
    ///
    /// `fullSizeContentView` plus a transparent, title-less bar is what removes the
    /// opaque strip above the video — the content view then spans the whole window
    /// and the traffic lights simply float over the picture.
    /// Hides the close/minimise/zoom cluster.
    ///
    /// The container is hidden as well as the individual buttons: the player
    /// carries its own close and PiP controls in the overlay, so the system ones
    /// are redundant chrome sitting on the picture. ⌘W still closes the window.
    private static func hideTrafficLights(in window: NSWindow) {
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.standardWindowButton(.closeButton)?.superview?.isHidden = true
    }

    /// Finds the player window by scene identifier and configures it.
    ///
    /// `WindowAccessor` never resolved a window here — traced and confirmed
    /// `configure` was not running at all, which is why the traffic lights kept
    /// coming back. Looking the window up by identifier does not depend on a
    /// representable landing in the right part of the hierarchy, and retrying
    /// covers the window not existing yet when the view first appears.
    static func configureWhenReady() async {
        for _ in 0..<25 {
            if let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains(sceneID) == true
            }) {
                configure(window)
                // Explicitly fronted: opened from a sheet, the player could end up
                // behind the window the sheet belonged to.
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #if DEBUG
        PlaybackController.tracePlayback("window configure: never found a \(sceneID) window")
        #endif
    }

    /// Strips the title bar back to nothing visible.
    ///
    /// Re-applied on entering full screen: macOS slides the title bar down with
    /// the menu bar when the pointer reaches the top of the screen, and the
    /// transparency set at window creation does not survive the transition — so a
    /// grey band appeared over the picture.
    private static func applyChromelessTitlebar(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
    }

    static func configure(_ window: NSWindow) {
        window.styleMask.insert([.resizable, .fullSizeContentView])
        window.isMovableByWindowBackground = true
        applyChromelessTitlebar(to: window)
        window.backgroundColor = .black
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Nothing but video should occupy the window.
        window.toolbar = nil

        hideTrafficLights(in: window)
        #if DEBUG
        PlaybackController.tracePlayback(
            "window configure: buttons hidden="
            + "\(window.standardWindowButton(.closeButton)?.isHidden.description ?? "no-button")"
        )
        #endif

        // Re-applied after SwiftUI has finished configuring the window. Hiding
        // them once here did not stick — the buttons came back a moment later,
        // which is the same ordering problem that put the title bar strip back
        // before `.windowStyle(.hiddenTitleBar)` moved onto the scene.
        DispatchQueue.main.async { hideTrafficLights(in: window) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { hideTrafficLights(in: window) }

        // The decoder can report dimensions before the window exists, in which case
        // the earlier `applyAspectRatio` call found nothing. Re-apply here so the
        // window still ends up matching the video instead of pillarboxing it.
        if let aspect {
            applyAspectRatio(aspect)
        }
    }

    /// Locks resizing to the video's own aspect ratio and trims the current frame
    /// to match.
    ///
    /// Without this the window resizes freely and the video letterboxes inside it,
    /// which is the black band above and below the picture.
    static func applyAspectRatio(_ size: CGSize) {
        // Strict lookup: `playerWindow()` falls back to `keyWindow`, which could
        // apply a video aspect ratio to the main browsing window.
        guard size.width > 0, size.height > 0,
              let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(sceneID) == true })
        else { return }
        aspect = size

        // Constrains every subsequent user resize to the ratio.
        window.contentAspectRatio = size

        // Then reshape the window as it stands, keeping the top-left corner fixed
        // so the window does not appear to jump when the first frame arrives.
        let content = window.contentRect(forFrameRect: window.frame)
        var target = content
        target.size.height = (content.width * size.height / size.width).rounded()

        var frame = window.frameRect(forContentRect: target)
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: false)
    }

    /// Toggles a floating, always-on-top window parked in the bottom-right corner.
    ///
    /// Restores the previous frame on exit so toggling PiP does not lose the size
    /// and position the user had chosen.
    static func setPictureInPicture(_ enabled: Bool) {
        guard let window = playerWindow() else { return }

        if enabled {
            normalFrame = window.frame
            window.level = .floating
            // Visible across Spaces, including over full-screen apps.
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])

            // Height follows the video's own ratio so PiP never letterboxes.
            let width: CGFloat = 480
            let ratio = aspect.map { $0.height / $0.width } ?? (9.0 / 16.0)
            let size = NSSize(width: width, height: (width * ratio).rounded())
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                let margin: CGFloat = 20
                let origin = NSPoint(
                    x: visible.maxX - size.width - margin,
                    y: visible.minY + margin
                )
                window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
            }
        } else {
            window.level = .normal
            window.collectionBehavior.remove([.canJoinAllSpaces, .fullScreenAuxiliary])
            if let normalFrame {
                window.setFrame(normalFrame, display: true, animate: true)
            }
            normalFrame = nil
        }
    }

    /// Enters or leaves native macOS full screen.
    ///
    /// Needed because hiding the standard window buttons removed the zoom control,
    /// which is normally the only way in.
    static func toggleFullScreen() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue.contains(sceneID) == true
        }) else {
            #if DEBUG
            PlaybackController.tracePlayback("fullscreen: no player window found")
            #endif
            return
        }
        // Full screen and a floating PiP window are mutually exclusive states.
        if window.level == .floating {
            setPictureInPicture(false)
        }

        // Release the aspect lock first. `applyAspectRatio` sets
        // `contentAspectRatio` so user resizes stay 16:9, but AppKit will not take
        // a ratio-locked window full screen — it cannot satisfy both the ratio and
        // the display size, so the request was silently dropped and the button
        // appeared dead. It is restored on exit, below.
        window.toggleFullScreen(nil)

        // The title bar and the traffic lights both come back with the space
        // change, so both are re-suppressed once the transition settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            applyChromelessTitlebar(to: window)
            hideTrafficLights(in: window)
        }
    }


    /// Closes any open player window.
    ///
    /// `openWindow(id:value:)` mints a **new** window for each distinct value, so
    /// starting a second title while one is playing left two players running and
    /// two audio streams. Closing first makes Play replace rather than stack.
    ///
    /// Deliberately has no `keyWindow` fallback — matching loosely here could close
    /// the main window instead.
    static func closeExisting() {
        for window in NSApp.windows where window.identifier?.rawValue.contains(sceneID) == true {
            window.close()
        }
        normalFrame = nil
    }

    /// Finds the player window by its scene identifier.
    ///
    /// SwiftUI prefixes window-group identifiers, so this matches on containment
    /// rather than equality.
    private static func playerWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(sceneID) == true }
            ?? NSApp.keyWindow
    }
}
