import SwiftUI
import StreamCore
import Security

struct AddonsView: View {
    /// A short list rather than every ISO code — these cover the languages
    /// multi-audio releases actually ship.
    static let languageOptions: [(String, String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"),
        ("ru", "Russian"), ("ja", "Japanese"), ("ko", "Korean"), ("zh", "Chinese"),
        ("hi", "Hindi"), ("ar", "Arabic")
    ]

    /// Presented as a sheet rather than as a destination. A sheet needs its own
    /// way out — swipe-to-dismiss alone is easy to miss on a long scrolling list.
    var isModal = false

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var newAddonURL = ""
    @State private var isInstalling = false
    @State private var installError: String?
    @State private var showingInstaller = false
    @State private var showingDiscover = false
    @State private var screenQueueDepth = 0
    /// Held locally until saved, so the keychain is written once and the section
    /// does not restructure while the field has focus.
    @State private var tokenDraft = ""
    @State private var tokenWriteFailure: OSStatus?
    @State private var screenFailure: String?
    @State private var screenLastSent = "Nothing yet"

    var body: some View {
        NavigationStack {
            List {
                addonSection
                rankingSection
                enrichmentSection
                remoteSyncSection
                // Screen is a companion app most people do not have. The section
                // appears once a token is stored, or when diagnostics are on —
                // which is where anyone setting it up will already be.
                if !model.screenToken.isEmpty || model.showsDiagnostics {
                    screenSection
                }
                traktSection
                diagnosticsSection
                aboutSection
            }
            .settingsListStyle()
            .clearScrollBackground()
            // A draft lives in view state, and every way out of Settings throws
            // view state away — the iOS sheet's Done, a macOS sidebar switch, and
            // tvOS's Menu button, which is also how the keyboard is dismissed. The
            // write-through binding this replaced could not lose a token that way,
            // so the draft has to be committed rather than dropped.
            .onDisappear { commitPendingToken() }
            // A settings row spanning the full 1920pt width is unreadable; the
            // eye cannot connect a label on the left to its value on the right.
            .frame(maxWidth: Theme.Metrics.settingsWidth)
            .frame(maxWidth: .infinity)
            .themedBackground()
            .navigationTitle(Theme.isTelevision ? "" : "Settings")
            .toolbar {
                if isModal {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            commitPendingToken()
                            dismiss()
                        }
                    }
                }
            }
            .toolbar {
                if !Theme.isTelevision {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showingInstaller = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingDiscover) {
                DiscoverAddonsView().sheetSize(width: 720, height: 620)
            }
            .alert("Add addon", isPresented: $showingInstaller) {
                addonURLField
                Button("Cancel", role: .cancel) { newAddonURL = "" }
                Button("Install") { install() }
            } message: {
                Text("Paste an addon's manifest URL.")
            }
            .alert(
                "Could not install",
                isPresented: .init(get: { installError != nil }, set: { if !$0 { installError = nil } })
            ) {
                Button("OK", role: .cancel) { installError = nil }
            } message: {
                Text(installError ?? "")
            }
        }
    }

    /// `textInputAutocapitalization` is iOS/tvOS-only; macOS has no equivalent
    /// because it never autocapitalizes text fields.
    @ViewBuilder
    private var addonURLField: some View {
        let field = TextField("https://…/manifest.json", text: $newAddonURL)
            .autocorrectionDisabled()
        #if os(iOS) || os(tvOS)
        field.textInputAutocapitalization(.never)
        #else
        field
        #endif
    }

    // MARK: - Addons

    @ViewBuilder
    private var addonSection: some View {
        Section {
            if model.registry.addons.isEmpty {
                Text("No addons installed.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            } else {
                ForEach(Array(model.registry.addons.enumerated()), id: \.element.id) { index, addon in
                    AddonRow(addon: addon)
                        #if !os(iOS)
                        // Neither tvOS nor macOS has swipe-to-delete in a List, so
                        // `onDelete`/`onMove` below are unreachable on both and an
                        // addon installed there could never be removed or
                        // reordered — the enable toggle only silenced it. macOS was
                        // the worse of the two, because the footer told the reader
                        // to swipe. A context menu is the same idiom the shelves
                        // already use for remove-from-continue-watching, and it is
                        // right-click on a Mac and a long press on the remote.
                        .contextMenu {
                            Button(role: .destructive) {
                                model.registry.remove(addon)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            if index > 0 {
                                Button {
                                    model.registry.move(
                                        fromOffsets: IndexSet(integer: index),
                                        toOffset: index - 1
                                    )
                                } label: {
                                    Label("Move up", systemImage: "arrow.up")
                                }
                            }
                            if index < model.registry.addons.count - 1 {
                                Button {
                                    // `move(fromOffsets:toOffset:)` inserts *before*
                                    // the destination, so moving down one place is
                                    // index + 2, not index + 1.
                                    model.registry.move(
                                        fromOffsets: IndexSet(integer: index),
                                        toOffset: index + 2
                                    )
                                } label: {
                                    Label("Move down", systemImage: "arrow.down")
                                }
                            }
                        }
                        #endif
                }
                .onDelete { offsets in
                    for index in offsets {
                        model.registry.remove(model.registry.addons[index])
                    }
                }
                .onMove { source, destination in
                    model.registry.move(fromOffsets: source, toOffset: destination)
                }
            }

            if isInstalling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing…").font(.caption)
                }
            }

            Button {
                showingDiscover = true
            } label: {
                Label("Browse addons", systemImage: "square.stack.3d.up")
                    .font(.subheadline)
            }

            if Theme.isTelevision {
                Button {
                    showingInstaller = true
                } label: {
                    Label("Add by URL", systemImage: "plus")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Addons").settingsSectionHeader()
        } footer: {
            // Order is load-bearing, so say so rather than leaving it implicit.
            // The removal gesture differs by input device, and naming the wrong
            // one is worse than naming none.
            // Names the gesture the reader actually has. Naming the wrong one is
            // worse than naming none, and "Swipe to remove" on a Mac named a
            // gesture that does not exist for a control that had no other route.
            Text(Self.addonOrderFootnote)
                .settingsFootnote()
        }
    }

    private static var addonOrderFootnote: String {
        let order = "Order determines shelf order on Home and the priority of metadata lookups."
        #if os(iOS)
        return order + " Swipe to remove."
        #elseif os(macOS)
        return order + " Right-click to remove or reorder."
        #else
        return order + " Hold Select to remove or reorder."
        #endif
    }

    /// A labelled credential row.
    ///
    /// The label sits above the field rather than beside it. `LabeledContent` puts
    /// the field in the value position, so an unfilled one rendered as
    /// "Client secret … Required" — which reads as a value the row is asserting
    /// rather than a prompt for something you have not entered yet.
    @ViewBuilder
    private func credentialRow(
        _ label: String,
        prompt: String,
        text: Binding<String>,
        secure: Bool = true,
        onSubmit: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(Theme.Typography.fine)
                .foregroundStyle(Theme.Palette.tertiaryText)
            Group {
                if secure {
                    SecureField(prompt, text: text)
                } else {
                    TextField(prompt, text: text)
                }
            }
            .autocorrectionDisabled()
            .onSubmit { onSubmit?() }
        }
        .padding(.vertical, 2)
    }

    private func install() {
        let url = newAddonURL
        newAddonURL = ""
        guard !url.isEmpty else { return }

        isInstalling = true
        Task {
            do {
                try await model.installAddon(from: url)
            } catch {
                installError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isInstalling = false
        }
    }

    // MARK: - Ranking

    @ViewBuilder
    private var rankingSection: some View {
        @Bindable var model = model

        Section {
            Picker("Maximum quality", selection: $model.preferences.maxResolution) {
                Text("No limit").tag(StreamAttributes.Resolution?.none)
                ForEach(
                    StreamAttributes.Resolution.allCases.sorted(by: >),
                    id: \.self
                ) { resolution in
                    Text(resolution.label).tag(StreamAttributes.Resolution?.some(resolution))
                }
            }

            Toggle("Hide CAM and screener sources", isOn: $model.preferences.excludeLowQualitySources)
            Toggle("Prefer instantly available sources", isOn: $model.preferences.preferCached)
            Toggle("Hide HDR sources", isOn: $model.preferences.excludeHDR)
        } header: {
            Text("Source ranking").settingsSectionHeader()
        } footer: {
            // Says plainly that the ceiling is not a filter, because the list will
            // still show things above it and that would otherwise look like a bug.
            Text("""
            Applied when sorting sources and when picking the best one automatically. \
            Sources above the maximum are still listed and can be chosen by hand.
            """)
            .settingsFootnote()
        }
    }

    @ViewBuilder
    private var enrichmentSection: some View {
        @Bindable var model = model

        Section {
            // Labelled, not just placeheld. This is a List rather than a Form, so
            // a placeholder is the only thing naming the field — and it disappears
            // the moment the field is filled, leaving a row of dots with nothing to
            // say which credential it is.
            credentialRow("TMDB API key", prompt: "Optional", text: $model.tmdbApiKey)
        } header: {
            Text("Artwork").settingsSectionHeader()
        } footer: {
            Text("Optional. Adds network and studio logos and cast photos, which addons don't provide. Everything works without it.")
            .settingsFootnote()
        }
    }

    /// Trakt: cross-device progress that needs no Apple entitlement and works on a
    /// TV, because the device flow authorizes on a phone instead of a browser.
    @ViewBuilder
    private var traktSection: some View {
        @Bindable var trakt = model.trakt

        Section {
            switch model.trakt.state {
            case .awaitingAuthorization(let code, let url):
                VStack(alignment: .leading, spacing: 6) {
                    Text("Go to \(url) and enter:")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    Text(code)
                        .font(.title2.monospaced().weight(.bold))
                        .foregroundStyle(Theme.Palette.primaryText)
                        // tvOS has no text selection; the code is read off the
                        // screen there anyway, which is the point of device auth.
                        .selectableTextIfAvailable()
                    Button("Cancel") { model.trakt.cancelConnect() }
                        .font(.caption)
                }
                .padding(.vertical, 4)

            case .connected:
                LabeledContent("Status", value: model.screen == nil ? "Enter a valid HTTPS server URL" : "Configured")
                if let lastSync = model.trakt.lastSync {
                    LabeledContent("Last sync", value: lastSync.formatted(date: .omitted, time: .shortened))
                }
                Button("Disconnect", role: .destructive) { model.trakt.disconnect() }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.accentWarm)
                Button("Try again") { model.trakt.connect() }

            case .disconnected:
                credentialRow("Client ID", prompt: "Required",
                              text: $trakt.clientId, secure: false)
                credentialRow("Client secret", prompt: "Required", text: $trakt.clientSecret)
                Button("Connect") { model.trakt.connect() }
                    // Left focusable on a TV: `isConfigured` flips while the secret
                    // is being typed, and a disabled Button drops out of the focus
                    // map, moving focus out from under the remote mid-entry.
                    .disabled(!Theme.isTelevision && !model.trakt.isConfigured)
                if model.trakt.isConfigured {
                    Button("Forget credentials", role: .destructive) { model.trakt.forgetCredentials() }
                }
            }
        } header: {
            Text("Trakt").settingsSectionHeader()
        } footer: {
            Text("Optional. Syncs continue-watching with Trakt and any other app that reports to it. Trakt asks each app to register: create one at trakt.tv/oauth/applications with redirect URI urn:ietf:wg:oauth:2.0:oob, then paste its client ID and secret here.")
            .settingsFootnote()
        }
    }

    @ViewBuilder
    private var screenSection: some View {
        @Bindable var model = model
        Section {
            TextField("Screen server URL (https://…/watch-events)", text: $model.screenEndpointURL)
            Text("Optional. Enter your own Screen server URL and device token to send watch history. Leave the URL blank to keep this off.")
                .settingsFootnote()
            // Two states, the same split Trakt uses: entry until it is configured,
            // then status and actions. Six rows for one setting — a field, a save,
            // a confirmation, a queue depth and two more buttons — was the whole
            // problem. The entry field is not rendered once a token is stored, so
            // there is also nothing left to lose focus.
            if model.screenToken.isEmpty {
                credentialRow("Device token", prompt: "Paste it here",
                              text: $tokenDraft, onSubmit: saveScreenToken)
                // Never `.disabled`: a disabled Button is not focusable on tvOS, so
                // the focus map would change on the first character typed.
                Button("Save token") { saveScreenToken() }

                if let code = tokenWriteFailure {
                    Text("Saved for now, but the keychain refused to keep it (status \(code)). It will be gone when Stream restarts.")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.accentWarm)
                }

                Text("Screen → Your year → Connected apps → Create token.")
                    .settingsFootnote()
            } else {
                LabeledContent("Status", value: model.screen == nil ? "Enter a valid HTTPS server URL" : "Configured")
                LabeledContent("Waiting to send", value: "\(screenQueueDepth)")
                LabeledContent("Last sent", value: screenLastSent)
                if let failure = screenFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.accentWarm)
                }
                Button("Send now") {
                    Task {
                        await model.flushScreen()
                        await refreshScreenStatus()
                    }
                }
                Button("Forget token", role: .destructive) { model.forgetScreenToken() }
            }
        } header: {
            Text("Screen").settingsSectionHeader()
        } footer: {
            Text("""
            Finished films and episodes are reported to Screen. Anything sent while \
            offline is queued and retried, and re-sending the same title is ignored \
            there, so nothing is counted twice.
            """)
            .settingsFootnote()
        }
        .task(id: model.screenToken) { await refreshScreenStatus() }
    }

    /// Commits the draft. The draft is never seeded from the stored token — a live
    /// credential has no business sitting in view state, and "enter a new one to
    /// replace it" is clearer than a field pre-filled with dots you must not clear.
    /// Saves anything typed but not yet submitted, on the way out of Settings.
    private func commitPendingToken() {
        guard !tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saveScreenToken()
    }

    private func saveScreenToken() {
        switch model.saveScreenToken(tokenDraft) {
        case .ignored:
            // Return on an empty field is not a failure and must not be reported
            // as one — it would put a storage error on screen in the exact words
            // of a real one.
            break
        case .saved:
            tokenWriteFailure = nil
            tokenDraft = ""
        case .notPersisted(let status):
            tokenWriteFailure = status
            tokenDraft = ""
        }
    }

    /// Reading the actor's state needs an await, so it is mirrored into view state
    /// rather than read from the body.
    private func refreshScreenStatus() async {
        guard let screen = model.screen else {
            screenQueueDepth = 0
            screenFailure = nil
            return
        }
        screenQueueDepth = await screen.queueDepth
        screenFailure = await screen.lastFailure
        if let sent = await screen.lastSent {
            let title = await screen.lastSentTitle
            let time = sent.formatted(date: .omitted, time: .shortened)
            screenLastSent = title.map { "\($0) · \(time)" } ?? time
        } else {
            screenLastSent = "Nothing yet"
        }
    }

    /// A personal sync endpoint. Unlike Trakt, this carries addons and preferences
    /// too, so a fresh install needs no manual reconfiguration.
    @ViewBuilder
    private var remoteSyncSection: some View {
        @Bindable var sync = model.remoteSync

        Section {
            credentialRow("Endpoint", prompt: "https://…workers.dev",
                          text: $sync.endpoint, secure: false)
            credentialRow("Token", prompt: "Required", text: $sync.token)
            LabeledContent("Status", value: model.remoteSync.isConfigured ? "Connected" : "Not set up")
            if !model.remoteSync.token.isEmpty {
                // The field cannot clear the token — an empty value is never
                // written to the keychain — so disconnecting needs its own control.
                Button("Disconnect", role: .destructive) { model.remoteSync.forgetToken() }
            }

            if case .failed(let message) = model.remoteSync.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.accentWarm)
            } else if let lastSync = model.remoteSync.lastSync {
                LabeledContent("Last sync", value: lastSync.formatted(date: .omitted, time: .shortened))
            }

            Button("Sync now") {
                Task { await model.syncOnLaunch(); model.pushRemoteState() }
            }
            .disabled(!Theme.isTelevision && !model.remoteSync.isConfigured)
        } header: {
            Text("Device sync").settingsSectionHeader()
        } footer: {
            Text("Optional. Syncs continue-watching, installed addons, and preferences across your devices through a small server you host yourself — the Cloudflare Worker in the project's Sync folder. Leave empty if you only use one device.")
            .settingsFootnote()
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        @Bindable var model = model

        Section {
            Picker("Preferred language", selection: $model.preferredLanguage) {
                ForEach(Self.languageOptions, id: \.0) { code, name in
                    Text(name).tag(code)
                }
            }
            // tvOS's automatic picker style is a horizontal segmented strip; with
            // fourteen options it collapsed to a row of unlabelled dots.
            .languagePickerStyle()
            Toggle("Show diagnostics", isOn: $model.showsDiagnostics)
        } header: {
            Text("Playback").settingsSectionHeader()
        } footer: {
            Text("Preferred language selects the matching audio track on multi-language releases, and turns off forced subtitles in other languages.")
            .settingsFootnote()
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Installed addons", value: "\(model.registry.addons.count)")
            LabeledContent("Catalogs", value: "\(model.registry.homeCatalogs.count)")
            LabeledContent("Stream providers", value: "\(model.registry.addons(providing: .stream).count)")
        } header: {
            Text("About").settingsSectionHeader()
        } footer: {
            Text("Stream \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ships with no content addons. Catalogs and sources come only from addons you install yourself.")
            .settingsFootnote()
        }
    }
}

struct AddonRow: View {
    @Environment(AppModel.self) private var model
    let addon: Addon

    var body: some View {
        HStack(spacing: 12) {
            // Addon logos are arbitrary aspect ratios; filling crops wide wordmarks.
            RemoteImage(string: addon.manifest.logo, contentMode: .fit)
                .frame(width: Theme.Metrics.logoBox, height: Theme.Metrics.logoBox)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(addon.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)

                Text(capabilitySummary)
                    .font(Theme.Typography.fine)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Toggle(
                "",
                isOn: .init(
                    get: { addon.isEnabled },
                    set: { model.registry.setEnabled($0, for: addon) }
                )
            )
            .labelsHidden()
        }
    }

    /// Shows what the addon actually provides — the thing users need when
    /// debugging why a title has no sources.
    private var capabilitySummary: String {
        let resources = addon.manifest.resources
            .map(\.name.rawValue)
            .filter { $0 != "addon_catalog" }
        return resources.isEmpty ? "No resources" : resources.joined(separator: " · ")
    }
}
