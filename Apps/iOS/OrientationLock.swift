// xcode: set sdk=iOS

import SwiftUI
import UIKit

/// Keeps the app upright, and lets only the player turn.
///
/// The Info.plist has to advertise landscape for the player to be allowed to use
/// it at all, but that also let every browsing screen rotate — a phone held
/// sideways on the sofa would reflow Home into a landscape layout nothing was
/// designed for. UIKit asks the delegate on every rotation, so the answer can be
/// "portrait, unless the player is up".
final class OrientationLock: NSObject, UIApplicationDelegate {
    /// Set by the player while it is on screen.
    nonisolated(unsafe) static var allowsLandscape = false

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.allowsLandscape ? .allButUpsideDown : .portrait
    }
}

extension View {
    /// Frees rotation for as long as this view is on screen.
    func allowsLandscapeWhilePresented() -> some View {
        modifier(LandscapeWhilePresented())
    }
}

private struct LandscapeWhilePresented: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                OrientationLock.allowsLandscape = true
                requestGeometryUpdate()
            }
            .onDisappear {
                OrientationLock.allowsLandscape = false
                requestGeometryUpdate()
            }
    }

    /// Tells UIKit to re-ask the delegate. Without this the new mask is only
    /// consulted the next time the device physically turns, so leaving the player
    /// would strand the app in landscape.
    ///
    /// Entering the player *asks for* landscape rather than merely allowing it.
    /// Rotation Lock makes iOS ignore the device's orientation altogether, so a
    /// permissive `.allButUpsideDown` mask left the player upright on a locked
    /// phone — the mask says what is permitted, not what to adopt. An explicit
    /// request is honoured regardless of the lock, which is how every video app
    /// turns sideways for you.
    ///
    /// The delegate still answers `.allButUpsideDown` while the player is up, so
    /// once it is in landscape an *unlocked* phone can still be turned freely,
    /// including to portrait for a vertically-shot video.
    private func requestGeometryUpdate() {
        // Filter to window scenes *first*, then pick the active one. Taking the
        // first active scene of any kind and casting afterwards meant a single
        // non-window scene at the head of the list made the cast fail, the guard
        // return, and this whole function silently do nothing — which is why the
        // player only ever turned when the phone was physically rotated with
        // Rotation Lock off. That path is the delegate mask, not this.
        // `.foregroundActive` is not yet true while a full-screen cover is being
        // presented — the scene is mid-transition — so requiring it meant the one
        // moment this needs to run was the one moment it bailed out. Prefer the
        // active scene, fall back to whatever window scene exists.
        let windowScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = windowScenes.first(where: { $0.activationState == .foregroundActive })
            ?? windowScenes.first
        else {
            #if DEBUG
            PlaybackController.tracePlayback("orientation: no active window scene")
            #endif
            return
        }

        // The *presented* controller, not the root one. The player is a
        // `fullScreenCover`, so it is presented over the root, and UIKit asks the
        // topmost controller for its supported orientations. Telling only the root
        // to re-read left the cover still reporting portrait, and a geometry
        // request outside what the top controller supports is refused.
        var top = scene.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        top?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()

        // Must be a subset of what the delegate permits or the request is refused,
        // so the delegate's flag is set before this runs, and the mask is re-read
        // above before the request goes in.
        let target: UIInterfaceOrientationMask =
            OrientationLock.allowsLandscape ? .landscapeRight : .portrait

        request(target, on: scene)

        #if DEBUG
        // Reports where it actually ended up. The retry below is silent on
        // success, so without this the log cannot tell "turned" from "never ran"
        // — and the simulator has no Rotation Lock, so the only place the real
        // question can be answered is a phone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let names = [0: "unknown", 1: "portrait", 2: "upsideDown",
                         3: "landscapeLeft", 4: "landscapeRight"]
            let now = scene.interfaceOrientation.rawValue
            PlaybackController.tracePlayback(
                "orientation: asked \(OrientationLock.allowsLandscape ? "landscape" : "portrait")"
                + " -> settled on \(names[now] ?? "?")"
            )
        }
        #endif
    }

    /// Asks for an orientation, retrying briefly if UIKit refuses.
    ///
    /// `setNeedsUpdateOfSupportedInterfaceOrientations` only *schedules* a
    /// re-query of the supported mask, and there is no completion to wait on. The
    /// first request therefore lands while UIKit still holds the mask from before
    /// the flag changed and is refused — traced as "Requested: landscapeRight;
    /// Supported: portrait" while the delegate was, a beat later, answering
    /// `.allButUpsideDown`. Retrying is the only way to close that gap; the
    /// handler runs on failure only, so a success ends it.
    private func request(
        _ target: UIInterfaceOrientationMask,
        on scene: UIWindowScene,
        attempt: Int = 0
    ) {
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { error in
            guard attempt < 6 else {
                #if DEBUG
                PlaybackController.tracePlayback("orientation: gave up after \(attempt) — \(error)")
                #endif
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                request(target, on: scene, attempt: attempt + 1)
            }
        }
    }
}
