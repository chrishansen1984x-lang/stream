import Foundation

/// Structured attributes extracted from an unstructured release name.
public struct StreamAttributes: Hashable, Sendable {
    public var resolution: Resolution?
    public var source: SourceKind?
    public var videoCodec: VideoCodec?
    public var hdr: Set<HDRFormat> = []
    public var audioCodec: AudioCodec?
    public var audioChannels: String?
    public var sizeBytes: Int64?
    public var seeders: Int?
    public var releaseGroup: String?
    public var languages: Set<String> = []
    public var isCached: Bool = false
    public var is3D: Bool = false

    /// Dolby Vision with no HDR10 base layer — almost certainly Profile 5.
    ///
    /// DV Profile 5 encodes colour in IPT-PQ-C2 rather than a standard space, and
    /// decoders without Dolby Vision support render it with a heavy magenta and
    /// green cast. Profiles 7 and 8 carry an HDR10 base layer that degrades
    /// gracefully, which is why the presence of HDR10 alongside DV is the tell.
    ///
    /// libVLC has no DV processing, so these are effectively unwatchable on the
    /// software decoder and are pushed down the ranking.
    public var isLikelyDolbyVisionProfile5: Bool {
        guard hdr.contains(.dolbyVision) else { return false }
        if hdr.contains(.hdr10) || hdr.contains(.hdr10Plus) { return false }
        // A bare "HDR" from an aggregator says nothing — AIOStreams appends
        // `,HDR,DV` to every Dolby Vision result, Profile 5 included, and Silo
        // S01E08 wore exactly that tag while rendering magenta. The same word in
        // the *release name* is a different claim: scene convention names a DV
        // release with an HDR10 base layer `DV.HDR` (Profile 8), and one without
        // as `DV` alone (Profile 5). That is the only tell the name carries, and
        // it is the one that separated the release that played from the one that
        // did not.
        return !releaseNameDeclaresHDR
    }

    /// Whether the release name itself — not the addon\'s appended tags — says HDR.
    /// See `isLikelyDolbyVisionProfile5`.
    public var releaseNameDeclaresHDR = false

    public var sizeLabel: String? {
        guard let sizeBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: sizeBytes)
    }

    public enum Resolution: Int, Codable, Comparable, Hashable, Sendable, CaseIterable {
        case sd = 480, hd = 720, fullHD = 1080, twoK = 1440, fourK = 2160

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .sd: "480p"
            case .hd: "720p"
            case .fullHD: "1080p"
            case .twoK: "1440p"
            case .fourK: "4K"
            }
        }
    }

    /// Ordered worst → best; drives default ranking.
    public enum SourceKind: Int, Comparable, Hashable, Sendable {
        case cam = 0, telesync, screener, hdtv, webRip, webDL, blurayRip, bluray, remux

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        public var label: String {
            switch self {
            case .cam: "CAM"
            case .telesync: "TS"
            case .screener: "SCR"
            case .hdtv: "HDTV"
            case .webRip: "WEBRip"
            case .webDL: "WEB-DL"
            case .blurayRip: "BRRip"
            case .bluray: "BluRay"
            case .remux: "REMUX"
            }
        }

        /// Sources that are near-unwatchable and excluded by default.
        public var isLowQuality: Bool { self <= .screener }
    }

    public enum VideoCodec: String, Hashable, Sendable {
        case h264 = "H.264", h265 = "H.265", av1 = "AV1", vp9 = "VP9", xvid = "Xvid"

        /// AV1 has no hardware decoder before A17 Pro / M3 — relevant for engine routing.
        public var isHardwareFriendly: Bool { self == .h264 || self == .h265 }
    }

    public enum HDRFormat: String, Hashable, Sendable {
        /// An unqualified "HDR" tag. Aggregators use it to mean "HDR of some kind",
        /// so it must stay distinct from `hdr10`: it is not evidence of an HDR10
        /// base layer, and treating it as such hides Dolby Vision Profile 5.
        case hdr = "HDR"
        case hdr10 = "HDR10", hdr10Plus = "HDR10+", dolbyVision = "DV", hlg = "HLG"
    }

    public enum AudioCodec: String, Hashable, Sendable {
        case aac = "AAC", ac3 = "AC3", eac3 = "E-AC3", dts = "DTS"
        case dtsHD = "DTS-HD", trueHD = "TrueHD", atmos = "Atmos"
        case flac = "FLAC", opus = "Opus", mp3 = "MP3"

        /// Formats AVPlayer cannot decode — forces the VLC/MPV path.
        /// This is the §4.1 routing decision made concrete.
        public var requiresSoftwareDecode: Bool {
            switch self {
            case .dts, .dtsHD, .trueHD, .flac: true
            default: false
            }
        }
    }
}

/// Turns addon stream titles into structured attributes.
///
/// Input is genuinely arbitrary text, e.g.
/// `"Torrentio\n1080p BluRay x265 HDR 10bit DTS-HD MA 7.1\n👤 42 💾 8.4 GB ⚙️ RARBG"`
public enum ReleaseParser {

    /// The release name is whatever precedes the first comma. AIOStreams writes
    /// `<filename>, TAG,TAG,…`, and a bare filename has no comma at all.
    private static func declaresHDR(inReleaseName raw: String) -> Bool {
        let name = raw.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
        let lower = " " + name.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
            .lowercased().replacingOccurrences(of: "-", with: " ") + " "
        // A base layer, not Dolby Vision itself — `DV` alone is the case being
        // separated out, so it must not count as a declaration.
        return !parseHDR(lower).isDisjoint(with: [.hdr, .hdr10, .hdr10Plus, .hlg])
    }

    public static func parse(_ stream: Stream) -> StreamAttributes {
        // Everything the addon told us, including its own label and filename.
        let haystack = [
            stream.name,
            stream.title,
            stream.description,
            stream.behaviorHints?.filename
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        var attributes = parse(haystack)
        if let filename = stream.behaviorHints?.filename, !filename.isEmpty {
            attributes.releaseNameDeclaresHDR = declaresHDR(inReleaseName: filename)
        }

        // Structured hints beat anything scraped out of the title text.
        if let videoSize = stream.behaviorHints?.videoSize, videoSize > 0 {
            attributes.sizeBytes = Int64(videoSize)
        }
        if stream.behaviorHints?.cached == true {
            attributes.isCached = true
        }
        // AIOStreams sets none of the markers `parse(_:)` looks for — no ⚡, no
        // `[TB+]`, and never `behaviorHints.cached`. Measured across 28 of its
        // streams, *not one* parsed as cached, so `preferCached` — the ranker's
        // strongest intrinsic signal at +5000 — never applied, and auto-play
        // would take an uncached torrent over a copy already sitting in the
        // user's debrid library whenever the uncached one scored better on
        // resolution. What it does send is `folderSize`, present on exactly the
        // results it labels "Library" and absent on every indexer result. Same
        // 28 streams: `folderSize` and its own ⤓ glyph agreed with each other
        // every time. Structured field first, per the rule above.
        if stream.behaviorHints?.folderSize != nil {
            attributes.isCached = true
        }
        return attributes
    }

    public static func parse(_ raw: String) -> StreamAttributes {
        var attributes = StreamAttributes()

        // `text` keeps hyphens, because the scene convention for a release group is a
        // trailing "-GROUP" and stripping them would erase it.
        let text = " " + raw.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression) + " "
        // `lower` additionally flattens hyphens so "web.dl", "web-dl", and "web dl"
        // all reduce to one spelling for keyword matching.
        let lower = text.lowercased().replacingOccurrences(of: "-", with: " ")
        // Size and channel counts are read from the untouched string: separator
        // normalization turns "8.4 GB" into "8 4 GB" and "7.1" into "7 1".
        let original = " " + raw.lowercased() + " "

        attributes.resolution = parseResolution(lower)
        attributes.source = parseSource(lower)
        attributes.videoCodec = parseVideoCodec(lower)
        attributes.hdr = parseHDR(lower)
        attributes.releaseNameDeclaresHDR = declaresHDR(inReleaseName: raw)
        attributes.audioCodec = parseAudioCodec(lower)
        attributes.audioChannels = parseChannels(original)
        attributes.sizeBytes = parseSize(original)
        attributes.seeders = parseSeeders(text)
        attributes.releaseGroup = parseGroup(text)
        attributes.languages = parseLanguages(lower)
        attributes.is3D = lower.contains(" 3d ")

        // Debrid addons flag already-cached results with these markers. `⤓` is
        // AIOStreams' — it marks a result already in the debrid library, against
        // `⌁` for one that would have to be fetched first.
        // Whole-word, and never its own opposite: `contains("cached")` was true
        // for "Uncached" and "not cached", which handed the +5000 cached bonus to
        // every row of any addon that spells availability out — turning the
        // ranker's strongest signal into a constant. `⌁` is AIOStreams' explicit
        // not-in-library glyph and outranks anything else in the text.
        let deniesCache = raw.contains("⌁")
            || lower.range(of: #"\b(?:un|non)\s?cached\b|\bnot\s+cached\b"#,
                           options: .regularExpression) != nil
        let claimsCache = lower.range(of: #"\bcached\b"#, options: .regularExpression) != nil
        attributes.isCached = !deniesCache && (
            raw.contains("⚡") || raw.contains("⤓")
            || raw.contains("[RD+]") || raw.contains("[AD+]")
            || raw.contains("[PM+]") || raw.contains("[TB+]")
            || claimsCache
        )

        return attributes
    }

    // MARK: - Field parsers

    private static func parseResolution(_ text: String) -> StreamAttributes.Resolution? {
        if text.contains("2160") || text.contains("4k") || text.contains("uhd") { return .fourK }
        if text.contains("1440") { return .twoK }
        if text.contains("1080") { return .fullHD }
        if text.contains("720") { return .hd }
        if text.contains("480") || text.contains("360") || text.contains("sd ") { return .sd }
        return nil
    }

    private static func parseSource(_ text: String) -> StreamAttributes.SourceKind? {
        // Order matters: "remux" and "bluray rip" both contain "blu".
        if text.contains("remux") { return .remux }
        if text.contains("brrip") || text.contains("bdrip") || text.contains("bluray rip") { return .blurayRip }
        if text.contains("bluray") || text.contains("blu ray") || text.contains("bdmv") { return .bluray }
        if text.contains("web dl") || text.contains("webdl") { return .webDL }
        if text.contains("webrip") || text.contains("web rip") || text.contains("web ") { return .webRip }
        if text.contains("hdtv") || text.contains("pdtv") { return .hdtv }
        if text.contains("screener") || text.contains("dvdscr") { return .screener }
        if text.contains("telesync") || containsWord(text, "ts") || containsWord(text, "tc") { return .telesync }
        if text.contains("camrip") || containsWord(text, "cam") || text.contains("hdcam") { return .cam }
        return nil
    }

    /// Whole-word match. Short tokens like "dv", "ts", and "cam" appear delimited by
    /// brackets, commas, and dots in real release names, so space padding is not
    /// enough — but a bare `contains` would match "cam" inside "camera".
    private static func containsWord(_ text: String, _ word: String) -> Bool {
        text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func parseVideoCodec(_ text: String) -> StreamAttributes.VideoCodec? {
        if text.contains("av1") { return .av1 }
        if text.contains("x265") || text.contains("h265") || text.contains("h 265") || text.contains("hevc") { return .h265 }
        if text.contains("x264") || text.contains("h264") || text.contains("h 264") || text.contains("avc") { return .h264 }
        if text.contains("vp9") { return .vp9 }
        if text.contains("xvid") || text.contains("divx") { return .xvid }
        return nil
    }

    private static func parseHDR(_ text: String) -> Set<StreamAttributes.HDRFormat> {
        var formats: Set<StreamAttributes.HDRFormat> = []
        // "DV" appears bracketed and comma-delimited in real releases
        // ("[DV HDR10Plus]", ",DV,"), which space-padded matching misses entirely.
        if text.contains("dolby vision") || text.contains("dovi") || containsWord(text, "dv") {
            formats.insert(.dolbyVision)
        }
        // "HDR10" must be matched explicitly. AIOStreams and other aggregators
        // decorate every stream with a generic tag list — "…,4K,HDR,DV,ATMOS,…" —
        // where "HDR" means only "this is HDR". Folding that into `.hdr10` made a
        // Dolby Vision Profile 5 release look like it carried an HDR10 base layer,
        // which is exactly the tell `isLikelyDolbyVisionProfile5` relies on.
        if text.contains("hdr10+") || text.contains("hdr10plus") { formats.insert(.hdr10Plus) }
        else if text.contains("hdr10") || text.contains("hdr 10") { formats.insert(.hdr10) }
        else if text.contains("hdr") { formats.insert(.hdr) }
        if text.contains("hlg") { formats.insert(.hlg) }
        return formats
    }

    private static func parseAudioCodec(_ text: String) -> StreamAttributes.AudioCodec? {
        if text.contains("atmos") { return .atmos }
        if text.contains("truehd") || text.contains("true hd") { return .trueHD }
        if text.contains("dts hd") || text.contains("dtshd") || text.contains("dts x") { return .dtsHD }
        if text.contains("dts") { return .dts }
        if text.contains("eac3") || text.contains("e ac3") || text.contains("ddp") || text.contains("dd+") { return .eac3 }
        if text.contains("ac3") || text.contains(" dd ") { return .ac3 }
        if text.contains("flac") { return .flac }
        if text.contains("opus") { return .opus }
        if text.contains("aac") { return .aac }
        if text.contains("mp3") { return .mp3 }
        return nil
    }

    /// Surround-sound layout, e.g. "7.1". Both halves are captured so the label
    /// survives intact rather than collapsing to just the channel count.
    private static func parseChannels(_ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\b([578])[\.\s]([01])\b"#),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let major = Range(match.range(at: 1), in: text),
              let minor = Range(match.range(at: 2), in: text)
        else { return nil }
        return "\(text[major]).\(text[minor])"
    }

    private static func parseSize(_ text: String) -> Int64? {
        guard let match = firstMatch(in: text, pattern: #"(\d+(?:[.,]\d+)?)\s*(gb|gib|mb|mib)"#, group: 0) else {
            return nil
        }
        let normalized = match.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized.filter { $0.isNumber || $0 == "." }) else { return nil }
        let isGigabytes = normalized.contains("g")
        return Int64(value * (isGigabytes ? 1_073_741_824 : 1_048_576))
    }

    private static func parseSeeders(_ text: String) -> Int? {
        // Torrentio-style "👤 42", or an explicit "42 seeders".
        for pattern in [#"👤\s*(\d+)"#, #"(\d+)\s*seeders?"#, #"seeders?:?\s*(\d+)"#] {
            if let value = firstMatch(in: text, pattern: pattern), let count = Int(value) {
                return count
            }
        }
        return nil
    }

    private static func parseGroup(_ text: String) -> String? {
        if let value = firstMatch(in: text, pattern: #"⚙️\s*([A-Za-z0-9._-]+)"#) { return value }
        // Trailing "-GROUP" is the scene convention.
        if let value = firstMatch(in: text, pattern: #"-([A-Za-z0-9]{2,20})\s*$"#) { return value }
        return nil
    }

    private static func parseLanguages(_ text: String) -> Set<String> {
        let known = [
            "english": "en", "french": "fr", "spanish": "es", "german": "de",
            "italian": "it", "portuguese": "pt", "russian": "ru", "japanese": "ja",
            "korean": "ko", "hindi": "hi", "chinese": "zh", "dual audio": "multi",
            "multi": "multi"
        ]
        return Set(known.compactMap { text.contains($0.key) ? $0.value : nil })
    }

    // MARK: - Regex helper

    private static func firstMatch(in text: String, pattern: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              group < match.numberOfRanges,
              let matchRange = Range(match.range(at: group), in: text)
        else { return nil }
        return String(text[matchRange])
    }
}
