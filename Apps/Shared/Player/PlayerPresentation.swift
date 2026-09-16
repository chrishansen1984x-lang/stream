import SwiftUI
import StreamCore

/// Presents the player the way each platform expects.
///
/// iOS and tvOS take over the screen. macOS opens a **separate resizable window** —
/// a sheet there is modal and fixed-size, which is unusable for video and cannot
/// float on top.
extension View {
    func presentPlayer(
        item: Binding<RankedStream?>,
        context: PlaybackContext?,
        alternates: [RankedStream] = []
    ) -> some View {
        modifier(PlayerPresentation(item: item, context: context, alternates: alternates))
    }
}

private struct PlayerPresentation: ViewModifier {
    @Binding var item: RankedStream?
    let context: PlaybackContext?
    let alternates: [RankedStream]

    #if os(macOS)
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: item) { _, newValue in
            guard let newValue,
                  let context,
                  let request = PlaybackRequest(stream: newValue, context: context, alternates: alternates)
            else {
                item = nil
                return
            }
            // One player at a time: tear the previous window down before opening,
            // otherwise both keep decoding and both keep playing audio.
            MacPlayerWindow.closeExisting()
            openWindow(id: MacPlayerWindow.sceneID, value: request)
            // The window owns playback from here; clearing keeps the binding from
            // re-opening a second window on the next state change.
            item = nil
        }
    }
    #else
    /// Explicit types: the shorthand form makes Swift pick the two-argument
    /// `Binding(get:set:)` overload and fail to type-check.
    private var requestBinding: Binding<PlaybackRequest?> {
        Binding<PlaybackRequest?>(
            get: { () -> PlaybackRequest? in
                guard let item, let context else { return nil }
                return PlaybackRequest(stream: item, context: context, alternates: alternates)
            },
            set: { (newValue: PlaybackRequest?) in
                if newValue == nil { item = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(item: requestBinding) { request in
            PlayerView(request: request)
        }
    }
    #endif
}
