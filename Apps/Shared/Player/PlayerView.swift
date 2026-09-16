import SwiftUI
import StreamCore

/// Selects a playback engine from source metadata.
enum PlaybackRouter {

    /// Containers eligible for AVPlayer. Unknown containers use libVLC.
    private static let avPlayerContainers: Set<String> = ["mp4", "m4v", "mov"]

    /// Uses the addon filename, falling back to the playback URL extension.
    /// Container and audio metadata are hints; PlaybackController handles runtime fallback.
    static func engine(for item: RankedStream) -> PlaybackController.Engine {
        let container = item.stream.behaviorHints?.containerExtension
            ?? item.stream.playbackURL.flatMap { $0.pathExtension.isEmpty ? nil : $0.pathExtension.lowercased() }

        guard let container, avPlayerContainers.contains(container) else {
            return .software
        }
        if item.attributes.audioCodec?.requiresSoftwareDecode == true {
            return .software
        }
        return .avPlayer
    }
}

/// A resolved source, reduced to what playback actually needs.
///
/// `Codable`/`Hashable` because macOS opens the player as a separate window scene,
/// and SwiftUI requires window values to round-trip through state restoration.
struct PlaybackRequest: Codable, Hashable, Identifiable {
    var url: URL
    var title: String
    var preferSoftware: Bool
    /// Identity for watch tracking, carried through so the player can record
    /// progress without needing to reach back into the detail screen.
    var videoId: String
    var metaId: String
    var type: MediaType
    var startAt: Duration?
    var metaName: String?
    var poster: String?
    /// Advertised source size, used by preflight to detect placeholder clips.
    var expectedBytes: Int64?
    /// Remaining sources in ranked order for automatic fallback, including
    /// when preflight detects a playable provider error clip.
    var alternates: [Alternate] = []

    struct Alternate: Codable, Hashable, Sendable {
        var url: URL
        var expectedBytes: Int64?
        var preferSoftware: Bool
    }

    var id: String { url.absoluteString }

    #if DEBUG
    /// Creates a request with placeholder tracking fields for the `stream://play` debug link.
    init(previewing url: URL, title: String, software: Bool = false, startAt: Duration? = nil) {
        self.url = url
        self.title = title
        self.preferSoftware = software
        self.startAt = startAt
        self.videoId = "preview"
        self.metaId = "preview"
        self.type = .movie
    }
    #endif

    init?(stream: RankedStream, context: PlaybackContext, alternates: [RankedStream] = []) {
        guard let url = stream.stream.playbackURL else { return nil }
        self.url = url
        self.title = context.title
        self.preferSoftware = PlaybackRouter.engine(for: stream) == .software
        // `videoSize` only. `folderSize` is the whole torrent folder — a healthy
        // episode measured at 15% of it, which a size check would reject.
        self.expectedBytes = stream.stream.behaviorHints?.videoSize.map(Int64.init)
        self.videoId = context.videoId
        self.metaId = context.metaId
        self.type = context.type
        self.startAt = context.startAt
        self.metaName = context.metaName
        self.poster = context.poster
        // Deduplicate the selected source and alternates so fallback does not
        // probe the same URL twice when multiple addons return it.
        var seen: Set<URL> = [url]
        self.alternates = alternates.compactMap { candidate in
            guard let alternateURL = candidate.stream.playbackURL,
                  seen.insert(alternateURL).inserted else { return nil }
            return Alternate(
                url: alternateURL,
                expectedBytes: candidate.stream.behaviorHints?.videoSize.map(Int64.init),
                preferSoftware: PlaybackRouter.engine(for: candidate) == .software
            )
        }
    }
}

/// Everything the player needs that isn't the stream itself.
struct PlaybackContext: Hashable {
    var videoId: String
    var metaId: String
    var type: MediaType
    var title: String
    var startAt: Duration?
    /// Snapshot for the continue-watching shelf, so it needs no metadata lookup.
    var metaName: String?
    var poster: String?
}

struct PlayerView: View {
    let request: PlaybackRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var controller: PlaybackController
    @State private var areControlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// tvOS only, but `@FocusState` compiles everywhere and keeping it
    /// unconditional avoids bracketing every use site.
    /// Where focus is, on tvOS.
    ///
    /// One enum rather than a `@FocusState` Bool per control. Separate Bools can
    /// only be *cleared*, never handed on, so "leave the scrubber" meant dropping
    /// focus and letting the focus engine re-target — which usually put it back on
    /// the scrubber, because nothing said where it should go instead.
    private enum PlayerFocus: Hashable {
        case surface
        case playPause
        case scrubber
    }
    @FocusState private var focus: PlayerFocus?
    /// Where the drag currently is, held for as long as the gesture lasts so the
    /// knob answers to the pointer rather than to the decoder's clock.
    @State private var scrubTarget: Double?
    /// Throttles the keyframe seeks issued during a drag.
    @State private var lastScrubSeek: Date = .distantPast
    /// One automatic engine fallback per player, so a source libVLC also cannot
    /// open does not loop.
    @State private var didAutoRetry = false
    #if os(tvOS)
    /// tvOS presents audio and subtitle tracks as a focusable list rather than a menu.
    @State private var isShowingTracks = false
    #endif
    /// Whether Screen has been told about this sitting yet. One report while the
    /// film is on is enough; the closing report then corrects the position.
    @State private var didReportToScreen = false
    /// When Trakt last heard from this sitting. See `recordProgress`.
    @State private var lastTraktPush: Date = .distantPast
    @State private var isFloating = false
    @State private var isFullScreen = false

    /// What is playing *now*. Distinct from `request`, which is only the item the
    /// player opened on — auto-advance replaces this without a new window.
    @State private var active: PlaybackRequest
    @State private var isAdvancing = false

    private var url: URL { active.url }
    private var title: String { active.title }

    init(request: PlaybackRequest) {
        self.request = request
        _active = State(initialValue: request)
        _controller = State(
            initialValue: PlaybackController(engine: request.preferSoftware ? .software : .avPlayer)
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoSurface(controller: controller)
                .ignoresSafeArea()

            // Separate hit layer: the engines' video views are UIView/NSView-backed
            // and swallow taps, so a gesture attached to the surface never fires.
            //
            // On tvOS it is also the player's focus anchor. The controls are taken
            // out of the hierarchy when they auto-hide, and they are the only
            // focusable views in here — so focus left the player entirely and the
            // remote's buttons, Play/Pause included, were delivered to nothing.
            // This keeps a focus target behind the video whenever the controls are
            // away, which is what makes the remote work at all.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
                #if os(tvOS)
                // Never focusable while an overlay owns the screen. It used to be,
                // and four seconds after a playback failure the auto-hide timer
                // pulled focus off "Try the software decoder" and "Close" onto this
                // invisible layer — leaving two buttons on screen that showed no
                // focus and answered to nothing.
                .focusable(!areControlsVisible && !isFailed && !isAdvancing)
                .focused($focus, equals: .surface)
                // Left and right seek from here too. `onMoveCommand` consumes every
                // direction it is attached to, so merely waking the controls left
                // the swipe doing nothing at all — the scrubber never saw it.
                .onMoveCommand { direction in
                    switch direction {
                    case .left: seekFromRemote(by: -10)
                    case .right: seekFromRemote(by: 10)
                    default: break
                    }
                    revealControls()
                }
                #endif

            if case .failed(let reason) = controller.status {
                failureOverlay(reason)
            } else if controller.status == .loading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    // Only while stepping past a rejected source. A silent minute
                    // reads as a hang.
                    if let note = controller.loadingNote {
                        Text(note)
                            .font(Theme.Typography.meta)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
            }

            #if os(tvOS)
            // Removed outright on tvOS, because the surface layer's focus handling
            // depends on the controls genuinely leaving the hierarchy.
            if showsControls {
                controlsOverlay
                    .transition(.opacity)
                transportButtons
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            #else
            // Mounted always, faded rather than removed. The auto-hide timer keeps
            // running while a menu is open, and a menu belongs to the view that
            // presented it — so with eleven subtitle tracks to read through, the
            // controls were torn out from under the open menu four seconds in and
            // the click landed on nothing. Same lesson as the keyboard shortcuts:
            // a view that is not in the hierarchy does not work.
            Group {
                controlsOverlay

                // A sibling of the video, not a child of the controls stack.
                // Inside that stack it centred on a frame the window's safe area
                // had already pushed down, which still left it below the middle
                // of the picture.
                transportButtons
                    // Centres on the picture, not on the safe-area-inset frame.
                    // macOS insets only the top, so without this the row sat
                    // consistently below the middle of the video.
                    .ignoresSafeArea()
            }
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)
            #endif

            if isAdvancing {
                ResolvingOverlay { dismiss() }
            }

            #if os(macOS)
            keyboardCommands
            #endif

        }
        .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
        #if os(tvOS)
        // The remote's dedicated Play/Pause button. macOS has had the space bar
        // since the keyboard work; tvOS had nothing bound at all, so the only way
        // to pause was to move focus onto the on-screen button — which is not what
        // anyone reaches for, and is unreachable while the controls are hidden.
        //
        // tvOS delivers this along the focused view's responder chain, so it only
        // arrives while something inside this stack holds focus. The surface layer
        // above is what guarantees that.
        .onPlayPauseCommand {
            controller.togglePlayPause()
            revealControls()
        }
        // Focus follows the controls. Parking it on the surface when they hide is
        // what keeps the remote alive; handing it to the scrubber when they return
        // is what makes left and right scrub instead of only waking the overlay.
        .onChange(of: areControlsVisible) { _, visible in
            // Not while an overlay owns the screen — its buttons are the only
            // things that should hold focus then.
            guard !isFailed, !isAdvancing else { return }
            focus = visible ? .scrubber : .surface
        }
        #endif
        .task {
            controller.preferredAudioLanguage = model.preferredLanguage
            // Names the film in Control Centre, on the Lock Screen, and wherever
            // else the system shows what is playing.
            controller.nowPlayingTitle = title
            controller.completionThreshold = WatchProgress.completionThreshold(for: active.type)
            controller.load(
                url: url,
                startAt: active.startAt,
                expectedBytes: active.expectedBytes,
                alternates: active.alternates
            )
            scheduleControlsHide()
        }
        .task {
            // Checkpoint periodically as well as on exit: the app can be killed
            // while playing, and losing the position is worse than a small write.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                recordProgress()
            }
        }
        .onChange(of: controller.status) { _, status in
            if status == .ended {
                Task { await finishAndAdvance() }
                return
            }
            // Falls back on its own, once. Routing is a heuristic on addon
            // metadata rather than a probe, so AVPlayer will still occasionally be
            // handed something it cannot decode — and making the viewer read an
            // error and press a button to run the retry we already know how to run
            // is just asking them to do it for us. The button stays for the case
            // where this fails too.
            if case .failed = status, controller.canRetryWithSoftwareEngine, !didAutoRetry {
                didAutoRetry = true
                controller.retryWithSoftwareEngine()
            }
        }
        #if os(tvOS)
        .sheet(isPresented: $isShowingTracks) { trackChooser }
        #endif
        .onDisappear {
            hideTask?.cancel()
            recordProgress(closing: true)
            // The closing report, which carries the final position. The first one
            // has usually already gone from a checkpoint; this is what corrects it.
            // A finished film is reported by the completion hook instead.
            if let saved = model.watchState.progress(for: active.videoId) {
                model.reportProgressToScreen(saved)
            }
            controller.teardown()
        }
        #if os(iOS)
        // Always, not behind a toggle. The player owns the whole screen for as
        // long as it is up, so the home indicator and status bar have nothing to
        // say — and the button that used to control this is gone.
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        // Only the player turns; the browsing screens stay upright.
        .allowsLandscapeWhilePresented()
        #endif
        #if os(macOS)
        // Small enough to sit in a corner as a PiP; the window itself stays freely
        // resizable above this floor.
        .frame(minWidth: 320, minHeight: 180)
        .background(WindowAccessor { window in
            MacPlayerWindow.configure(window)
        })
        // Belt and braces: the accessor above was silently doing nothing.
        .task { await MacPlayerWindow.configureWhenReady() }
        // Applied once the decoder reports dimensions: locks user resizing to the
        // video's ratio and trims the letterbox bands off the current frame.
        .onChange(of: controller.videoSize) { _, size in
            guard let size else { return }
            // One pass now, one after the window has settled: SwiftUI may still be
            // sizing the scene when the first frame arrives.
            MacPlayerWindow.applyAspectRatio(size)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                MacPlayerWindow.applyAspectRatio(size)
            }
        }
        #endif
    }

    /// Whether the controls should be visible and operable.
    private var showsControls: Bool { areControlsVisible && !isFailed && !isAdvancing }

    /// Current audio track, as a selection the menu's `Picker` can bind to.
    private var audioSelection: Binding<String?> {
        Binding(
            get: { controller.audioTracks.first(where: \.isSelected)?.id },
            set: { if let id = $0 { controller.selectAudioTrack(id: id) } }
        )
    }

    /// Current subtitle track, where `nil` is Off.
    private var subtitleSelection: Binding<String?> {
        Binding(
            get: { controller.subtitleTracks.first(where: \.isSelected)?.id },
            set: { controller.selectSubtitleTrack(id: $0) }
        )
    }

    #if os(tvOS)
    /// Audio and subtitle tracks, as a list the remote can actually walk.
    private var trackChooser: some View {
        NavigationStack {
            List {
                if controller.audioTracks.count > 1 {
                    Section {
                        ForEach(controller.audioTracks) { track in
                            trackRow(track.displayName, isSelected: track.isSelected) {
                                controller.selectAudioTrack(id: track.id)
                            }
                        }
                    } header: {
                        Text("Audio").settingsSectionHeader()
                    }
                }

                if !controller.subtitleTracks.isEmpty {
                    Section {
                        trackRow(
                            "Off",
                            isSelected: !controller.subtitleTracks.contains(where: \.isSelected)
                        ) {
                            controller.selectSubtitleTrack(id: nil)
                        }
                        ForEach(controller.subtitleTracks) { track in
                            trackRow(track.displayName, isSelected: track.isSelected) {
                                controller.selectSubtitleTrack(id: track.id)
                            }
                        }
                    } header: {
                        Text("Subtitles").settingsSectionHeader()
                    }
                }
            }
            .themedBackground()
        }
    }

    /// A real conditional checkmark.
    ///
    /// The button-based menu this replaces carried its state as
    /// `systemImage: isSelected ? "checkmark" : ""` — an empty symbol name, which
    /// renders nothing — so no row ever looked chosen and the menu read as broken.
    private func trackRow(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer(minLength: 24)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
    }
    #endif

    /// Uniform circular control, so the row stays aligned regardless of which
    /// buttons a given stream needs.
    private func playerControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: Theme.isTelevision ? 30 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(
                width: Theme.isTelevision ? 72 : 34,
                height: Theme.isTelevision ? 72 : 34
            )
            .background(.black.opacity(0.45), in: Circle())
    }

    /// Steps the position and keeps the controls up while the user is working.
    ///
    /// Each press is a discrete seek rather than a drag, so `isScrubbing` is not
    /// set — there is no drag gesture for periodic time updates to fight with.
    private func seekFromRemote(by seconds: Int) {
        controller.skip(by: .seconds(seconds))
        hideTask?.cancel()
        scheduleControlsHide()
    }

    private var progressFraction: Double {
        guard let duration = controller.duration, duration > .zero else { return 0 }
        return min(1, max(0, controller.currentTime.seconds / duration.seconds))
    }

    private var isFailed: Bool {
        if case .failed = controller.status { return true }
        return false
    }

    // MARK: - Controls

    private var controlsOverlay: some View {
        VStack {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: Theme.isTelevision ? 30 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(Theme.isTelevision ? 0 : 10)
                        .background(
                            Theme.isTelevision ? Color.clear : .black.opacity(0.45),
                            in: Circle()
                        )
                }
                .transportButtonStyle()

                Spacer()

                // Multi-language releases frequently default to a track that is
                // not the viewer's language, and there was no way to change it.
                if controller.audioTracks.count > 1 || !controller.subtitleTracks.isEmpty {
                    #if os(tvOS)
                    // Not a `Menu` on the TV. `Menu` containing `Picker(.inline)`
                    // is a macOS/iOS pattern — `.menuStyle(.borderlessButton)` and
                    // `.menuIndicator(.hidden)` beside it are the giveaway — and it
                    // is not a supported tvOS combination, so the rows either did
                    // not draw as selectable or never committed. Every television
                    // player uses a plain focusable list; this is that.
                    Button {
                        isShowingTracks = true
                    } label: {
                        playerControlIcon("captions.bubble")
                    }
                    .transportButtonStyle()
                    #else
                    // Pickers, not lists of buttons. The buttons carried their
                    // selection state as `systemImage: isSelected ? "checkmark" : ""`
                    // — an empty symbol name — and a macOS menu renders a `Label` as
                    // text alone anyway, so nothing was ever ticked, including
                    // "Off". A menu with no indication of what is currently on reads
                    // as a menu that does not work. A `Picker` draws that itself.
                    Menu {
                        if controller.audioTracks.count > 1 {
                            Picker("Audio", selection: audioSelection) {
                                ForEach(controller.audioTracks) { track in
                                    Text(track.displayName).tag(String?.some(track.id))
                                }
                            }
                            .pickerStyle(.inline)
                        }

                        if !controller.subtitleTracks.isEmpty {
                            Picker("Subtitles", selection: subtitleSelection) {
                                Text("Off").tag(String?.none)
                                ForEach(controller.subtitleTracks) { track in
                                    Text(track.displayName).tag(String?.some(track.id))
                                }
                            }
                            .pickerStyle(.inline)
                        }
                    } label: {
                        playerControlIcon("captions.bubble")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Audio and subtitles")
                    #endif
                }

                #if os(macOS)
                // macOS only. On the phone the player already fills the screen and
                // now turns to landscape by itself, so the button toggled nothing
                // the viewer could see except the status bar.
                Button {
                    toggleFullScreen()
                } label: {
                    playerControlIcon(isFullScreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help(isFullScreen ? "Exit full screen" : "Full screen")
                #endif

                #if os(macOS)
                // True PiP is unavailable to us on macOS — SwiftVLC gates it behind a
                // private-API opt-in — so this is the honest equivalent: a small,
                // always-on-top window parked in a corner.
                Button {
                    isFloating.toggle()
                    MacPlayerWindow.setPictureInPicture(isFloating)
                } label: {
                    playerControlIcon(isFloating ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(.plain)
                .help(isFloating ? "Exit floating window" : "Float on top")
                #endif

                VStack(alignment: .trailing, spacing: 2) {
                    Text(title)
                        .font(Theme.isTelevision
                            ? .title3.weight(.semibold)
                            : .subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    // Which engine is decoding is a debugging detail, not something
                    // to brand the player with — kept behind the diagnostics toggle,
                    // and never on a television, where the toggle is on for the
                    // shelf and source diagnostics and this read as a stray label.
                    if model.showsDiagnostics && !Theme.isTelevision {
                        Text(controller.engine == .software ? "libVLC" : "AVPlayer")
                            .font(Theme.Typography.fine)
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .padding(Theme.Metrics.playerInset)

            Spacer()

            scrubber
                .padding(.horizontal, Theme.Metrics.playerInset)
                .padding(.bottom, Theme.isTelevision ? 48 : 28)
        }

        .background {
            LinearGradient(
                colors: [.black.opacity(0.6), .clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    private var transportButtons: some View {
        HStack(spacing: Theme.isTelevision ? 44 : 36) {
                Button { controller.skip(by: .seconds(-10)) } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: Theme.isTelevision ? 40 : 26, weight: .medium))
                }
                .transportButtonStyle()

                Button { controller.togglePlayPause() } label: {
                    Image(systemName: controller.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: Theme.isTelevision ? 52 : 38, weight: .medium))
                        .frame(width: Theme.isTelevision ? 66 : 52)
                }
                .transportButtonStyle()
                #if os(tvOS)
                // The row's landing spot: where focus goes when the controls
                // appear, and where the scrubber hands it on to.
                .focused($focus, equals: .playPause)
                #endif

                Button { controller.skip(by: .seconds(10)) } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: Theme.isTelevision ? 40 : 26, weight: .medium))
                }
                .transportButtonStyle()
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var scrubber: some View {
        let total = controller.duration?.seconds ?? 0

        VStack(spacing: 3) {
            #if os(tvOS)
            // tvOS has no `Slider`, so the bar is focusable and takes left/right
            // move commands directly. `onMoveCommand` swallows every direction it
            // is attached to, so up is forwarded by hand — otherwise focus is
            // trapped on the scrubber and the transport row becomes unreachable.
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(Theme.Palette.accent)
                        .frame(width: geometry.size.width * progressFraction)
                }
            }
            .frame(height: focus == .scrubber ? 12 : 6)
            .animation(.easeOut(duration: 0.15), value: focus)
            .focusable(total > 0)
            .focused($focus, equals: .scrubber)
            .onMoveCommand { direction in
                switch direction {
                case .left: seekFromRemote(by: -10)
                case .right: seekFromRemote(by: 10)
                // Handed to the transport row, not merely resigned. Clearing focus
                // let the focus engine choose, and with nothing else focusable
                // nearby it chose the scrubber again — so up did nothing.
                case .up: focus = .playPause
                default: break
                }
            }
            #else
            Slider(
                value: Binding(
                    // While a drag is live the knob follows the pointer from view
                    // state. Reading `currentTime` here meant every position report
                    // from the decoder — several a second — overwrote the value
                    // mid-gesture and snatched the knob back out from under the
                    // cursor, so the bar could not be moved.
                    get: {
                        if let scrubTarget { return scrubTarget }
                        guard total > 0 else { return 0 }
                        return min(controller.currentTime.seconds, total)
                    },
                    set: { newValue in
                        scrubTarget = newValue
                        // Keyframe seeks while the gesture is in flight, one
                        // precise seek when it ends — what SwiftVLC documents for
                        // a scrubber. Measured at four seeks a second both modes
                        // tracked equally well, so this is latency and load
                        // insurance for a real drag's rate, not the fix itself.
                        let now = Date()
                        guard now.timeIntervalSince(lastScrubSeek) > 0.2 else { return }
                        lastScrubSeek = now
                        controller.seek(to: .seconds(newValue), fast: true)
                    }
                ),
                in: 0...max(total, 0.001),
                onEditingChanged: { editing in
                    controller.isScrubbing = editing
                    if editing {
                        hideTask?.cancel()
                    } else {
                        // One exact seek to where the user let go, then the knob
                        // goes back to tracking the decoder.
                        if let scrubTarget { controller.seek(to: .seconds(scrubTarget)) }
                        scrubTarget = nil
                        scheduleControlsHide()
                    }
                }
            )
            .tint(Theme.Palette.accent)
            // A live stream or an unparsed duration makes the scrubber meaningless.
            .disabled(total <= 0)
            #endif

            HStack {
                Text(controller.currentTime.timecode)
                Spacer()
                Text(controller.duration?.timecode ?? "--:--")
            }
            .font(Theme.isTelevision
                ? .callout.monospacedDigit()
                : .caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func failureOverlay(_ reason: String) -> some View {
        VStack(spacing: 14) {
            StateMessage(
                icon: "exclamationmark.triangle",
                title: "Playback failed",
                message: reason
            )

            // Routing runs on addon metadata, not a real probe, so AVPlayer will
            // occasionally be handed something it cannot decode. Offer the fallback
            // rather than dead-ending.
            if controller.canRetryWithSoftwareEngine {
                Button("Try the software decoder") {
                    controller.retryWithSoftwareEngine()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
            }

            // The stream stopped short and would not restart. Whether that was
            // the end of the episode is the viewer's call — a remux's credits can
            // run past where the file gives out — so it is offered, not assumed.
            if controller.stalledAt != nil {
                Button("Mark as watched") {
                    Task { await finishAndAdvance() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)

                Button("Try again") { controller.retryFromStall() }
                    .buttonStyle(.bordered)
            }

            Button("Close") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.secondaryText)
        }
    }

    /// On macOS this is a real window-level toggle; on iOS the player already
    /// fills the screen, so it hides the remaining system overlays instead.
    #if os(macOS)
    /// Space, arrows and F, carried by zero-sized buttons.
    ///
    /// Mounted unconditionally rather than inside the controls overlay: the
    /// overlay is removed when the controls auto-hide, and a shortcut on a view
    /// that is not in the hierarchy does not fire. An `NSEvent` monitor and
    /// `.focusable()` with `@FocusState` were both tried first; neither received a
    /// key press even with the player window main.
    private var keyboardCommands: some View {
        VStack(spacing: 0) {
            Button("Play or pause") {
                controller.togglePlayPause()
                revealControls()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Back ten seconds") {
                controller.skip(by: .seconds(-10))
                revealControls()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Forward ten seconds") {
                controller.skip(by: .seconds(10))
                revealControls()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button("Toggle full screen") { toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])

            Button("Close player") { closeFromKeyboard() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
    #endif

    /// Brings the controls back and restarts the auto-hide, so a key press gives
    /// the same feedback a click does.
    private func revealControls() {
        withAnimation(.easeOut(duration: 0.15)) { areControlsVisible = true }
        scheduleControlsHide()
    }

    #if os(macOS)
    /// Escape closes the player rather than only leaving full screen.
    ///
    /// Full screen is left first: closing a window while it still owns a space
    /// strands an empty desktop behind it.
    private func closeFromKeyboard() {
        guard isFullScreen else {
            dismiss()
            return
        }
        toggleFullScreen()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            dismiss()
        }
    }
    #endif

    private func toggleFullScreen() {
        isFullScreen.toggle()
        #if os(macOS)
        MacPlayerWindow.toggleFullScreen()
        #endif
    }

    /// Closes the loop at the end of a video: record the completion, then either
    /// roll into the next episode or close.
    ///
    /// Both halves matter. Nothing observed `.ended` before, so the window sat on
    /// the last frame; and because libVLC reports a time of zero once the media
    /// stops, the ordinary progress write was discarded by the minimum-position
    /// guard and the episode kept its stale part-watched record.
    private func finishAndAdvance() async {
        guard !isAdvancing else { return }

        model.watchState.markFinished(
            videoId: active.videoId,
            metaId: active.metaId,
            type: active.type,
            duration: controller.duration,
            metaName: active.metaName,
            poster: active.poster
        )
        model.pushRemoteState()

        guard active.type == .series else {
            dismiss()
            return
        }

        isAdvancing = true
        let next = await nextEpisodeRequest()
        isAdvancing = false

        guard let next else {
            dismiss()
            return
        }

        active = next
        // Both latches are per *source*, and this player now spans several. Left
        // set, episode two onward gets no engine fallback and is never reported to
        // Screen.
        didAutoRetry = false
        didReportToScreen = false
        controller.completionThreshold = WatchProgress.completionThreshold(for: next.type)
        controller.replaceItem(
            url: next.url,
            engine: next.preferSoftware ? .software : .avPlayer,
            expectedBytes: next.expectedBytes,
            alternates: next.alternates
        )
        // Surface the new title briefly rather than dropping straight to a bare
        // frame — this is the one moment the viewer did not choose what plays.
        areControlsVisible = true
        scheduleControlsHide()
    }

    /// The next episode in running order, already resolved to a playable source.
    ///
    /// Self-contained rather than a callback to the detail screen, because on
    /// macOS the player is a separate window scene and cannot call back into it.
    private func nextEpisodeRequest() async -> PlaybackRequest? {
        let providers = model.registry.addons(providing: .meta, type: .series, id: active.metaId)
        var detail: MetaDetail?
        for addon in providers {
            if let found = try? await model.client.meta(from: addon, type: .series, id: active.metaId) {
                detail = found
                break
            }
        }
        guard let detail else { return nil }

        // Specials are excluded for the same reason `UpNextResolver` excludes
        // them: they are not part of the through-line.
        let ordered = detail.seasons.filter { $0.number > 0 }.flatMap(\.episodes)
        let episodes = ordered.isEmpty ? detail.videos : ordered

        guard let index = episodes.firstIndex(where: { $0.id == active.videoId }) else { return nil }
        let nextIndex = episodes.index(after: index)
        guard nextIndex < episodes.endIndex else { return nil }

        let episode = episodes[nextIndex]
        guard !episode.isUpcoming else { return nil }

        let showName = active.metaName ?? detail.name
        let episodeTitle = "\(showName) · \(episode.episodeCode ?? episode.displayName)"

        // Through the launcher, so auto-advance gets the settle window Play gets.
        // Draining the resolver here waited out its fifteen-second deadline
        // whenever one addon was slow — which is most of the time — and the
        // overlay between episodes sat for as long as the slowest addon took.
        // Ranked, not just the winner: the next episode deserves the same ability
        // to step past a placeholder as the one the viewer started by hand.
        let ranked = await PlaybackLauncher().resolveRanked(
            target: StreamTarget(type: .series, videoId: episode.id, metaId: active.metaId, title: episodeTitle),
            registry: model.registry,
            resolver: model.resolver,
            preferences: model.preferences
        )
        guard let winner = ranked.first else { return nil }
        return PlaybackRequest(
            stream: winner,
            context: PlaybackContext(
                videoId: episode.id,
                metaId: active.metaId,
                type: .series,
                title: episodeTitle,
                startAt: nil,
                metaName: showName,
                poster: active.poster
            ),
            alternates: Array(ranked.dropFirst().prefix(5))
        )
    }

    private func recordProgress(closing: Bool = false) {
        model.watchState.record(
            videoId: active.videoId,
            metaId: active.metaId,
            type: active.type,
            position: controller.currentTime,
            duration: controller.duration,
            metaName: active.metaName,
            poster: active.poster,
            // This session's share only; the store adds it to what came before.
            // Reset each checkpoint so fifteen seconds of playback is not counted
            // again on the next one.
            playedSeconds: controller.consumePlayedSeconds()
        )

        // Push the record we just wrote, not the one it replaced. Fire-and-forget:
        // playback must never wait on the network.
        // `active`, not `request`: after an episode advance `request` still names
        // the episode the player opened with, so every checkpoint wrote episode
        // N+1 and then pushed episode N to Trakt and Screen.
        if let saved = model.watchState.progress(for: active.videoId) {
            // Trakt hears about a pause once a minute and on the way out, not on
            // every checkpoint: four reports a minute for the length of a film is
            // not what a scrobble is for, and Trakt caps writes at one a second.
            if closing || Date().timeIntervalSince(lastTraktPush) >= 60 {
                lastTraktPush = Date()
                Task { await model.trakt.push(saved) }
            }
            // Tell Screen while the film is still on, not only on the way out.
            // Latches on the send, not the attempt: the first checkpoints are
            // under `minimumMeaningfulPosition` and report nothing, so latching on
            // the call would silence the sitting entirely.
            if !didReportToScreen {
                didReportToScreen = model.reportProgressToScreen(saved)
            }
        }
        model.pushRemoteState()
    }

    // MARK: - Auto-hide

    private func toggleControls() {
        areControlsVisible.toggle()
        if areControlsVisible { scheduleControlsHide() } else { hideTask?.cancel() }
    }

    private func scheduleControlsHide() {
        hideTask?.cancel()
        // A failure or an auto-advance owns the screen and its buttons are the
        // only way out. Letting the timer run underneath them hid the controls,
        // which on tvOS moved focus off those buttons and stranded the user.
        guard !isFailed, !isAdvancing else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            areControlsVisible = false
        }
    }
}
