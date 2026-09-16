import SwiftUI
import AVFoundation
import SwiftVLC

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Renders whichever engine is active behind one view.
///
/// AVKit's `VideoPlayer` is deliberately avoided: it brings its own transport UI,
/// which would mean two different control designs depending on the decode path.
/// A bare layer plus the shared overlay keeps playback identical either way.
struct VideoSurface: View {
    let controller: PlaybackController

    var body: some View {
        switch controller.engine {
        case .avPlayer:
            if let player = controller.avPlayer {
                PlayerLayerView(player: player)
            } else {
                Color.black
            }
        case .software:
            if let player = controller.vlcPlayer {
                SwiftVLC.VideoView(player)
            } else {
                Color.black
            }
        }
    }
}

#if canImport(UIKit)

/// `AVPlayerLayer` in a plain view — video only, no controls.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerBackedView {
        let view = PlayerLayerBackedView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerBackedView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerLayerBackedView: UIView {
    // Backing the view with AVPlayerLayer means resizing is handled by the layout
    // system rather than manual frame syncing.
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

#else

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        // The layer must track the window as it is resized — this is what lets the
        // macOS player be dragged down to a small window without the video drifting.
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.frame = view.bounds
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(playerLayer)
        context.coordinator.playerLayer = playerLayer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.playerLayer?.frame = nsView.bounds
        if context.coordinator.playerLayer?.player !== player {
            context.coordinator.playerLayer?.player = player
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var playerLayer: AVPlayerLayer?
    }
}

#endif
