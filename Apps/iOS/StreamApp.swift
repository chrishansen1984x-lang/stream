// xcode: set sdk=iOS

import SwiftUI
import StreamCore

@main
struct StreamApp: App {
    @UIApplicationDelegateAdaptor(OrientationLock.self) private var orientationLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .task {
                    #if DEBUG
                    model.present(link: DeepLink.fromLaunchArguments)
                    #endif
                    await model.seedDefaultAddonsIfNeeded()
                }
                // Sync on every return to the foreground, not just cold launch —
                // otherwise progress from another device only appears after a
                // full restart.
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.syncOnLaunch() }
                    }
                }
        }
    }
}

struct RootView: View {
    private enum Section: Hashable { case home, search }
    @State private var section: Section = .home
    @Environment(AppModel.self) private var model
    #if DEBUG
    /// `stream://play` on iOS. macOS and tvOS both had a handler for it and iOS
    /// did not, so the debug route landed on Home and there was no way to reach
    /// the player without tapping through — which is what made the orientation
    /// behaviour untestable here.
    @State private var previewPlayback: PlaybackRequest?
    #endif

    var body: some View {
        // Two destinations, icon only. macOS and tvOS both draw bare glyphs with
        // no captions, and Settings is not a place you browse to — it lives in the
        // menu on the other platforms too, so it moved to the one on Home.
        TabView(selection: $section) {
            Tab(value: .home) {
                HomeView()
            } label: {
                Image(systemName: "house")
            }
            Tab(value: .search) {
                SearchView()
            } label: {
                Image(systemName: "magnifyingglass")
            }
        }
        // A link names a section as well as a screen. Home and Search each
        // consume their own links, but neither can bring itself to the front,
        // so a `stream://detail` link while Search was showing pushed a page
        // nobody could see.
        .onChange(of: model.pendingLink, initial: true) { _, link in
            switch link {
            case .home, .detail: section = .home
            case .search: section = .search
            default: break
            }
        }
        // White, not accent. macOS and tvOS both draw their destinations as bare
        // monochrome glyphs that brighten when current; a blue tint here was the
        // only place in the app where navigation carried colour.
        .tint(Theme.Palette.primaryText)
        // Tab bars substitute the filled variant for the selected item, so asking
        // for `house` still rendered `house.fill` once selected. This keeps every
        // icon a consistent thin outline.
        .environment(\.symbolVariants, .none)
        #if DEBUG
        .onChange(of: model.pendingLink) { _, link in
            guard case .play(let url, let title, let software, let startAt) = link else { return }
            previewPlayback = PlaybackRequest(
                previewing: url, title: title, software: software,
                startAt: startAt.map { Duration.seconds($0) })
            model.pendingLink = nil
        }
        .fullScreenCover(item: $previewPlayback) { request in
            PlayerView(request: request)
        }
        #endif
    }
}
