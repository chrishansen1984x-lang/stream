import Testing
@testable import StreamCore

struct AudioTrackPreferenceTests {
    @Test func macKeepsFirstMainTrackInsteadOfFavoringDolby() {
        let main = AudioTrackPreference.score(name: "DTS-HD MA 5.1 - [English]", codec: "dtsh")
        let unlabeledDescription = AudioTrackPreference.score(name: "DD 5.1 - [English]", codec: "a52")
        // The caller preserves the first track on ties, matching the reported file.
        #expect(main == unlabeledDescription)
    }
    @Test(arguments: ["Audio Description", "Descriptive Audio", "English AD", "Visually impaired", "Director commentary"])
    func alternateAudioLosesToMainOnEveryPlatform(label: String) {
        for compatibility in [false, true] {
            let main = AudioTrackPreference.score(name: "DTS-HD MA 5.1", codec: "dtsh", preferCompatibleCodec: compatibility)
            let alternate = AudioTrackPreference.score(name: "DD 5.1", description: label, codec: "a52", preferCompatibleCodec: compatibility)
            #expect(main > alternate)
        }
    }
    @Test func adDetectionUsesWholeWords() {
        #expect(AudioTrackPreference.score(name: "Adventure original") == 40)
    }
    @Test func mobileCompatibilityWorkaroundRemainsForUnlabeledTracks() {
        #expect(AudioTrackPreference.score(name: "TrueHD", codec: "mlp", preferCompatibleCodec: true) < AudioTrackPreference.score(name: "DD 5.1", preferCompatibleCodec: true))
    }
    @Test func normalForeignLanguageIsNotPenalized() {
        #expect(AudioTrackPreference.score(name: "French") == AudioTrackPreference.score(name: "English"))
    }
}
