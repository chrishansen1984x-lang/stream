// xcode: set sdk=tvOS

import SwiftUI
import StreamCore

@main
struct StreamTVApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    model.present(link: DeepLink.fromLaunchArguments)
                    #endif
                    await model.seedDefaultAddonsIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.syncOnLaunch() }
                    }
                }
                .onOpenURL { model.handle(url: $0) }
        }
    }
}

/// tvOS navigation, arranged like the Mac's toolbar.
///
/// A `TabView` was drawing a centred, labelled pill — a different shape from the
/// Mac's left-aligned icons, which is what made the two apps look unrelated. The
/// bar is a sibling in a `ZStack` rather than an `.overlay`: overlay content sits
/// outside tvOS's focus path and could never be reached with the remote.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: TVSection = .home
    #if DEBUG
    @State private var previewPlayback: PlaybackRequest?
    #endif

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                // Home stays mounted. As a `switch` case it was torn down on every
                // trip to Search or Settings and rebuilt on the way back: every
                // catalog refetched, the launch sync run again, the resume shelf
                // rebuilt, the scroll position and hero lost. Hidden, it is
                // disabled as well as transparent — on tvOS an invisible button
                // still takes focus.
                //
                // Only Home. Search and Settings host system text fields, which do
                // not honour `disabled` for focus, and both are cheap to rebuild.
                //
                // Full bleed on Home alone: applying it to the whole stack stripped
                // the top safe area from Search too, and Search needs it — that
                // inset is what holds its results below the search field and
                // keyboard. Without it the grid scrolled up underneath them and
                // posters slid behind the letters.
                HomeView()
                    .ignoresSafeArea(edges: .top)
                    .opacity(section == .home ? 1 : 0)
                    .disabled(section != .home)
                    .accessibilityHidden(section != .home)

                switch section {
                case .home:
                    EmptyView()
                case .search:
                    SearchView().padding(.top, TVTopBar<EmptyView>.height)
                case .settings:
                    AddonsView().padding(.top, TVTopBar<EmptyView>.height)
                }
            }
            .themedBackground()

            TVTopBar(section: $section) {
                if section == .home {
                    HomeGenreFilter()
                }
            }
            // Horizontal too, not just top. Stripping only the top left the bar
            // laid out inside tvOS's horizontal title-safe inset and then adding
            // `screenPadding` on top of it, while Home's shelves go full bleed and
            // apply the same padding from the physical edge — so the wordmark sat
            // a whole safe-area inset to the right of the hero title beneath it.
            // Same constant, same origin now.
            .ignoresSafeArea(edges: [.top, .horizontal])
        }
        .onChange(of: model.pendingLink) { _, link in
            switch link {
            case .search: section = .search
            case .settings: section = .settings
            case .home, .detail: section = .home
            #if DEBUG
            case .play(let url, let title, let software, let startAt):
                section = .home
                previewPlayback = PlaybackRequest(
                    previewing: url, title: title, software: software,
                    startAt: startAt.map { Duration.seconds($0) })
            // macOS-only development instruments; nothing to do here. `seek` is
            // handled in `AppModel.handle(url:)` before a link is ever published,
            // so it never reaches this switch.
            case .snapshot, .fullScreen, .seek: break
            #endif
            case nil: break
            }
        }
        #if DEBUG
        .fullScreenCover(item: $previewPlayback) { request in
            PlayerView(request: request)
        }
        #endif
    }
}
