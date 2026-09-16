import SwiftUI
import StreamCore

@Observable
@MainActor
final class DiscoverAddonsViewModel {
    struct Directory: Identifiable {
        let source: CatalogSource
        var entries: [AddonCatalogEntry] = []

        var id: String { source.id }
        var title: String { source.catalog.displayName }
    }

    private(set) var directories: [Directory] = []
    private(set) var isLoading = true
    private(set) var failure: String?

    var query = ""

    /// Loads every directory published by installed addons.
    func load(registry: AddonRegistry, client: AddonClient) async {
        isLoading = true
        failure = nil

        let sources = registry.addonDirectories
        guard !sources.isEmpty else {
            directories = []
            isLoading = false
            return
        }

        var loaded: [Directory] = []
        await withTaskGroup(of: (CatalogSource, [AddonCatalogEntry]).self) { group in
            for source in sources {
                group.addTask {
                    let entries = (try? await client.addonCatalog(
                        from: source.addon,
                        type: source.catalog.type,
                        id: source.catalog.id
                    )) ?? []
                    return (source, entries)
                }
            }
            for await (source, entries) in group where !entries.isEmpty {
                loaded.append(Directory(source: source, entries: entries))
            }
        }

        // Directory order follows the addon's own declaration ("Official" before
        // "Community"), which the concurrent group does not preserve.
        let order = sources.map(\.id)
        directories = loaded.sorted {
            (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
        }

        if directories.isEmpty {
            failure = "No addon directories were available."
        }
        isLoading = false
    }

    /// Case-insensitive filter over name and description. With ~100 community
    /// addons, browsing without search is impractical.
    func filtered(_ directory: Directory) -> [AddonCatalogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory.entries }
        return directory.entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(trimmed)
                || (entry.manifest.description ?? "").localizedCaseInsensitiveContains(trimmed)
        }
    }
}

struct DiscoverAddonsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = DiscoverAddonsViewModel()
    @State private var installing: Set<String> = []
    @State private var configuring: AddonCatalogEntry?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let failure = viewModel.failure {
                    StateMessage(icon: "square.stack.3d.up.slash", title: "Nothing to browse", message: failure)
                } else {
                    list
                }
            }
            .themedBackground()
            .navigationTitle("Browse addons")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .searchable(text: $viewModel.query, prompt: "Filter addons")
        .task {
            await viewModel.load(registry: model.registry, client: model.client)
        }
        .sheet(item: $configuring) { entry in
            AddonConfigurationNotice(entry: entry)
                .presentationDetents([.medium])
        }
    }

    private var list: some View {
        List {
            ForEach(viewModel.directories) { directory in
                let entries = viewModel.filtered(directory)
                if !entries.isEmpty {
                    Section(directory.title) {
                        ForEach(entries) { entry in
                            DiscoverAddonRow(
                                entry: entry,
                                isInstalled: model.registry.contains(entry.manifest.id),
                                isInstalling: installing.contains(entry.id),
                                install: { install(entry) }
                            )
                        }
                        .listRowBackground(Theme.Palette.surface)
                    }
                }
            }
        }
        .listStyle(.plain)
        .clearScrollBackground()
    }

    private func install(_ entry: AddonCatalogEntry) {
        // Configurable addons hand back a setup page; installing the bare manifest
        // would add something that returns nothing.
        guard !entry.requiresConfiguration else {
            configuring = entry
            return
        }

        installing.insert(entry.id)
        Task {
            try? await model.installAddon(from: entry.transportUrl)
            installing.remove(entry.id)
        }
    }
}

struct DiscoverAddonRow: View {
    let entry: AddonCatalogEntry
    let isInstalled: Bool
    let isInstalling: Bool
    let install: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RemoteImage(string: entry.manifest.logo, contentMode: .fit)
                .frame(width: Theme.Metrics.logoBox, height: Theme.Metrics.logoBox)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    if entry.flags?.official == true {
                        Chip(text: "OFFICIAL", tint: Theme.Palette.accent)
                    }
                }

                if let description = entry.manifest.description, !description.isEmpty {
                    Text(description)
                        .font(Theme.Typography.fine)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .lineLimit(2)
                }

                HStack(spacing: 4) {
                    ForEach(entry.capabilities, id: \.self) { capability in
                        Chip(text: capability)
                    }
                    if entry.requiresConfiguration {
                        Chip(text: "SETUP", tint: Theme.Palette.accentWarm)
                    }
                }
            }

            Spacer(minLength: 0)

            installButton
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var installButton: some View {
        if isInstalling {
            ProgressView().controlSize(.small)
        } else if isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Palette.cached)
        } else {
            Button(entry.requiresConfiguration ? "Set up" : "Add", action: install)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(Theme.Palette.accent)
        }
    }
}

/// Shown for addons that must be configured on their own site before they return
/// anything — the aggregators (AIOStreams, Torrentio, Comet) all work this way,
/// because the user's debrid credentials live in the generated URL.
struct AddonConfigurationNotice: View {
    let entry: AddonCatalogEntry
    @Environment(\.dismiss) private var dismiss

    /// Names the control the reader actually has. The "+ button" is a toolbar item
    /// that tvOS never shows; there the equivalent is a row in the addons list.
    private var instructions: String {
        #if os(tvOS)
        """
        This addon needs configuring before it returns anything. Open the address \
        below on a phone or computer, choose your options, then add the manifest \
        URL it gives you from Settings › Addons › Add by URL.
        """
        #else
        """
        This addon needs configuring before it returns anything. Open its setup \
        page, choose your options, then copy the generated manifest URL and add \
        it with the + button.
        """
        #endif
    }

    /// The addon's configuration page, which the protocol places at `/configure`.
    private var configureURL: URL? {
        guard var components = URLComponents(string: entry.transportUrl) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/manifest.json", with: "/configure")
        return components.url
    }

    var body: some View {
        VStack(spacing: 16) {
            RemoteImage(string: entry.manifest.logo, contentMode: .fit)
                .frame(width: 54, height: 54)

            Text(entry.name)
                .font(.headline)
                .foregroundStyle(Theme.Palette.primaryText)

            Text(instructions)
            .font(.subheadline)
            .foregroundStyle(Theme.Palette.secondaryText)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            if let configureURL {
                #if os(tvOS)
                // An Apple TV has no browser, so `Link` opens nothing at all — the
                // one real action on this screen was inert, and the text sent the
                // user to a "+ button" that only exists on the other platforms.
                // The URL itself is the useful thing here: it is what gets typed
                // into a phone or a Mac to finish the job.
                Text(configureURL.absoluteString)
                    .font(.body.monospaced())
                    .foregroundStyle(Theme.Palette.primaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                #else
                Link(destination: configureURL) {
                    Label("Open setup page", systemImage: "arrow.up.forward.app")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.Palette.accent)
                #endif
            }

            Button("Close") { dismiss() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Palette.tertiaryText)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .themedBackground()
    }
}
