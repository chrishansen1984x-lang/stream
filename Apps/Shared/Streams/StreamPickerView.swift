import SwiftUI
import StreamCore

@Observable
@MainActor
final class StreamPickerViewModel {
    private(set) var streams: [RankedStream] = []
    /// Everything that resolved, before the user's exclusions.
    private(set) var allStreams: [RankedStream] = []
    /// Sources that resolved but were removed by the user's own filters.
    private(set) var hiddenByFilters = 0
    private(set) var failures: [AddonFailure] = []
    private(set) var isResolving = false
    private(set) var respondedAddons = 0
    private(set) var totalAddons = 0

    /// Consumes the resolver's progressive stream so results appear as each addon
    /// answers, rather than after the slowest one.
    func resolve(
        target: StreamTarget,
        registry: AddonRegistry,
        resolver: StreamResolver,
        preferences: RankingPreferences
    ) async {
        isResolving = true
        streams = []
        allStreams = []
        hiddenByFilters = 0
        failures = []
        respondedAddons = 0

        let addons = registry.enabledAddons
        totalAddons = addons.filter {
            $0.supports(.stream, type: target.type, id: target.videoId)
        }.count

        var collected: [RankedStream] = []

        for await result in resolver.resolve(type: target.type, id: target.videoId, from: addons) {
            respondedAddons += 1
            switch result {
            case .success(let batch):
                collected.append(contentsOf: batch)
                // Re-rank on every batch so the list stays correctly ordered while filling.
                streams = StreamRanker.rank(collected, preferences: preferences)
                // Counted separately so an empty list can say whether the title
                // has no sources or only ones the user chose to hide.
                allStreams = StreamRanker.rank(collected, preferences: .init(
                    resolutionLadder: preferences.resolutionLadder,
                    excludeLowQualitySources: false,
                    excludeHDR: false,
                    preferCached: preferences.preferCached,
                    maxSizeBytes: nil,
                    requiredLanguages: [],
                    tagRules: []
                ))
                hiddenByFilters = StreamRanker.excludedCount(
                    of: allStreams, preferences: preferences
                )
            case .failure(let failure):
                failures.append(failure)
            }
        }

        isResolving = false
    }
}

struct StreamPickerView: View {
    let target: StreamTarget

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = StreamPickerViewModel()
    @State private var playing: RankedStream?
    /// Set by the empty state's escape hatch, to list what the filters removed.
    @State private var showsFilteredSources = false

    var body: some View {
        NavigationStack {
            Group {
                if visibleStreams.isEmpty && !viewModel.isResolving {
                    emptyState
                } else {
                    list
                }
            }
            .themedBackground()
            .navigationTitle("Sources")
            .navigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            await viewModel.resolve(
                target: target,
                registry: model.registry,
                resolver: model.resolver,
                preferences: model.preferences
            )
        }
        .presentPlayer(
            item: $playing,
            context: PlaybackContext(
                videoId: target.videoId,
                metaId: target.metaId,
                type: target.type,
                title: target.title,
                startAt: model.watchState.progress(for: target.videoId)
                    .flatMap { $0.isResumable ? $0.position : nil }
            )
        )
    }

    private var list: some View {
        List {
            // Neutral copy on purpose. The count of addons being queried is internal
            // mechanics, not something to narrate to the user mid-load.
            if viewModel.isResolving && viewModel.totalAddons > 0 {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading…")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .listRowBackground(Color.clear)
            }

            ForEach(visibleStreams) { stream in
                Button {
                    playing = stream
                    #if os(macOS)
                    // Close the sheet. It is modal to the main window, so the
                    // player opened behind it and picking a source looked like it
                    // did nothing. Deferred a turn so `presentPlayer` sees the
                    // change before this view goes away.
                    //
                    // macOS only: on iOS the player is a cover presented *by* this
                    // view, so dismissing here would tear it down.
                    DispatchQueue.main.async { dismiss() }
                    #endif
                } label: {
                    // The first row is what Play would have chosen. Saying so tells
                    // the user what they are overriding.
                    StreamRow(
                        item: stream,
                        isBestMatch: stream.id == bestMatchId && !viewModel.isResolving,
                        maxResolution: model.preferences.maxResolution
                    )
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.Palette.surface)
            }

            // Diagnostics are opt-in; by default a failing addon is silent and the
            // user simply sees fewer results.
            if model.showsDiagnostics && !viewModel.failures.isEmpty {
                Section("Diagnostics") {
                    ForEach(viewModel.failures, id: \.self) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.addonName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Text(failure.message)
                                .font(Theme.Typography.fine)
                                .foregroundStyle(Theme.Palette.tertiaryText)
                        }
                    }
                    .listRowBackground(Theme.Palette.surface)
                }
            }
        }
        .listStyle(.plain)
        .clearScrollBackground()
    }

    /// What the list shows: the filtered set, or everything once the viewer has
    /// asked to see what was removed.
    private var visibleStreams: [RankedStream] {
        showsFilteredSources ? viewModel.allStreams : viewModel.streams
    }

    /// The source Play would have chosen — the first of `autoPlayOrder`, not row
    /// zero. Row zero of `rank` can be a torrent or an over-ceiling release, and
    /// with hidden sources shown it was whatever the filters had removed.
    private var bestMatchId: String? {
        StreamRanker.autoPlayOrder(of: viewModel.streams, preferences: model.preferences).first?.id
    }

    /// Deliberately says nothing about addons, counts, or what was queried — the
    /// user gets a result, not a description of the machinery behind it.
    private var emptyState: some View {
        // "Try again later" is wrong when sources exist and the user is hiding
        // them — nothing changes by waiting, and the setting responsible is not
        // mentioned anywhere. That case gets its own message and a way out.
        if viewModel.hiddenByFilters > 0 {
            return AnyView(
                VStack(spacing: 14) {
                    StateMessage(
                        icon: "line.3.horizontal.decrease.circle",
                        title: viewModel.hiddenByFilters == 1
                            ? "1 source hidden by your filters"
                            : "\(viewModel.hiddenByFilters) sources hidden by your filters",
                        message: hiddenExplanation
                    )

                    Button("Show hidden sources") {
                        showsFilteredSources = true
                    }
                    .buttonStyle(OutlineButtonStyle())
                }
            )
        }

        // A fresh install has no source addon at all, and "try again later" is
        // the wrong advice for that: nothing changes by waiting. Say what is
        // missing and open the place it is added.
        if model.registry.addons(providing: .stream).isEmpty {
            return AnyView(
                StateMessage(
                    icon: "puzzlepiece.extension",
                    title: "No source addons yet",
                    message: UnavailableCopy.noSourceAddon,
                    actionTitle: "Open Settings",
                    action: {
                        dismiss()
                        model.present(link: .settings)
                    }
                )
            )
        }

        return AnyView(
            StateMessage(
                icon: "play.slash",
                title: "Not currently available",
                message: model.showsDiagnostics
                    ? "No installed addon returned a source for this title."
                    : "This title can't be played right now. Try again later."
            )
        )
    }

    /// Names the setting doing the hiding, so it can be found and changed.
    private var hiddenExplanation: String {
        var reasons: [String] = []
        if model.preferences.excludeLowQualitySources { reasons.append("CAM and screener sources") }
        if model.preferences.excludeHDR { reasons.append("HDR sources") }
        if !model.preferences.tagRules.filter({ $0.effect == .exclude }).isEmpty {
            reasons.append("your tag rules")
        }
        guard !reasons.isEmpty else { return "Change your source filters in Settings to see them." }
        return "Hiding " + reasons.joined(separator: " and ") + ", set in Settings."
    }
}

/// What a viewer is told when nothing can play.
enum UnavailableCopy {
    static let noSourceAddon = "Stream ships with no sources. Add a stream addon under "
        + "Settings › Addons › Browse addons, then try again."
}

extension View {
    /// The "cannot play" alert, aware of whether the reason is a missing addon.
    func unavailableAlert(isPresented: Binding<Bool>) -> some View {
        modifier(UnavailableAlert(isPresented: isPresented))
    }
}

private struct UnavailableAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppModel.self) private var model

    private var hasSourceAddon: Bool {
        !model.registry.addons(providing: .stream).isEmpty
    }

    func body(content: Content) -> some View {
        content.alert(
            hasSourceAddon ? "Not currently available" : "No source addons yet",
            isPresented: $isPresented
        ) {
            if !hasSourceAddon {
                Button("Open Settings") { model.present(link: .settings) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(hasSourceAddon
                 ? "This title can't be played right now. Try again later."
                 : UnavailableCopy.noSourceAddon)
        }
    }
}

/// One resolved source, with its parsed attributes surfaced as chips.
struct StreamRow: View {
    let item: RankedStream
    var isBestMatch: Bool = false
    /// The user's quality ceiling, so a source above it can say so. Without this a
    /// 4K release sorted below a 1080p one looks like the ranking is simply wrong.
    var maxResolution: StreamAttributes.Resolution?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if item.attributes.isCached {
                    Image(systemName: "bolt.fill")
                        .font(Theme.Typography.fine)
                        .foregroundStyle(Theme.Palette.cached)
                }
                if isBestMatch {
                    Chip(text: "BEST MATCH", tint: Theme.Palette.accent, filled: true)
                }
                Text(item.addonName)
                    .font(Theme.Typography.fine.weight(.bold))
                    .foregroundStyle(Theme.Palette.accent)

                // The service or quality tag, e.g. "Disney Plus" — without this the
                // row says "Subscription" and never says of what.
                if let source = item.stream.sourceLabel(addonName: item.stream.addonName) {
                    Text(source)
                        .font(Theme.Typography.fine.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if !item.stream.isDirectlyPlayable {
                    // Honest signal: an App Store build cannot resolve this itself.
                    Chip(text: item.stream.isTorrent ? "TORRENT" : "EXTERNAL")
                }
            }

            Text(item.stream.displayTitle)
                .font(.caption)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            attributeChips
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    /// Four chips, not seven.
    ///
    /// Resolution, source, audio, and size are what people actually choose on. Codec,
    /// HDR flavour, and seeder count move to a dimmer secondary line so the row can be
    /// scanned in one pass instead of read.
    private var attributeChips: some View {
        let attributes = item.attributes
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let resolution = attributes.resolution {
                    Chip(text: resolution.label, tint: tint(for: resolution), filled: true)
                }
                if let source = attributes.source {
                    Chip(text: source.label)
                }
                if let audio = attributes.audioCodec {
                    Chip(text: [audio.rawValue, attributes.audioChannels].compactMap { $0 }.joined(separator: " "))
                }
                if let size = attributes.sizeLabel {
                    Chip(text: size)
                }
            }

            if !secondaryAttributes.isEmpty {
                Text(secondaryAttributes.joined(separator: " · "))
                    .font(Theme.Typography.fine)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
    }

    private var secondaryAttributes: [String] {
        let attributes = item.attributes
        var parts: [String] = []
        if let codec = attributes.videoCodec { parts.append(codec.rawValue) }
        parts.append(contentsOf: attributes.hdr.map(\.rawValue).sorted())
        if let seeders = attributes.seeders { parts.append("\(seeders) seeders") }
        // Says why a source may behave differently, without shouting about it.
        if attributes.audioCodec?.requiresSoftwareDecode == true { parts.append("software decode") }
        // Dolby Vision with no HDR10 base layer is Profile 5, which the player renders
        // with magenta skin and green shadows. The ranker demotes it, but it stays
        // selectable, so a manual pick should not be a silent trap.
        if attributes.isLikelyDolbyVisionProfile5 { parts.append("colour unsupported") }
        // Explains the demotion rather than leaving it looking like a mis-sort.
        if let maxResolution, let resolution = attributes.resolution, resolution > maxResolution {
            parts.append("above your maximum")
        }
        return parts
    }

    private func tint(for resolution: StreamAttributes.Resolution) -> Color {
        switch resolution {
        case .fourK, .twoK: Theme.Palette.tier4K
        case .fullHD, .hd: Theme.Palette.tierHD
        case .sd: Theme.Palette.tierSD
        }
    }
}
