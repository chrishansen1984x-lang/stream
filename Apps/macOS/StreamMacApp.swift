// xcode: set sdk=macOS

import SwiftUI
import StreamCore

@main
struct StreamMacApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()

    var body: some Scene {
        // `Window`, not `WindowGroup`: browsing is a single-window activity, and
        // as a group the app accumulated main windows — reopening it with none
        // visible made a new one, restoration brought every one of them back
        // cascaded off the bottom of the screen, and each carried its own copy of
        // the deep-link and navigation handlers. Eight of them were live at a
        // clean launch. A unique window still remembers its frame.
        Window("Stream", id: "main") {
            MacRootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    #if DEBUG
                    // The window snapshot only reflects the launch frame, so a
                    // screen can only be inspected by opening straight onto it.
                    model.present(link: DeepLink.fromLaunchArguments)
                    #endif
                    await model.seedDefaultAddonsIfNeeded()
                }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await model.syncOnLaunch() }
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        // The standard place for this on macOS, and the only one where the
        // shortcut actually registers — inside a toolbar menu it did nothing.
        .commands {
            CommandGroup(replacing: .sidebar) {
                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.isSidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
            }
        }

        // The player gets its own window rather than a sheet: sheets on macOS are
        // modal and cannot be resized, which is exactly the wrong shape for video.
        WindowGroup(id: MacPlayerWindow.sceneID, for: PlaybackRequest.self) { $request in
            if let request {
                PlayerView(request: request)
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
        }
        .defaultSize(width: 960, height: 540)
        // `contentMinSize` lets the user drag the window down to the view's minimum
        // (320×180) instead of pinning it to the ideal size.
        .windowResizability(.contentMinSize)
        // Set on the scene, not patched onto the NSWindow afterwards. Mutating
        // styleMask from a WindowAccessor did not survive SwiftUI's own window
        // configuration, which is why a title bar strip kept coming back.
        .windowStyle(.hiddenTitleBar)
        // Never restored on launch. SwiftUI otherwise reopens the player with the
        // request it held when the app quit, so relaunching immediately resumed
        // whatever was last watched — and starting something else then raced two
        // players, each writing progress for its own position.
        .restorationBehavior(.disabled)
    }
}

struct MacRootView: View {
    private enum Section: String, CaseIterable, Identifiable {
        case home = "Home"
        case search = "Search"
        case settings = "Settings"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: "house"
            case .search: "magnifyingglass"
            case .settings: "gearshape"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .home: "1"
            case .search: "f"
            case .settings: ","
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var selection: Section = .home
    #if DEBUG
    @Environment(\.openWindow) private var openWindow
    #endif
    /// Explicit, rather than `NavigationSplitViewVisibility.automatic`.
    ///
    /// `.automatic` does not say whether the sidebar is actually showing, so a
    /// menu item derived from it could not name the action it would perform.
    /// Two-way, so the split view collapsing the sidebar on its own — a divider
    /// drag, a narrow window — keeps the menu item's wording honest.
    private var columns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { model.isSidebarVisible ? .all : .detailOnly },
            set: { model.isSidebarVisible = $0 != .detailOnly }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columns) {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection {
            case .home: HomeView()
            case .search: SearchView()
            case .settings: AddonsView()
            }
        }
        .themedBackground()
        // Section links had no handler on macOS at all: `stream://settings` set
        // `pendingLink` and nothing ever read it.
        .onChange(of: model.pendingLink) { _, link in
            // Only the first window to see a link acts on it. Every open window
            // hosts this handler, so without the claim one `stream://play` opened
            // the player once per window.
            guard link != nil, model.claimLink() else { return }
            switch link {
            // Through `show`, not by assigning `selection` directly: a link can
            // arrive while a title is open, and that is the case that crashes.
            case .search:
                show(.search)
                model.pendingLink = nil
            case .settings:
                show(.settings)
                model.pendingLink = nil
            case .detail:
                // Home owns the stack, so it must be the visible section before it
                // can push. `pendingLink` is left for Home to consume, and the
                // section is set without unwinding — the push is the point here.
                selection = .home
            #if DEBUG
            case .play(let url, let title, let software, let startAt):
                // The real player window, not a sheet: libVLC never got a working
                // drawable in the sheet and rendered black, which made the debug
                // route useless for anything visual.
                // Close first, as the picker does: `openWindow(id:value:)` fronts
                // an existing window rather than opening a new one, so a leftover
                // player would replay its own request and ignore this URL.
                MacPlayerWindow.closeExisting()
                openWindow(
                    id: MacPlayerWindow.sceneID,
                    value: PlaybackRequest(
                        previewing: url,
                        title: title,
                        software: software,
                        startAt: startAt.map { Duration.seconds($0) }
                    )
                )
                model.pendingLink = nil
            #endif
            default:
                break
            }
        }
        // Navigation lived only in the sidebar, so collapsing it removed the only
        // way to move between sections. These are always present.
        .toolbar {
            if #available(macOS 26.0, *) {
                navigationItems.sharedBackgroundVisibility(.hidden)
                actionItems.sharedBackgroundVisibility(.hidden)
            } else {
                navigationItems
                actionItems
            }
        }
    }

    /// Wordmark, sidebar toggle, Home.
    ///
    /// `sharedBackgroundVisibility(.hidden)` above is what makes these read as
    /// bare glyphs: macOS 26 puts every toolbar item in a glass capsule and gives
    /// adjacent items one shared capsule, which drew the wordmark as if it were
    /// the Home button's label.
    /// Switches section, and unwinds that section's own navigation.
    ///
    /// Setting `selection` alone only moves between sections. Each section holds
    /// its own `NavigationStack`, so picking Home while a title was open left the
    /// title on screen and the menu item appeared to do nothing.
    private func show(_ section: Section) {
        // Unwind first, switch after.
        //
        // Home relied on `pendingLink = .home` to pop, which never fired when Home
        // was already the current section — so from a movie page the Home item did
        // nothing at all. Worse, leaving the stack loaded while the detail column
        // was swapped is what crashed the app on Search: SwiftUI asserts inside
        // `NavigationColumnState.boundPathChange` when a bound, non-empty path is
        // torn down with its column.
        let wasDeep = !model.homePath.isEmpty
        model.homePath.removeAll()

        guard section != selection else { return }

        if wasDeep {
            // A turn later, so the stack has actually emptied before the column
            // changes. Doing both in one update is the crash.
            DispatchQueue.main.async { selection = section }
        } else {
            selection = section
        }
    }

    @ToolbarContentBuilder
    private var navigationItems: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text("Stream")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.Palette.primaryText)
                .padding(.trailing, 10)
        }

        ToolbarItem(placement: .navigation) {
            // A menu, not a sidebar toggle.
            //
            // Removing the system toggle to put the wordmark first also removed
            // the only working way to open the sidebar — and with the sidebar
            // shut, Settings had no route at all. Navigation now lives in the
            // control itself, so it cannot depend on split-view state.
            Menu {
                ForEach(Section.allCases) { section in
                    Button {
                        show(section)
                    } label: {
                        Label(
                            section.rawValue,
                            systemImage: selection == section ? "checkmark" : section.icon
                        )
                    }
                    // The shortcuts moved here with the destinations, so removing
                    // the toolbar buttons did not take ⌘1 and ⌘F with them.
                    .keyboardShortcut(section.shortcut, modifiers: .command)
                }

                Divider()

                Button(model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.isSidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Menu")
        }

        // No Home button here. It did not respond, and the menu beside it already
        // carries Home — two controls for one destination, one of them broken.
        // ⌘1 still works, from the menu item.
    }

    @ToolbarContentBuilder
    private var actionItems: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                show(.search)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Search (⌘F)")
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
