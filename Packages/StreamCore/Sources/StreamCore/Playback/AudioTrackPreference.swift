import Foundation

/// Scores tracks already filtered to the preferred language. Preserve container
/// order on ties. A codec label alone does not identify the main soundtrack.
public enum AudioTrackPreference {
    public static func score(
        name: String, description: String? = nil, codec: String? = nil,
        preferCompatibleCodec: Bool = false
    ) -> Int {
        let name = name.lowercased()
        let details = [name, description?.lowercased() ?? ""].joined(separator: " ")
        var score = 0
        let descriptive = ["description", "descriptive", "described", "visually impaired", "visual impaired", "audio narration"]
        let tokens = details.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        if descriptive.contains(where: details.contains) || tokens.contains("ad") || details.contains("commentary") {
            score -= 1_000
        }

        // Retain the existing protection against mislabeled English dubs. Only
        // use explicit dub markers: a language name alone is not a defect.
        if name.contains("dub") || name.contains("mvo") || name.contains("vo,") { score -= 60 }

        if preferCompatibleCodec {
            let codec = (codec ?? "").lowercased()
            if ["mlp", "trhd", "true"].contains(where: codec.contains) { score -= 80 }
            else if ["dtsh", "dtse", "dtsx"].contains(where: codec.contains) { score -= 60 }
            else if codec.contains("dts") { score -= 30 }
            let fragile = ["truehd", "atmos", "dts-hd", "dtshd", "dts:x", "dtsx"]
            if fragile.contains(where: name.contains) { score -= 50 }
        }
        if name.contains("original") { score += 40 }
        return score
    }
}
