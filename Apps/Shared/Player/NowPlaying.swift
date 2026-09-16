import Foundation
import MediaPlayer

/// Puts the player behind the system's own transport controls.
///
/// Without this the app never becomes the system's "now playing" app, so a squeeze
/// on an AirPod stem, a tap on a media key, Control Centre, the Lock Screen and a
/// car's steering-wheel button all go to whichever app the system considers
/// default — in practice Music, which is why asking Stream to pause launched Music
/// instead and left the film running.
///
/// Two halves, and both are required: `MPRemoteCommandCenter` accepts the button
/// presses, and `MPNowPlayingInfoCenter` is what actually claims the slot. Register
/// the commands without publishing now-playing info and the system still has no
/// reason to route anything here.
@MainActor
final class NowPlaying {

    /// What the transport buttons should do. Set once, by the controller.
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var toggle: () -> Void
        var skip: (Double) -> Void
        var seek: (Double) -> Void
    }

    private var handlers: Handlers?
    private var registered = false

    /// Claims the transport controls and starts answering them.
    func activate(handlers: Handlers) {
        self.handlers = handlers
        guard !registered else { return }
        registered = true

        let centre = MPRemoteCommandCenter.shared()

        centre.playCommand.addTarget { [weak self] _ in
            self?.handlers?.play()
            return .success
        }
        centre.pauseCommand.addTarget { [weak self] _ in
            self?.handlers?.pause()
            return .success
        }
        // The one an AirPod stem sends.
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.handlers?.toggle()
            return .success
        }
        centre.skipForwardCommand.preferredIntervals = [10]
        centre.skipBackwardCommand.preferredIntervals = [10]
        centre.skipForwardCommand.addTarget { [weak self] event in
            let by = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.handlers?.skip(by)
            return .success
        }
        centre.skipBackwardCommand.addTarget { [weak self] event in
            let by = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            self?.handlers?.skip(-by)
            return .success
        }
        // Lets the Lock Screen and Control Centre scrubbers work, not just the
        // buttons.
        centre.changePlaybackPositionCommand.isEnabled = true
        centre.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            self?.handlers?.seek(position)
            return .success
        }

        for command in [
            centre.playCommand, centre.pauseCommand, centre.togglePlayPauseCommand,
            centre.skipForwardCommand, centre.skipBackwardCommand
        ] {
            command.isEnabled = true
        }
        // Explicitly off, so the system offers skip rather than track-change
        // buttons it has nothing to do with — a film has no next track.
        centre.nextTrackCommand.isEnabled = false
        centre.previousTrackCommand.isEnabled = false
    }

    /// Publishes what is playing. This is the half that claims the slot.
    func update(title: String, elapsed: Double, duration: Double?, rate: Double) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue
        ]
        if let duration, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        // macOS will not show the app in its now-playing UI without this, and the
        // media keys stay pointed elsewhere.
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
        #endif
    }

    /// Hands the controls back when the player closes, so a later stem press does
    /// not resume a torn-down session.
    func deactivate() {
        handlers = nil
        // The command centre is a singleton and this is not: every player session
        // used to add another set of targets and remove none, for the life of the
        // process.
        let centre = MPRemoteCommandCenter.shared()
        for command in [
            centre.playCommand, centre.pauseCommand, centre.togglePlayPauseCommand,
            centre.skipForwardCommand, centre.skipBackwardCommand,
            centre.changePlaybackPositionCommand
        ] {
            command.removeTarget(nil)
        }
        registered = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
    }
}
