import Testing
import Foundation
@testable import StreamCore

@Suite("Release name parsing")
struct ReleaseParserTests {

    @Test("Parses a typical Torrentio result end to end")
    func torrentioStyle() {
        let raw = """
        Torrentio
        The.Matrix.1999.2160p.UHD.BluRay.REMUX.HDR.HEVC.TrueHD.7.1.Atmos-FraMeSToR
        👤 128 💾 54.2 GB ⚙️ FraMeSToR
        """
        let attributes = ReleaseParser.parse(raw)

        #expect(attributes.resolution == .fourK)
        #expect(attributes.source == .remux)
        #expect(attributes.videoCodec == .h265)
        // A bare "HDR" tag is exactly that — not a claim of an HDR10 base layer.
        #expect(attributes.hdr.contains(.hdr))
        #expect(attributes.hdr.contains(.hdr10) == false)
        #expect(attributes.audioCodec == .atmos)
        #expect(attributes.seeders == 128)
        #expect(attributes.releaseGroup == "FraMeSToR")
        #expect(attributes.sizeBytes != nil)
    }

    @Test("Separator normalization handles dots, underscores, and hyphens")
    func separatorNormalization() {
        // These three spellings of the same release must parse identically.
        let variants = [
            "Movie.2020.1080p.WEB-DL.x264.AC3",
            "Movie_2020_1080p_WEB_DL_x264_AC3",
            "Movie 2020 1080p WEB DL x264 AC3"
        ]
        for variant in variants {
            let attributes = ReleaseParser.parse(variant)
            #expect(attributes.resolution == .fullHD, "failed for \(variant)")
            #expect(attributes.source == .webDL, "failed for \(variant)")
            #expect(attributes.videoCodec == .h264, "failed for \(variant)")
        }
    }

    @Test("REMUX is not misread as a BluRay rip")
    func remuxPrecedence() {
        #expect(ReleaseParser.parse("Film 1080p BluRay REMUX AVC").source == .remux)
        #expect(ReleaseParser.parse("Film 1080p BRRip x264").source == .blurayRip)
        #expect(ReleaseParser.parse("Film 1080p BluRay x264").source == .bluray)
    }

    @Test("Detects formats AVPlayer cannot decode")
    func softwareDecodeDetection() {
        // Drives the dual-engine routing decision in AUDIT.md §4.1.
        #expect(ReleaseParser.parse("Film 1080p DTS-HD MA 5.1").audioCodec?.requiresSoftwareDecode == true)
        #expect(ReleaseParser.parse("Film 1080p TrueHD 7.1").audioCodec?.requiresSoftwareDecode == true)
        #expect(ReleaseParser.parse("Film 1080p AAC 2.0").audioCodec?.requiresSoftwareDecode == false)
    }

    @Test("Reads debrid cache markers")
    func cacheMarkers() {
        #expect(ReleaseParser.parse("[RD+] Film 1080p").isCached)
        #expect(ReleaseParser.parse("⚡ Film 1080p").isCached)
        #expect(ReleaseParser.parse("Film 1080p").isCached == false)
    }

    @Test("Sizes convert from both GB and MB")
    func sizeParsing() {
        let gigabytes = ReleaseParser.parse("Film 8.4 GB").sizeBytes
        #expect(gigabytes == Int64(8.4 * 1_073_741_824))

        let megabytes = ReleaseParser.parse("Film 700 MB").sizeBytes
        #expect(megabytes == Int64(700 * 1_048_576))
    }

    @Test("Unparseable text yields empty attributes rather than failing")
    func gracefulOnGarbage() {
        let attributes = ReleaseParser.parse("something entirely unstructured")
        #expect(attributes.resolution == nil)
        #expect(attributes.source == nil)
        #expect(attributes.hdr.isEmpty)
    }
}

@Suite("Stream ranking")
struct StreamRankerTests {

    /// Builds a stream the way an addon would send it — title text only.
    private func makeStream(_ title: String, url: String = "https://example.com/v.mkv") -> RankedStream {
        let json = """
        {"url": "\(url)", "title": "\(title)"}
        """
        let stream = try! JSONDecoder().decode(Stream.self, from: Data(json.utf8))
        return RankedStream(stream: stream, attributes: ReleaseParser.parse(stream))
    }

    @Test("Higher resolution wins by default")
    func resolutionOrdering() {
        let streams = [
            makeStream("Film 720p WEB-DL x264"),
            makeStream("Film 2160p BluRay x265"),
            makeStream("Film 1080p WEB-DL x264")
        ]
        let ranked = StreamRanker.rank(streams)
        #expect(ranked.first?.attributes.resolution == .fourK)
        #expect(ranked.last?.attributes.resolution == .hd)
    }

    @Test("CAM releases are excluded by default")
    func lowQualityExcluded() {
        let streams = [makeStream("Film 1080p HDCAM"), makeStream("Film 1080p WEB-DL")]
        let ranked = StreamRanker.rank(streams)
        #expect(ranked.count == 1)
        #expect(ranked.first?.attributes.source == .webDL)
    }

    @Test("A prefer rule outranks intrinsic quality")
    func tagRulePrecedence() {
        let preferences = RankingPreferences(
            tagRules: [TagRule(name: "My group", pattern: "FraMeSToR", effect: .prefer)]
        )
        let streams = [
            makeStream("Film 2160p BluRay x265"),
            makeStream("Film 1080p WEB-DL x264 FraMeSToR")
        ]
        let ranked = StreamRanker.rank(streams, preferences: preferences)
        #expect(ranked.first?.stream.displayTitle.contains("FraMeSToR") == true)
    }

    // MARK: - Maximum quality

    @Test("A ceiling keeps auto-play at or below it")
    func ceilingGovernsAutoPlay() {
        let streams = [
            makeStream("Film 2160p WEB-DL x265"),
            makeStream("Film 1080p WEB-DL x264"),
            makeStream("Film 720p WEB-DL x264")
        ]
        #expect(StreamRanker.best(of: streams)?.attributes.resolution == .fourK)

        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD
        #expect(StreamRanker.best(of: streams, preferences: preferences)?.attributes.resolution == .fullHD)
    }

    @Test("Sources above the ceiling are demoted, never removed")
    func ceilingDoesNotFilter() {
        let streams = [makeStream("Film 2160p WEB-DL x265"), makeStream("Film 1080p WEB-DL x264")]
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD
        let ranked = StreamRanker.rank(streams, preferences: preferences)

        // The whole point of the setting: it changes the order, not the contents,
        // so a 4K release is still there to be chosen by hand.
        #expect(ranked.count == 2)
        #expect(ranked.first?.attributes.resolution == .fullHD)
        #expect(ranked.last?.attributes.resolution == .fourK)
    }

    @Test("The ceiling outranks a prefer rule on an over-size release")
    func ceilingBeatsPreferRule() {
        // Both are explicit user instructions; the more specific one wins.
        var preferences = RankingPreferences(
            tagRules: [TagRule(name: "My group", pattern: "FraMeSToR", effect: .prefer)]
        )
        preferences.maxResolution = .fullHD
        let streams = [
            makeStream("Film 2160p BluRay x265 FraMeSToR"),
            makeStream("Film 1080p WEB-DL x264")
        ]
        #expect(StreamRanker.best(of: streams, preferences: preferences)?.attributes.resolution == .fullHD)
    }

    @Test("With nothing at or below the ceiling, something is still playable")
    func ceilingNeverLeavesNothingToPlay() {
        // A filter would leave the title unplayable; a demotion still returns the
        // only source there is.
        let streams = [makeStream("Film 2160p WEB-DL x265")]
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD
        #expect(StreamRanker.best(of: streams, preferences: preferences) != nil)
    }

    @Test("An unparsed resolution is never demoted by the ceiling")
    func unknownResolutionIsUnaffected() {
        // Plenty of releases do not state a resolution. Treating "unknown" as "too
        // big" would bury them all the moment a ceiling was set.
        let streams = [makeStream("Some Obscure Release WEB-DL"), makeStream("Film 2160p WEB-DL x265")]
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD
        #expect(StreamRanker.rank(streams, preferences: preferences).first?.attributes.resolution == nil)
    }

    @Test("Preferences stored before the ceiling existed still decode")
    func decodesPreferencesWithoutTheNewKey() throws {
        // Everyone's saved settings predate this field.
        let legacy = """
        {"resolutionLadder":[2160,1080],"excludeLowQualitySources":true,
         "excludeHDR":false,"preferCached":true,"requiredLanguages":[],"tagRules":[]}
        """
        let decoded = try JSONDecoder().decode(RankingPreferences.self, from: Data(legacy.utf8))
        #expect(decoded.maxResolution == nil)
        #expect(decoded.preferCached)
    }

    @Test("The ceiling survives a round trip")
    func ceilingEncodesAndDecodes() throws {
        var preferences = RankingPreferences()
        preferences.maxResolution = .fullHD
        let data = try JSONEncoder().encode(preferences)
        #expect(try JSONDecoder().decode(RankingPreferences.self, from: data).maxResolution == .fullHD)
    }

    @Test("An exclude rule hides matches entirely")
    func excludeRule() {
        let preferences = RankingPreferences(
            tagRules: [TagRule(name: "No x265", pattern: "x265", effect: .exclude)]
        )
        let streams = [makeStream("Film 2160p BluRay x265"), makeStream("Film 1080p WEB-DL x264")]
        let ranked = StreamRanker.rank(streams, preferences: preferences)
        #expect(ranked.count == 1)
        #expect(ranked.first?.attributes.videoCodec == .h264)
    }

    @Test("Invalid regex never matches instead of crashing")
    func malformedRegexIsInert() {
        let rule = TagRule(name: "Broken", pattern: "[unclosed(", effect: .exclude)
        #expect(rule.matches("anything") == false)
    }

    /// Regression: the Profile 5 penalty used to be smaller than the `preferCached`
    /// bonus, so a cached Profile 5 release outranked every uncached alternative —
    /// the ordinary debrid case — and auto-play handed the player a file that renders
    /// with magenta skin and green shadows.
    @Test("A cached Dolby Vision Profile 5 release loses to an uncached alternative")
    func dolbyVisionProfile5LosesToUncachedAlternative() {
        let streams = [
            makeStream("⚡ Silo S01E08 2160p WEBMux DV HEVC Atmos-SGF"),
            makeStream("Silo S01E08 2160p WEB-DL HDR H.265-FLUX")
        ]
        #expect(streams[0].attributes.isCached)
        #expect(streams[0].attributes.isLikelyDolbyVisionProfile5)

        let ranked = StreamRanker.rank(streams)
        #expect(ranked.first?.attributes.isLikelyDolbyVisionProfile5 == false)
        #expect(ranked.last?.attributes.isLikelyDolbyVisionProfile5 == true)
        // Demoted, never hidden: the profile is inferred from the release name.
        #expect(ranked.count == 2)
    }

    /// The penalty and a `prefer` rule are deliberately the same magnitude, so the
    /// rule cancels it rather than overpowering it: the release stops being demoted
    /// and competes on its other merits again — here, being the only cached one.
    @Test("A prefer rule neutralises the Profile 5 penalty")
    func dolbyVisionProfile5YieldsToUserRule() {
        let preferences = RankingPreferences(
            tagRules: [TagRule(name: "My group", pattern: "SGF", effect: .prefer)]
        )
        let streams = [
            makeStream("⚡ Silo S01E08 2160p WEBMux DV HEVC Atmos-SGF"),
            makeStream("Silo S01E08 2160p WEB-DL HDR H.265-FLUX")
        ]
        #expect(StreamRanker.rank(streams).first?.attributes.isLikelyDolbyVisionProfile5 == false)
        let ranked = StreamRanker.rank(streams, preferences: preferences)
        #expect(ranked.first?.attributes.isLikelyDolbyVisionProfile5 == true)
    }

    @Test("Auto-play never selects a non-HTTP source")
    func bestSkipsUnplayable() {
        // A torrent-only result must not be handed to the player in an App Store build.
        let magnetJSON = #"{"infoHash": "abc123", "title": "Film 2160p BluRay x265"}"#
        let magnet = try! JSONDecoder().decode(Stream.self, from: Data(magnetJSON.utf8))
        let streams = [
            RankedStream(stream: magnet, attributes: ReleaseParser.parse(magnet)),
            makeStream("Film 1080p WEB-DL x264")
        ]
        let best = StreamRanker.best(of: streams)
        #expect(best?.stream.isDirectlyPlayable == true)
        #expect(best?.attributes.resolution == .fullHD)
    }
}

@Suite("Stream resolution")
struct StreamResolverTests {

    private func makeAddon(resources: String, types: String = #"["movie"]"#) throws -> Addon {
        let json = """
        {"id":"org.test","name":"Test","version":"1.0","types":\(types),
         "catalogs":[],"resources":\(resources)}
        """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        return Addon(manifest: manifest, transportURL: URL(string: "https://test.example/manifest.json")!)
    }

    @Test("Finishes immediately when no addon provides streams", .timeLimit(.minutes(1)))
    func noCapableAddonsReturnsAtOnce() async throws {
        // Regression: the fan-out raced a deadline task, so a caller with zero stream
        // addons sat on a spinner for the full 15s before the stream closed.
        let metadataOnly = try makeAddon(resources: #"["catalog","meta"]"#)
        let resolver = StreamResolver(client: AddonClient())

        let start = ContinuousClock.now
        var received = 0
        for await _ in resolver.resolve(type: .movie, id: "tt0111161", from: [metadataOnly]) {
            received += 1
        }
        let elapsed = ContinuousClock.now - start

        #expect(received == 0)
        #expect(elapsed < .seconds(1))
    }

    @Test("Addons that cannot serve the requested type are not queried")
    func routingExcludesIncapableAddons() throws {
        let seriesOnly = try makeAddon(resources: #"["stream"]"#, types: #"["series"]"#)
        #expect(seriesOnly.supports(.stream, type: .series))
        #expect(seriesOnly.supports(.stream, type: .movie) == false)
    }

    @Test("A disabled addon is never queried")
    func disabledAddonsExcluded() throws {
        var addon = try makeAddon(resources: #"["stream"]"#)
        #expect(addon.supports(.stream, type: .movie))
        addon.isEnabled = false
        #expect(addon.supports(.stream, type: .movie) == false)
    }
}

@Suite("Addon protocol")
struct AddonProtocolTests {

    @Test("Transport URL normalization accepts the forms users paste")
    func urlNormalization() {
        let expected = "https://v3-cinemeta.strem.io/manifest.json"
        #expect(AddonClient.normalizeTransportURL("https://v3-cinemeta.strem.io/manifest.json") == expected)
        #expect(AddonClient.normalizeTransportURL("https://v3-cinemeta.strem.io/") == expected)
        #expect(AddonClient.normalizeTransportURL("v3-cinemeta.strem.io") == expected)
        #expect(AddonClient.normalizeTransportURL("stremio://v3-cinemeta.strem.io/manifest.json") == expected)
    }

    @Test("Configuration path segments survive normalization")
    func configuredAddonURL() {
        // Configured addons carry a blob in the path; losing it breaks the addon.
        let configured = "https://torrentio.example/providers=yts%7Csort=size/manifest.json"
        #expect(AddonClient.normalizeTransportURL(configured) == configured)
    }

    @Test("Resources decode in both short and long form")
    func resourceDescriptorForms() throws {
        let json = """
        {
          "id": "org.example", "name": "Example", "version": "1.0",
          "types": ["movie"],
          "catalogs": [],
          "resources": [
            "catalog",
            { "name": "stream", "types": ["series"], "idPrefixes": ["tt"] }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))
        #expect(manifest.resources.count == 2)

        // Short form inherits the manifest's types.
        #expect(manifest.supports(.catalog, type: .movie))
        // Long form overrides them.
        #expect(manifest.supports(.stream, type: .series, id: "tt123"))
        #expect(manifest.supports(.stream, type: .movie) == false)
        // And enforces its own id prefixes.
        #expect(manifest.supports(.stream, type: .series, id: "kitsu:42") == false)
    }

    @Test("Availability addons surface the service name, not just the offer type")
    func sourceLabelling() throws {
        // WatchHub puts the service in `name` and the offer in `title`. Showing only
        // the title gives a row that reads "Subscription" and never says of what.
        let json = #"{"name":"Disney Plus","title":"Subscription","externalUrl":"https://example.com"}"#
        var stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))
        stream.addonName = "WatchHub"

        #expect(stream.displayTitle == "Subscription")
        #expect(stream.sourceLabel(addonName: "WatchHub") == "Disney Plus")
    }

    @Test("A source label that just repeats the addon name is dropped")
    func redundantSourceLabel() throws {
        // Torrentio-style: `name` leads with the addon's own name, which the row
        // already displays.
        let json = "{\"infoHash\":\"abc\",\"name\":\"Torrentio\\n1080p\",\"title\":\"Film 1080p WEB-DL\"}"
        let stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))

        #expect(stream.sourceLabel(addonName: "Torrentio") == nil)
        #expect(stream.sourceLabel(addonName: "Other") == "Torrentio")
        #expect(stream.displayTitle == "Film 1080p WEB-DL")
    }

    @Test("Aggregator streams with no title fall back to the release filename")
    func aggregatorDisplayTitle() throws {
        // AIOStreams omits `title`, puts the release string in `name`, and a decorated
        // multi-line summary in `description`. Neither reads well as a row label.
        let json = """
        {"url":"https://host/playback/opaquetoken",
         "name":"Spider-Man.2021.2160p.BluRay.Remux.mkv, TrueHD,4K,HDR",
         "description":"⌁ Spider-man (2021)\\n⛁ 66.14 GB · ⟳ 148 min\\n⭑ Comet",
         "behaviorHints":{"filename":"Spider-Man.2021.2160p.BluRay.Remux.mkv","cached":true}}
        """
        var stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))
        stream.addonName = "AIOStreams"

        #expect(stream.displayTitle == "Spider-Man.2021.2160p.BluRay.Remux.mkv")
        // The name is the release string again, not a short label — suppress it.
        #expect(stream.sourceLabel(addonName: "AIOStreams") == nil)
        #expect(stream.behaviorHints?.containerExtension == "mkv")
    }

    /// Regression: AIOStreams appends a generic tag list to every stream name. The
    /// bare "HDR" in it was folded into `.hdr10`, which is the exact signal
    /// `isLikelyDolbyVisionProfile5` reads as "this carries an HDR10 base layer". A
    /// Profile 5 release therefore looked safe and became auto-play's pick, and the
    /// picture came out with magenta skin and green shadows.
    @Test("A generic HDR tag from the aggregator does not mask Dolby Vision Profile 5")
    func genericHDRTagDoesNotMaskProfile5() {
        // The real Silo release: `DV` alone in the name, `,HDR,DV` appended by
        // AIOStreams. It was Profile 5 and rendered magenta. The appended tag must
        // not rescue it.
        let aioStreamsLabel = "Silo.S01E08.2160p.WEBMux.DV.HEVC.Atmos-SGF.mkv, ATMOS,4K,HDR,DV,ATMOS,Season Pack"
        let attributes = ReleaseParser.parse(aioStreamsLabel)
        #expect(attributes.hdr.contains(.hdr))
        #expect(attributes.hdr.contains(.dolbyVision))
        #expect(attributes.hdr.contains(.hdr10) == false)
        #expect(attributes.releaseNameDeclaresHDR == false)
        #expect(attributes.isLikelyDolbyVisionProfile5)

        // An explicit HDR10 mention is still a genuine Profile 7/8 tell.
        let profile8 = ReleaseParser.parse("Silo.S01E08.2160p.WEB-DL.DV.HDR10.H.265-NTb.mkv")
        #expect(profile8.hdr.contains(.hdr10))
        #expect(profile8.isLikelyDolbyVisionProfile5 == false)
    }

    /// The other half of the same coin. `DV.HDR` in the *release name* is the scene
    /// convention for a DV release with an HDR10 base layer, and the one shape of
    /// name that separated the 4K that played from the one that rendered magenta.
    @Test("DV with HDR in the release name itself is not treated as Profile 5")
    func dvWithHDRInTheNameIsNotProfile5() {
        let label = "Hysteria.2024.S01E06.Speaking.in.Tongues.2160p.PCOK.WEB-DL.DDP5.1.DV.HDR.x265-FLUX_EniaHD.mkv, DD+,4K,HDR,DV"
        let attributes = ReleaseParser.parse(label)
        #expect(attributes.hdr.contains(.dolbyVision))
        #expect(attributes.releaseNameDeclaresHDR)
        #expect(attributes.isLikelyDolbyVisionProfile5 == false)

        // Same release handed over as a Stream with a clean `filename` hint.
        let stream = StreamCore.Stream(
            url: "https://example.test/x",
            name: "AIOStreams, DD+,4K,HDR,DV",
            behaviorHints: StreamBehaviorHints(
                filename: "Hysteria.2024.S01E06.2160p.PCOK.WEB-DL.DDP5.1.DV.HDR.x265-FLUX.mkv"
            )
        )
        #expect(ReleaseParser.parse(stream).isLikelyDolbyVisionProfile5 == false)
    }

    /// `contains("cached")` matched its own opposite and handed every row of a
    /// wordy addon the +5000 cached bonus.
    @Test("Cached is a whole word, and never its own negation")
    func cachedIsNotItsOwnNegation() {
        #expect(ReleaseParser.parse("Film 1080p [Uncached]").isCached == false)
        #expect(ReleaseParser.parse("Film 1080p — not cached").isCached == false)
        #expect(ReleaseParser.parse("Film 1080p un-cached").isCached == false)
        #expect(ReleaseParser.parse("⌁  Film (2026) | ♛ Library").isCached == false)
        #expect(ReleaseParser.parse("Film 1080p [Cached]").isCached)
        #expect(ReleaseParser.parse("⤓  Film (2026) | ♛ Library").isCached)
    }

    /// The ordering the report was about: a cached 4K DV.HDR must beat a cached
    /// 720p, while a real Profile 5 still sinks beneath it.
    @Test("A DV.HDR 4K outranks a 720p; a bare-DV 4K still does not")
    func dvHDROutranksLowerResolutionButProfile5DoesNot() {
        func ranked(_ name: String, filename: String) -> RankedStream {
            let raw = StreamCore.Stream(
                url: "https://example.test/\(filename)",
                name: name,
                description: "⤓  Show | ♛ Library",
                behaviorHints: StreamBehaviorHints(filename: filename)
            )
            return RankedStream(stream: raw, attributes: ReleaseParser.parse(raw))
        }
        let sd = ranked("Hysteria 2024 S01 720p WEB-DL x264, 720p", filename: "Hysteria.S01.720p.WEB-DL.x264.mkv")
        let p8 = ranked("AIOStreams, DD+,4K,HDR,DV", filename: "Hysteria.S01E06.2160p.WEB-DL.DV.HDR.x265-FLUX.mkv")
        let p5 = ranked("AIOStreams, ATMOS,4K,HDR,DV", filename: "Silo.S01E08.2160p.WEBMux.DV.HEVC.Atmos-SGF.mkv")

        let order = StreamRanker.autoPlayOrder(of: [sd, p8, p5])
        #expect(order.first?.id == p8.id)
        #expect(order.last?.id == p5.id)
    }

    @Test("Container is read from the filename, not the opaque debrid URL")
    func containerFromFilename() throws {
        // Debrid playback links carry no extension; URL-based detection reports
        // nothing and every MKV would be misrouted to AVPlayer.
        let json = """
        {"url":"https://host/playback/aGVsbG8gd29ybGQ",
         "behaviorHints":{"filename":"Film.2021.1080p.WEB-DL.mkv"}}
        """
        let stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))

        #expect(URL(string: stream.url!)!.pathExtension.isEmpty)
        #expect(stream.behaviorHints?.containerExtension == "mkv")
    }

    @Test("Structural cached flag is honoured, not just the ⚡ text marker")
    func structuralCacheFlag() throws {
        let json = #"{"url":"https://h/v","behaviorHints":{"cached":true,"filename":"a.mkv"}}"#
        let stream = try JSONDecoder().decode(Stream.self, from: Data(json.utf8))
        #expect(ReleaseParser.parse(stream).isCached)
    }

    @Test("Dolby Vision is detected when bracketed or comma-delimited")
    func dolbyVisionDelimiters() {
        // Real releases write it "[DV HDR10Plus]" or ",DV," — space-padded matching
        // missed both.
        #expect(ReleaseParser.parse("Film [DV HDR10Plus][EAC3]").hdr.contains(.dolbyVision))
        #expect(ReleaseParser.parse("Film,4K,HDR,DV,ATMOS").hdr.contains(.dolbyVision))
        #expect(ReleaseParser.parse("Film 2160p DoVi Hybrid").hdr.contains(.dolbyVision))
        // And must not fire on unrelated words containing the letters.
        #expect(ReleaseParser.parse("Film advd 1080p").hdr.contains(.dolbyVision) == false)
    }

    @Test("Whole-word matching does not fire inside longer words")
    func wordBoundarySafety() {
        // "cam" must not match "camera"; "ts" must not match "hits".
        #expect(ReleaseParser.parse("Behind the camera 1080p WEB-DL").source == .webDL)
        #expect(ReleaseParser.parse("Greatest hits 1080p BluRay").source == .bluray)
    }

    @Test("Addon directories decode, and one bad entry drops itself")
    func addonCatalogDecoding() throws {
        let json = """
        { "addons": [
            { "transportUrl": "https://a.example/manifest.json", "transportName": "http",
              "flags": { "official": true },
              "manifest": { "id":"a","name":"Alpha","version":"1.0","types":["movie"],
                            "catalogs":[], "resources":["stream"],
                            "behaviorHints":{"configurationRequired":true} } },
            { "transportUrl": "https://broken.example/manifest.json",
              "manifest": { "name": "No id so this fails" } },
            { "transportUrl": "https://b.example/manifest.json",
              "manifest": { "id":"b","name":"Beta","version":"1.0","types":["series"],
                            "catalogs":[], "resources":["catalog","addon_catalog"] } }
        ]}
        """
        let response = try JSONDecoder().decode(AddonCatalogResponse.self, from: Data(json.utf8))

        #expect(response.addons.count == 2)

        let alpha = response.addons[0]
        #expect(alpha.name == "Alpha")
        #expect(alpha.flags?.official == true)
        // Aggregators need setup before they return anything.
        #expect(alpha.requiresConfiguration)
        #expect(alpha.capabilities == ["stream"])

        // A directory listing is not a capability worth showing the user.
        #expect(response.addons[1].capabilities == ["catalog"])
    }

    @Test("Manifests expose their published addon directories")
    func addonCatalogsOnManifest() throws {
        // Cinemeta advertises Official and Community lists this way.
        let json = """
        { "id":"com.linvo.cinemeta","name":"Cinemeta","version":"3.0.14",
          "types":["movie","series"], "catalogs":[],
          "resources":["catalog","meta","addon_catalog"],
          "addonCatalogs":[{"type":"all","id":"official","name":"Official"},
                           {"type":"all","id":"community","name":"Community"}] }
        """
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(json.utf8))

        #expect(manifest.addonCatalogs.count == 2)
        #expect(manifest.addonCatalogs.map(\.displayName) == ["Official", "Community"])
        #expect(manifest.supports(.addonCatalog))
    }

    @Test("Lenient decoding tolerates string-or-number fields")
    func lenientFields() throws {
        // Cinemeta sends imdbRating as a string; other addons send a number.
        let asString = #"{"id":"tt1","type":"movie","name":"A","imdbRating":"9.5","year":"1999"}"#
        let asNumber = #"{"id":"tt1","type":"movie","name":"A","imdbRating":9.5,"year":1999}"#

        let first = try JSONDecoder().decode(MetaPreview.self, from: Data(asString.utf8))
        let second = try JSONDecoder().decode(MetaPreview.self, from: Data(asNumber.utf8))

        #expect(first.imdbRating == "9.5")
        #expect(second.imdbRating == "9.5")
        #expect(first.year == "1999")
        #expect(second.year == "1999")
    }

    @Test("A malformed item drops itself, not the whole catalog")
    func lossyCatalogDecoding() throws {
        let json = """
        { "metas": [
            {"id":"tt1","type":"movie","name":"Good"},
            {"type":"movie","name":"Missing id"},
            {"id":"tt2","type":"movie","name":"Also good"}
        ]}
        """
        let response = try JSONDecoder().decode(CatalogResponse.self, from: Data(json.utf8))
        #expect(response.metas.count == 2)
        #expect(response.metas.map(\.name) == ["Good", "Also good"])
    }

    @Test("Series episodes group into ordered seasons with specials last")
    func seasonGrouping() throws {
        let json = """
        { "meta": { "id":"tt1","type":"series","name":"Show","videos":[
            {"id":"tt1:2:1","season":2,"episode":1,"name":"B"},
            {"id":"tt1:0:1","season":0,"episode":1,"name":"Special"},
            {"id":"tt1:1:2","season":1,"episode":2,"name":"A2"},
            {"id":"tt1:1:1","season":1,"episode":1,"name":"A1"}
        ]}}
        """
        let meta = try JSONDecoder().decode(MetaResponse.self, from: Data(json.utf8)).meta
        let seasons = meta.seasons

        #expect(seasons.map(\.number) == [1, 2, 0])
        #expect(seasons[0].episodes.map(\.displayName) == ["A1", "A2"])
        #expect(seasons[0].episodes.first?.episodeCode == "S01E01")
    }
}

@Suite("Filtered-out sources are counted")
struct ExcludedCountTests {

    private func stream(_ name: String) -> StreamCore.Stream {
        let json = #"{"name":"\#(name)","url":"https://example.com/a.mkv"}"#
        return try! JSONDecoder().decode(StreamCore.Stream.self, from: Data(json.utf8))
    }

    @Test("A CAM release is counted as excluded when low quality is hidden")
    func camIsExcluded() {
        // The reported case: the only source for a title was a CAM rip, and the
        // picker said "not currently available" rather than "you are hiding it".
        let ranked = StreamRanker.rank(
            [stream("Teenage.Sex.and.Death.at.Camp.Miasma.2026.1080p.CAM.x264-DKS.mkv")]
                .map { RankedStream(stream: $0, attributes: ReleaseParser.parse($0)) },
            preferences: RankingPreferences(excludeLowQualitySources: false)
        )

        #expect(ranked.count == 1)
        #expect(StreamRanker.excludedCount(
            of: ranked, preferences: RankingPreferences(excludeLowQualitySources: true)) == 1)
        #expect(StreamRanker.excludedCount(
            of: ranked, preferences: RankingPreferences(excludeLowQualitySources: false)) == 0)
    }
}
