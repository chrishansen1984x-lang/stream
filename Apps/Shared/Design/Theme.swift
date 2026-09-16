import SwiftUI

/// Visual constants for the app. Centralized so the tvOS and macOS targets inherit
/// the same language when they land.
enum Theme {

    // MARK: - Color

    enum Palette {
        /// Deep neutral base rather than pure black — keeps poster art from
        /// bleeding into the background on OLED.
        static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
        static let surface = Color(red: 0.09, green: 0.09, blue: 0.12)
        static let surfaceRaised = Color(red: 0.13, green: 0.13, blue: 0.17)

        static let accent = Color(red: 0.45, green: 0.55, blue: 1.0)
        static let accentWarm = Color(red: 1.0, green: 0.72, blue: 0.30)

        // Opacities are chosen for WCAG AA against `background`, measured rather
        // than eyeballed: secondary 8.4:1, tertiary 6.3:1. Tertiary was previously
        // 0.40, which measured 3.78:1 and failed for the 11pt text it was used on.
        static let primaryText = Color.white
        static let secondaryText = Color.white.opacity(0.65)
        static let tertiaryText = Color.white.opacity(0.55)

        static let separator = Color.white.opacity(0.16)

        /// Quality-tier colors used on stream attribute chips.
        static let tier4K = Color(red: 0.60, green: 0.45, blue: 1.0)
        static let tierHD = Color(red: 0.35, green: 0.75, blue: 0.95)
        static let tierSD = Color.white.opacity(0.45)
        static let cached = Color(red: 0.35, green: 0.85, blue: 0.55)
    }

    // MARK: - Metrics

    /// Three roles only. Nothing content-bearing sits below `meta`, which is the
    /// smallest size that still scales acceptably with Dynamic Type.
    enum Typography {
        // `.title2` is 48pt on tvOS against a 13pt headline on macOS — nearly
        // 4x, which read as shouting rather than as the same design at viewing
        // distance. `.title3` is 38pt, a little under 3x.
        static let title: Font = isTelevision ? .title3 : .headline
        static let body: Font = isTelevision ? .body : .subheadline
        static let meta: Font = isTelevision ? .callout : .caption

        /// Smallest supporting text. On a TV nothing may go below `caption`, which
        /// is already near the legibility floor at viewing distance.
        static let fine: Font = isTelevision ? .caption : .system(size: 10)
    }

    /// tvOS is viewed from across a room, not at arm's length, so everything is
    /// larger — Apple's guidance is roughly a 2× jump from a handheld layout.
    #if os(tvOS)
    static let isTelevision = true
    #else
    static let isTelevision = false
    #endif

    enum Metrics {
        // Three radii, not five: container / element / chip.
        static let cornerRadius: CGFloat = 12
        static let posterCornerRadius: CGFloat = isTelevision ? 12 : 8
        #if os(macOS)
    static let screenPadding: CGFloat = 32
    #else
    static let screenPadding: CGFloat = isTelevision ? 80 : 16
    #endif
        static let shelfSpacing: CGFloat = isTelevision ? 52 : 28
        #if os(macOS)
    static let posterSpacing: CGFloat = 16
    #else
    static let posterSpacing: CGFloat = isTelevision ? 32 : 12
    #endif

        /// Standard movie-poster ratio.
        static let posterAspect: CGFloat = 2.0 / 3.0
        static let posterWidth: CGFloat = isTelevision ? 210 : 116
        static let backdropAspect: CGFloat = 16.0 / 9.0

        /// Maximum measure for running text — roughly 70–80 characters, the usual
        /// readability ceiling. Matters on macOS and iPad, where an unconstrained
        /// column would otherwise stretch to the full window width.
        ///
        /// Wider on a TV: the same character count needs more pixels at TV type
        /// sizes, and a 700pt column on a 1080p screen wraps every other word.
        static let readableWidth: CGFloat = isTelevision ? 1300 : 700

        /// Minimum column width for the credits grid. The 165pt handheld value
        /// forced "Christopher Nolan" onto two lines at TV scale.
        static let creditColumnWidth: CGFloat = isTelevision ? 380 : 165

        /// Episode card minimum width.
        static let episodeCardWidth: CGFloat = isTelevision ? 460 : 260

        /// Circular cast portrait.
        static let castAvatar: CGFloat = isTelevision ? 130 : 62

        /// Column allotted to a cast member, avatar plus name.
        static let castColumn: CGFloat = isTelevision ? 160 : 78

        /// Filmography poster in the person view.
        static let creditPosterWidth: CGFloat = isTelevision ? 200 : 104

        /// Settings measure.
        ///
        /// The reason is the same on both capped platforms: an unbounded row puts a
        /// label at one end of the display and its value at the other, and the eye
        /// cannot connect them. A maximised window on a large Mac is *wider* than a
        /// 1080p television, so `.infinity` there was the value nobody revisited
        /// rather than a decision — and it quietly made both `.frame(maxWidth:)`
        /// lines in `AddonsView` a no-op everywhere except tvOS. iPhone and iPad
        /// keep `.infinity`: the list already constrains itself there, and a hard
        /// cap only strands content in landscape.
        #if os(macOS)
        static let settingsWidth: CGFloat = 720
        #else
        static let settingsWidth: CGFloat = isTelevision ? 1000 : .infinity
        #endif

        /// Inset for the player's own controls. Deliberately not `screenPadding`:
    /// that is a page margin, and the player window goes down to 320pt wide.
    static let playerInset: CGFloat = isTelevision ? 80 : 16

    /// Landscape resume tile on Home.
    static let resumeCardWidth: CGFloat = isTelevision ? 520 : 300

    /// Addon and studio logo box in list rows.
        static let logoBox: CGFloat = isTelevision ? 72 : 36
    }
}

extension View {
    /// `insetGrouped` does not exist on macOS; `inset` is the closest match and
    /// keeps the grouped look the settings screen is built around.
    @ViewBuilder
    func settingsListStyle() -> some View {
        #if os(macOS)
        self.listStyle(.inset)
        #elseif os(tvOS)
        // tvOS has neither `inset` nor `insetGrouped`; grouped is the closest.
        self.listStyle(.grouped)
        #else
        self.listStyle(.insetGrouped)
        #endif
    }

    /// Gives a sheet a usable size on macOS.
    ///
    /// macOS sheets have no intrinsic size and ignore `presentationDetents`, so a
    /// list-based sheet collapses to its chrome and renders as an empty box.
    @ViewBuilder
    func sheetSize(width: CGFloat = 700, height: CGFloat = 560) -> some View {
        #if os(macOS)
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
        #else
        self
        #endif
    }

    /// Poster and card buttons.
    ///
    /// tvOS's `.card` style provides the native focus behaviour — the lift, the
    /// parallax tilt, and the shadow — which cannot be reproduced convincingly by
    /// hand and is what makes remote navigation feel correct.
    @ViewBuilder
    func posterButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Lets a scroll container span the full screen width on tvOS.
    ///
    /// Applied to the container, not to nested artwork: tvOS applies its
    /// title-safe inset at the TabView, and `ignoresSafeArea` on a descendant
    /// cannot escape an ancestor's layout. Content re-establishes its own margin
    /// through `screenPadding`, which is sized to the title-safe area.
    @ViewBuilder
    func tvFullBleedHorizontal() -> some View {
        #if os(tvOS)
        self.ignoresSafeArea(edges: .horizontal)
        #else
        self
        #endif
    }

    /// The home hero.
    ///
    /// tvOS's default focus for a `.plain` button is a hard white border, which
    /// around a full-width banner looks like a rendering fault. `.card` gives the
    /// same lift treatment the posters use.
    @ViewBuilder
    func heroButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(.card)
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// `textSelection` does not exist on tvOS.
    @ViewBuilder
    func selectableTextIfAvailable() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// Attaches toolbar content on macOS only — iOS and tvOS hide the navigation
    /// bar on this screen and render the same control as a floating overlay.
    @ViewBuilder
    func macToolbarGenreMenu<T: ToolbarContent>(_ content: T) -> some View {
        #if os(macOS)
        // This is a second `.toolbar` and therefore its own group, so it needs
        // the glass opt-out separately from the ones in `MacRootView`.
        if #available(macOS 26.0, *) {
            self.toolbar { content.sharedBackgroundVisibility(.hidden) }
        } else {
            self.toolbar { content }
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func languagePickerStyle() -> some View {
        #if os(tvOS)
        self.pickerStyle(.navigationLink)
        #else
        self.pickerStyle(.menu)
        #endif
    }

    /// Player transport control.
    ///
    /// `.plain` draws no focus state on tvOS, so every button in the row looked
    /// the same regardless of which one the remote was on. `.card` is wrong here
    /// too — it plates a rectangle behind a circular glyph over video.
    @ViewBuilder
    func transportButtonStyle() -> some View {
        #if os(tvOS)
        self.buttonStyle(TransportButtonStyle())
        #else
        self.buttonStyle(.plain)
        #endif
    }

    /// Home's window/navigation title.
    ///
    /// macOS puts the wordmark in the toolbar, so a matching window title showed
    /// "Stream" twice next to each other.
    @ViewBuilder
    func homeNavigationTitle() -> some View {
        #if os(macOS)
        self.navigationTitle("")
        #else
        self.navigationTitle("Stream")
        #endif
    }

    /// tvOS renders list section headers at roughly 35% white — legible on the
    /// system's own light settings background, not on this app's near-black one.
    /// Measured 2.6:1 there, against 8.4:1 for `secondaryText`.
    @ViewBuilder
    func settingsSectionHeader() -> some View {
        #if os(tvOS)
        self.font(.callout.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(Theme.Palette.secondaryText)
        #else
        self
        #endif
    }

    /// Explanatory text under a settings section. Same contrast problem as
    /// `settingsSectionHeader`, and these carry more meaning.
    @ViewBuilder
    func settingsFootnote() -> some View {
        // `fixedSize` on every platform: a multi-line `Text` in a List row is
        // measured as one line and truncated with an ellipsis rather than wrapped,
        // which only became visible once the macOS measure was capped and the
        // sentences stopped fitting across a whole window.
        // `lineLimit(nil)` and a leading full-width frame as well: on macOS an
        // inset list still measured the footer as one line and cut it with an
        // ellipsis even with `fixedSize`, so every multi-sentence footnote
        // ended in "…".
        #if os(tvOS)
        self.font(.callout)
            .foregroundStyle(Theme.Palette.secondaryText)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        #else
        self.lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        #endif
    }

    /// `scrollContentBackground` does not exist on tvOS, where lists have no
    /// system background to clear in the first place.
    @ViewBuilder
    func clearScrollBackground() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    /// Hides the navigation bar entirely on iOS/tvOS. macOS has no navigation bar —
    /// its chrome is the window toolbar, handled by `hiddenToolbarBackground`.
    @ViewBuilder
    func hiddenNavigationBar() -> some View {
        #if os(iOS) || os(tvOS)
        self.toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }

    /// Removes the toolbar's opaque fill so artwork can run underneath it.
    /// The placement differs per platform and cannot be branched mid-chain.
    @ViewBuilder
    func hiddenToolbarBackground() -> some View {
        #if os(macOS)
        self.toolbarBackground(.hidden, for: .windowToolbar)
        #else
        self.toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    /// Applies the app background across the full safe area.
    ///
    /// The expansion to fill matters: without it the background only covers the
    /// content's intrinsic frame, so a small view (an empty state, say) renders as a
    /// lighter panel floating on the system's black.
    /// Fills the screen with the app background.
    ///
    /// Only the background layer ignores the safe area — never the content. On
    /// tvOS, pushing content outside the title-safe inset put it underneath the
    /// tab bar and took the tab bar out of the focus path, which is why Home,
    /// Search, and Settings became unreachable with the remote.
    func themedBackground() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Palette.background.ignoresSafeArea())
    }
}
