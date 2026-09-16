import SwiftUI
import StreamCore

/// A focusable poster with a caption.
///
/// The platform split is structural, not cosmetic. tvOS's `.card` style draws its
/// focus plate around **everything the button contains**, so putting the caption
/// inside produced a grey slab behind the title that also clipped the poster's
/// lower edge. On tvOS the button therefore wraps the artwork alone and the
/// caption sits beneath it; elsewhere the whole tile is one control.
struct PosterButton<Artwork: View>: View {
    let width: CGFloat
    let caption: String
    @ViewBuilder var artwork: () -> Artwork
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) { poster }
                .buttonStyle(.card)
            captionBlock
        }
        .frame(width: width, alignment: .leading)
        #else
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                poster
                captionBlock
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
        #endif
    }

    private var poster: some View {
        artwork()
            .frame(width: width, height: width / Theme.Metrics.posterAspect)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
            }
    }

    /// `reservesSpace` keeps one- and two-line titles the same height, so posters
    /// in a grid row stay on a common baseline instead of stepping up and down.
    private var captionBlock: some View {
        Text(caption)
            .font(Theme.Typography.meta)
            .fontWeight(.medium)
            .foregroundStyle(Theme.Palette.primaryText)
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .leading)
    }
}

extension String {
    /// Keeps `compactMap` chains from producing empty separators.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension ResumeEntry {
    /// "S02E04 · Rise of Apocalypse" for something not yet started, or
    /// "S01E08 · Hanna · 39:37 left" for something part-way through.
    ///
    /// The two say different things and should not be collapsed: a time
    /// remaining on an episode you have never opened is a lie.
    var subtitleLine: String {
        let episode = [episodeCode, episodeName]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty

        if isUpNext {
            return episode ?? "Up next"
        }
        let left = remaining.map { "\($0.watchTimecode) left" }
        return [episode, left].compactMap { $0 }.joined(separator: "  ·  ")
    }
}


/// Landscape resume tile.
///
/// Deliberately a different shape from `PosterButton`: a portrait poster says
/// "browse this", a 16:9 still says "you were in the middle of this". Keeping
/// both shapes on Home is what lets the two rows read as different offers.
struct ResumeCard: View {
    let entry: ResumeEntry
    var width: CGFloat = Theme.Metrics.resumeCardWidth
    /// Removes the title from the shelf. Offered on a long press or right-click
    /// rather than as a visible button — it is a rare action and a delete control
    /// on every card would be easy to hit by accident.
    var onRemove: (() -> Void)?
    var onMarkWatched: (() -> Void)? = nil
    /// Opens the title's page. The card itself plays, so this is how the detail
    /// screen stays reachable from the shelf.
    var onShowDetails: (() -> Void)?
    /// Plays the row. `ResumeEntry` already knows which video and from where.
    let action: () -> Void

    var body: some View {
        #if os(tvOS)
        // Same split as `PosterButton`: tvOS's `.card` style plates everything
        // inside the button, so the caption sits outside it rather than behind a
        // grey slab that also clips the artwork.
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) { artwork }
                .buttonStyle(.card)
                // On the control that holds focus. A long press is delivered to
                // the focused view, and the enclosing stack never is one.
                .contextMenu { cardMenu }
            captionRow
        }
        .frame(width: width, alignment: .leading)
        #else
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) { artwork }
                .buttonStyle(.plain)
            captionRow
        }
        .frame(width: width, alignment: .leading)
        .contextMenu { cardMenu }
        #endif
    }

    /// A visible way to the title's page.
    ///
    /// The card itself plays — which is what a row called Continue watching should
    /// do — and that left the detail page reachable only by right-click or a long
    /// press. A hidden gesture is not a route most people will find, and for a
    /// series the page is where the rest of the episodes are.
    @ViewBuilder
    private var detailsButton: some View {
        if let onShowDetails {
            Button(action: onShowDetails) {
                Text(entry.type == .series ? "View show" : "View film")
                    .font(Theme.Typography.meta)
                    .fontWeight(.medium)
            }
            .buttonStyle(.bordered)
            .tint(Theme.Palette.secondaryText)
            // Never squeezed by a long episode name — the text truncates instead.
            .fixedSize()
        }
    }

    @ViewBuilder
    private var cardMenu: some View {
        if let onShowDetails {
            Button {
                onShowDetails()
            } label: {
                Label("Show details", systemImage: "info.circle")
            }
        }
        if let onMarkWatched {
            Button(entry.type == .series ? "Mark episode as watched" : "Mark as watched", systemImage: "checkmark.circle") {
                onMarkWatched()
            }
        }
        removeButton
    }

    @ViewBuilder
    private var removeButton: some View {
        if let onRemove {
            Button("Remove from Continue watching", systemImage: "minus.circle", role: .destructive) {
                onRemove()
            }
        }
    }

    private var artwork: some View {
        RemoteImage(string: entry.still ?? entry.poster, title: entry.title)
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))
            .overlay(alignment: .bottom) { progressBar }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Palette.separator, lineWidth: 0.5)
            }
    }

    /// On the artwork's bottom edge, not floating beneath the card. Detached from
    /// the image it reads as a divider rather than as a position.
    @ViewBuilder
    private var progressBar: some View {
        if entry.fractionComplete > 0 {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.55))
                    Rectangle()
                        .fill(Theme.Palette.accent)
                        .frame(width: geometry.size.width * max(0.015, entry.fractionComplete))
                }
            }
            .frame(height: 4)
            .clipShape(
                UnevenRoundedRectangle(
                    bottomLeadingRadius: Theme.Metrics.posterCornerRadius,
                    bottomTrailingRadius: Theme.Metrics.posterCornerRadius
                )
            )
        }
    }

    /// Title and episode on the left, the way through to the page on the right —
    /// one row rather than two. Stacked, the button started a second column under
    /// text it belongs beside, and cost the shelf a whole line of height per card.
    private var captionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            caption
            Spacer(minLength: 8)
            detailsButton
        }
        .frame(width: width)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.title)
                .font(Theme.isTelevision ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(1)

            // The question this row exists to answer for a series is *which
            // episode*. Showing only the show name and a time left never did.
            Text(entry.subtitleLine)
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String { entry.subtitleLine }
}

extension Duration {
    /// "1:23:45" or "4:05".
    var watchTimecode: String {
        let total = Int((Double(components.seconds)).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Translucent companion to `ResumePlayButton` for secondary actions.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(Theme.isTelevision ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                // Focus inverts the fill, matching the primary action's white.
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, Theme.isTelevision ? 24 : 14)
                .padding(.vertical, Theme.isTelevision ? 14 : 11)
                .background {
                    Capsule()
                        .fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial))
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(isFocused ? 0 : 0.18), lineWidth: 0.5)
                        }
                }
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.06 : 1)
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.75 : 1)
                .animation(.easeOut(duration: 0.16), value: isFocused)
        }
    }
}

/// Outlined companion to `ResumePlayButton`.
///
/// Distinct from `GlassButtonStyle`: glass is for icon-only controls that sit
/// beside the primary pair, this is for a labelled secondary action of equal
/// stature to Play. A blurred fill at that size competes with the primary.
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(Theme.isTelevision ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(isFocused ? .black : .white)
                .padding(.horizontal, Theme.isTelevision ? 30 : 22)
                .padding(.vertical, Theme.isTelevision ? 14 : 11)
                .background {
                    Capsule()
                        .fill(isFocused
                              ? AnyShapeStyle(.white)
                              : AnyShapeStyle(.black.opacity(configuration.isPressed ? 0.5 : 0.28)))
                        .overlay {
                            Capsule().strokeBorder(.white.opacity(isFocused ? 0 : 0.85), lineWidth: 1.2)
                        }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Small selectable capsule — the season picker and anything like it.
///
/// `.plain` leaves tvOS drawing its rounded-rectangle focus plate over a capsule,
/// the same mismatch the cast row had, and at `.caption` the labels were set for a
/// desk rather than a sofa. Focus fills white the way the top bar's icons do;
/// selection is carried by a border instead, so the two states stay distinct.
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration, isSelected: isSelected)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        let isSelected: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .font(Theme.isTelevision ? .body.weight(.semibold) : .caption.weight(.semibold))
                .padding(.horizontal, Theme.isTelevision ? 22 : 14)
                .padding(.vertical, Theme.isTelevision ? 12 : 8)
                .foregroundStyle(foreground)
                .background {
                    Capsule().fill(
                        isFocused
                            ? AnyShapeStyle(.white)
                            : (isSelected
                               ? AnyShapeStyle(.white)
                               : AnyShapeStyle(Theme.Palette.surfaceRaised))
                    )
                }
                .overlay {
                    // Only while focused, and only on an already-white selected
                    // chip would a white ring vanish — so the ring is drawn
                    // outside the fill rather than on it.
                    if isFocused {
                        Capsule().strokeBorder(Theme.Palette.accent, lineWidth: 4)
                    }
                }
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
                .animation(.easeOut(duration: 0.14), value: isFocused)
        }

        private var foreground: Color {
            (isFocused || isSelected) ? .black : Theme.Palette.secondaryText
        }
    }
}

/// Cast portraits, where the focus treatment has to follow a circle.
///
/// `.buttonStyle(.plain)` leaves tvOS's own focus effect in place, and that draws
/// a rounded *rectangle* around the button's whole frame — portrait and both
/// labels together. Against a circular avatar it read as a misaligned plate
/// sitting behind the face with the names washed out on top of it.
///
/// The portrait itself carries the focus instead, the way the top bar's icons do:
/// a white ring and a lift, no plate. On macOS and iOS `isFocused` stays false, so
/// the row keeps the appearance it already had.
struct CastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.55 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// The ring that marks the focused cast portrait.
///
/// Reads focus from inside the button's own subtree — `\.isFocused` is only
/// published there — so the ring can hug the circle rather than the column.
struct CastAvatarRing: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    func body(content: Content) -> some View {
        content
            .overlay {
                Circle()
                    .strokeBorder(
                        isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.Palette.separator),
                        lineWidth: isFocused ? 4 : 0.5
                    )
            }
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

/// The primary action, carrying its own resume state.
///
/// A bar and a time inside the button say exactly what pressing it will do, which
/// a bare "Play" plus a separate "10m left" line never quite did. The bar and time
/// appear only once there is real progress — an empty track on an unwatched title
/// implies a state it does not have.
struct ResumePlayButton: View {
    var label: String
    var fractionComplete: Double = 0
    var remaining: Duration?
    let action: () -> Void

    private var isResuming: Bool {
        fractionComplete > 0 && remaining != nil
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "play.fill")
                    .font(.system(size: Theme.isTelevision ? 17 : 13, weight: .bold))

                if isResuming {
                    progressTrack
                    Text(remaining!.compactRemaining)
                        .font(labelFont.monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(label)
                        .font(labelFont)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            // The row must keep its intrinsic width. Squeezed by the buttons
            // beside it on a phone, "1h 44m" wrapped one character per line and
            // inflated the capsule into a circle.
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.black)
            .padding(.horizontal, Theme.isTelevision ? 30 : 20)
            .padding(.vertical, Theme.isTelevision ? 14 : 12)
            .background { Capsule().fill(.white) }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(spokenLabel)
    }

    /// Resuming swaps the title for a progress bar and a bare "42m", so the
    /// button no longer says what it plays. Sighted viewers read that from the
    /// artwork behind it; VoiceOver had only "42m, button".
    private var spokenLabel: String {
        guard isResuming, let remaining else { return label }
        return "\(label), \(remaining.compactRemaining) remaining"
    }

    /// 29pt on tvOS against 13pt on macOS. `.title3` was 38pt and made the
    /// primary action look like a headline.
    private var labelFont: Font {
        Theme.isTelevision ? .body.weight(.semibold) : .subheadline.weight(.semibold)
    }

    private var progressTrack: some View {
        // Narrower on a phone: the hero action row also carries More Info and the
        // watchlist toggle, and 64pt of track left nothing for the time.
        #if os(iOS)
        let width: CGFloat = 44
        #else
        let width: CGFloat = Theme.isTelevision ? 110 : 64
        #endif
        return ZStack(alignment: .leading) {
            Capsule().fill(.black.opacity(0.22))
            Capsule()
                .fill(.black.opacity(0.75))
                .frame(width: max(4, width * min(1, fractionComplete)))
        }
        .frame(width: width, height: Theme.isTelevision ? 6 : 4)
    }
}

/// Press feedback, plus a focus lift where focus exists.
///
/// The fill already carries the emphasis, so focus adds elevation rather than a
/// colour change — but it must add *something*, or the control gives no sign it
/// is selected when driven by a remote.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.82 : 1)
                .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 18, y: 10)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

extension Duration {
    /// "10m", "1h 24m" — short enough to sit inside a button.
    var compactRemaining: String {
        let total = max(0, Int(Double(components.seconds).rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(1, minutes))m"
    }
}

/// Cover art on the trailing edge of a hero.
///
/// Shared by the detail page and Home's featured banner for the same reason
/// `HeroScrim` is: two hand-matched copies is what makes one app look like two.
///
/// Trailing, where Screen — the sibling app this was taken from — puts it leading.
/// Screen has no clearlogo, so its poster *is* the title treatment. Stream draws
/// the wordmark itself, and side by side the poster's burnt-in title and the
/// clearlogo are the same words twice at the same baseline. The width of the hero
/// between them is what stops them reading as a duplicate. Leading placement would
/// also push the title, synopsis and action row inward while the shelves below
/// stay at `screenPadding`, and "two different left insets on one page breaks the
/// strongest alignment cue it has".
struct HeroPoster: View {
    let poster: String?
    /// Used for the initials the placeholder falls back to.
    let title: String
    /// The hero's own width. Narrow heroes get no poster at all.
    let availableWidth: CGFloat

    var body: some View {
        // Only when the addon actually supplied one. A placeholder card in front
        // of a placeholder backdrop is two empty boxes saying the same thing.
        if let poster = poster?.nilIfEmpty, let width = Self.width(for: availableWidth) {
            RemoteImage(string: poster, title: title)
                .frame(width: width, height: width / Theme.Metrics.posterAspect)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
                }
                // Lifts it off the backdrop, which on a bright still is otherwise
                // the same brightness as the artwork it sits on.
                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
                // Decorative: the title mark beside it already announces the name.
                .accessibilityHidden(true)
        }
    }

    /// Nil when the hero is too narrow to hold a cover without crowding the
    /// action row.
    ///
    /// A phone never clears the bar, deliberately: the play button and its
    /// companions need most of a 390pt screen, and the bug where "1h 44m" wrapped
    /// one character per line and inflated the capsule into a circle came from
    /// squeezing exactly that row. An iPad clears it in either orientation.
    static func width(for availableWidth: CGFloat) -> CGFloat? {
        #if os(tvOS)
        // Fixed 1920pt stage, so the width test has nothing to decide.
        return 300
        #else
        guard availableWidth >= 700 else { return nil }
        // Proportional rather than a second breakpoint. A fixed width plus a
        // visibility threshold makes the cover pop in and out of existence while
        // the window is being dragged; this only grows and shrinks.
        return min(190, max(120, availableWidth * 0.17))
        #endif
    }

    /// The measure the text block must give up so it never runs under the cover.
    /// Only the trailing edge moves — the left inset is what aligns the hero with
    /// everything below it.
    static func textInset(for availableWidth: CGFloat) -> CGFloat {
        width(for: availableWidth).map { $0 + Theme.Metrics.screenPadding } ?? 0
    }
}

/// The gradient treatment shared by every hero.
///
/// One definition, used by both the home banner and the detail page. They looked
/// like different apps when each carried its own ramp, and the side gradient is
/// load-bearing rather than decorative: measured on a bright backdrop, 65%-white
/// body text scored 2.43:1 without it and 8.07:1 with it.
struct HeroScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(stops: Self.verticalStops, startPoint: .top, endPoint: .bottom)
            #if os(macOS) || os(tvOS)
            LinearGradient(stops: Self.sideStops, startPoint: .leading, endPoint: .trailing)
            #endif
        }
        .allowsHitTesting(false)
    }

    /// Concentrated where the text sits — the bottom third — so the artwork above
    /// still reads as a photograph.
    static var verticalStops: [Gradient.Stop] {
        #if os(iOS)
        // Heavier than the others because there is no side gradient to help, and
        // a phone's hero is short: the text sits over artwork that is still near
        // full brightness at the point the other platforms have already faded.
        [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.20),
            .init(color: Theme.Palette.background.opacity(0.45), location: 0.42),
            .init(color: Theme.Palette.background.opacity(0.78), location: 0.60),
            .init(color: Theme.Palette.background.opacity(0.94), location: 0.78),
            .init(color: Theme.Palette.background, location: 0.90),
            .init(color: Theme.Palette.background, location: 1.0)
        ]
        #else
        [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.34),
            .init(color: Theme.Palette.background.opacity(0.22), location: 0.55),
            .init(color: Theme.Palette.background.opacity(0.62), location: 0.72),
            .init(color: Theme.Palette.background.opacity(0.90), location: 0.87),
            .init(color: Theme.Palette.background, location: 0.97),
            .init(color: Theme.Palette.background, location: 1.0)
        ]
        #endif
    }

    /// A phone's text column spans nearly the full width, so a left-weighted
    /// gradient would not cover the end of the line it is meant to protect. iOS
    /// gets a stronger vertical ramp instead — see `verticalStops`.
    static var sideStops: [Gradient.Stop] {
        [
            .init(color: Theme.Palette.background.opacity(0.62), location: 0.0),
            .init(color: Theme.Palette.background.opacity(0.34), location: 0.30),
            .init(color: .clear, location: 0.62)
        ]
    }
}

/// Small labeled pill used for stream attributes and metadata.
struct Chip: View {
    let text: String
    var tint: Color = Theme.Palette.secondaryText
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(Theme.Typography.fine.weight(.semibold))
            .foregroundStyle(filled ? Theme.Palette.background : tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(filled ? tint : tint.opacity(0.14))
            }
    }
}

/// Horizontally scrolling row of posters with a title.
struct Shelf<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.fine)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                }
            }
            .padding(.horizontal, Theme.Metrics.screenPadding)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Theme.Metrics.posterSpacing) {
                    content()
                }
                .padding(.horizontal, Theme.Metrics.screenPadding)
                // Headroom for the focus lift. Without it tvOS scales the card up
                // and the row's own bounds clip the top and bottom off.
                .padding(.vertical, Theme.isTelevision ? 28 : 0)
            }
            // `.never`, not `.hidden`: hidden still defers to the system
            // "Show scroll bars: Always" preference, which leaves a grey bar
            // parked under every shelf.
            .scrollIndicators(.never)
        }
    }
}

/// Placeholder poster row shown while a catalog loads.
struct ShelfSkeleton: View {
    var body: some View {
        HStack(spacing: Theme.Metrics.posterSpacing) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.Metrics.posterCornerRadius, style: .continuous)
                    .fill(Theme.Palette.surface)
                    .frame(
                        width: Theme.Metrics.posterWidth,
                        height: Theme.Metrics.posterWidth / Theme.Metrics.posterAspect
                    )
            }
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        .redacted(reason: .placeholder)
    }
}

/// Neutral empty/error state.
/// A shelf that could not load.
///
/// Sits inside the row rather than replacing the screen: one dead catalog says
/// nothing about the others, and Home is usually still worth reading. The copy is
/// deliberately neutral — a viewer cannot act on "Addon returned HTTP 502", and
/// the shelf title already says which catalog it was. The raw reason is shown only
/// when diagnostics are on, which is the same rule the source list follows.
struct ShelfFailure: View {
    var detail: String?
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn’t load", systemImage: "arrow.clockwise.circle")
                .font(Theme.Typography.meta)
                .foregroundStyle(Theme.Palette.secondaryText)

            if let detail {
                Text(detail)
                    .font(Theme.Typography.fine)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .tint(Theme.Palette.accent)
        }
        .frame(width: Theme.Metrics.posterWidth * 1.6, alignment: .leading)
        // Matches a poster tile so a failing shelf keeps the row's height and the
        // page does not reflow when one catalog answers late.
        .frame(height: Theme.Metrics.posterWidth / Theme.Metrics.posterAspect, alignment: .top)
    }
}

struct StateMessage: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.isTelevision ? 18 : 10) {
            Image(systemName: icon)
                .font(.system(size: Theme.isTelevision ? 76 : 34, weight: .light))
                .foregroundStyle(Theme.Palette.tertiaryText)
            Text(title)
                .font(Theme.isTelevision ? .title.bold() : .headline)
                .foregroundStyle(Theme.Palette.primaryText)
            if let message {
                Text(message)
                    .font(Theme.isTelevision ? .title3 : .subheadline)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Palette.accent)
                    .padding(.top, 4)
            }
        }
        // The 320pt handheld measure wrapped a one-line TV message onto three
        // narrow lines, because TV type is roughly twice the size at the same
        // character count.
        .frame(maxWidth: Theme.isTelevision ? 900 : 320)
        .padding(32)
    }
}

#if os(tvOS)
/// Circular transport control that inverts on focus.
///
/// Sits over arbitrary video, so the focused state is a solid white fill rather
/// than a tint — nothing else survives an unknown background.
struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(isFocused ? Color.black : Color.white)
                .frame(width: 96, height: 96)
                .background {
                    Circle().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.black.opacity(0.4)))
                }
                .scaleEffect(configuration.isPressed ? 0.94 : (isFocused ? 1.08 : 1))
                .shadow(color: .black.opacity(isFocused ? 0.5 : 0), radius: 20, y: 10)
                .animation(.easeOut(duration: 0.16), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}
#endif
