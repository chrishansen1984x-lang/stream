// xcode: set sdk=tvOS

import SwiftUI
import StreamCore

/// The tvOS counterpart of the macOS toolbar.
///
/// tvOS's own `TabView` bar is centred and labelled, which is why the two apps
/// stopped looking related. This is the same arrangement the Mac uses — wordmark
/// then icon-only destinations, left aligned, with the genre filter opposite —
/// drawn as ordinary focusable buttons so the remote can reach them.
struct TVTopBar<Trailing: View>: View {
    /// Distance from the physical top of the screen to the top of the row.
    ///
    /// The row sits outside the safe area so artwork can run under it, which means
    /// this is measured from the panel edge, not from the title-safe box — so it
    /// has to clear that box itself. tvOS's vertical title-safe inset is 60pt; at
    /// the old 50 the wordmark was already inside it, and the focused icon's 1.12
    /// scale put a solid white circle 46pt from the edge, where overscan clips it
    /// flat. 70 leaves the focused state clear too.
    static var topInset: CGFloat { 70 }

    /// How much room the bar occupies, for screens that must not run beneath it.
    static var height: CGFloat { topInset + iconSize + 24 }

    /// Computed, not stored: `TVTopBar` is generic over its trailing content, and
    /// a generic type cannot hold a static stored property.
    private static var iconSize: CGFloat { 60 }

    @Binding var section: TVSection
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 18) {
            Text("Stream")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Palette.primaryText)
                .padding(.trailing, 6)

            ForEach(TVSection.allCases) { destination in
                Button {
                    section = destination
                } label: {
                    Image(systemName: destination.icon)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: Self.iconSize, height: Self.iconSize)
                }
                .buttonStyle(TopBarButtonStyle(isSelected: section == destination))
                // The style already draws a circle on focus. Left on, tvOS added
                // its own rounded-rectangle plate around the 60pt frame on top of
                // it, which read as a white lozenge running into the wordmark.
                .focusEffectDisabled()
                .accessibilityLabel(destination.title)
            }

            Spacer()

            trailing()
        }
        .padding(.horizontal, Theme.Metrics.screenPadding)
        // Clear of the title-safe edge; the row sits outside the safe area so the
        // hero's artwork can run underneath it as it does on the Mac.
        .padding(.top, Self.topInset)
        .background(alignment: .top) {
            // The Mac's toolbar has a material behind it, which is what lets
            // content scroll under it and stay readable. This bar had nothing, so
            // a scrolled episode grid ran straight through it — the wordmark sat
            // on top of an episode still and the season chips disappeared behind
            // the icons. Same job, drawn as a fade so the hero still bleeds.
            // Deliberately not opaque. The Mac has no toolbar material here — the
            // hero's own gradient carries it — so a solid band would clip the top
            // of the artwork in a way the Mac never does. This is the minimum that
            // keeps the wordmark readable over a bright episode still.
            LinearGradient(
                colors: [
                    Theme.Palette.background.opacity(0.9),
                    Theme.Palette.background.opacity(0.5),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: Self.height + 24)
            .allowsHitTesting(false)
        }
        // Keeps the row together for the focus engine, so moving down from it
        // lands in the content rather than skipping between bar items.
        .focusSection()
    }
}

enum TVSection: String, CaseIterable, Identifiable {
    case home, search, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

/// Bare glyph that fills in on focus, matching the Mac's borderless toolbar
/// buttons rather than tvOS's default plate.
struct TopBarButtonStyle: ButtonStyle {
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
                .foregroundStyle(foreground)
                .background {
                    Circle().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.clear))
                }
                .scaleEffect(isFocused ? 1.12 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
        }

        private var foreground: Color {
            if isFocused { return Theme.Palette.background }
            // The current section stays bright; the others recede. On the Mac the
            // sidebar carries this, and without it nothing said where you were.
            return isSelected ? Theme.Palette.primaryText : Theme.Palette.tertiaryText
        }
    }
}

/// Genre filter, sitting opposite the destinations exactly as it does on the Mac.
///
/// Writes `AppModel.homeFilter`; Home reacts. "In theatres" lives here because a
/// remote cannot reach a floating overlay, and the Home menu that used to hold it
/// is never rendered on a television.
struct HomeGenreFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Menu {
            Button {
                model.homeFilter = nil
            } label: {
                Label("All genres", systemImage: model.homeFilter == nil ? "checkmark" : "")
            }

            // With the genres because it is the same kind of choice — a narrowing
            // of the whole page — and this is the only filter control the remote
            // can reach.
            Button {
                model.homeFilter = .inTheatres
            } label: {
                Label("In theatres", systemImage: model.homeFilter == .inTheatres ? "checkmark" : "")
            }

            Divider()

            ForEach(HomeViewModel.availableGenres(registry: model.registry), id: \.self) { genre in
                Button {
                    model.homeFilter = .genre(genre)
                } label: {
                    Label(genre, systemImage: model.homeFilter == .genre(genre) ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 24, weight: .semibold))
                // Named when active, matching the Mac. A bare funnel says a filter
                // exists but not which one is on.
                if let filter = model.homeFilter {
                    Text(filter.label).font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, model.homeFilter == nil ? 0 : 18)
            .frame(minWidth: Self.iconSize, minHeight: Self.iconSize)
        }
        // `.button`, not `.borderlessButton`: it is the one menu style that takes
        // a `ButtonStyle`, and the style is where the focus state is drawn. As a
        // borderless menu the label showed no focus at all, so the one control on
        // the right of the bar gave no sign the remote had landed on it.
        .menuStyle(.button)
        .buttonStyle(FilterButtonStyle(isActive: model.homeFilter != nil))
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel(model.homeFilter.map { "Filter: \($0.label)" } ?? "Filter")
    }

    private static var iconSize: CGFloat { 60 }
}

/// The filter's own focus treatment: the same white fill and lift the section
/// icons get, stretched to a capsule so it still fits a named genre.
struct FilterButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        FocusAware(configuration: configuration, isActive: isActive)
    }

    private struct FocusAware: View {
        let configuration: Configuration
        let isActive: Bool
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .foregroundStyle(foreground)
                .background {
                    Capsule().fill(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.clear))
                }
                .scaleEffect(configuration.isPressed ? 1.04 : (isFocused ? 1.12 : 1))
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var foreground: Color {
            if isFocused { return Theme.Palette.background }
            // Bright while a filter is on, the way the current section stays
            // bright; dim when the page is unfiltered.
            return isActive ? Theme.Palette.primaryText : Theme.Palette.tertiaryText
        }
    }
}
