import Testing
import Foundation
@testable import StreamCore

/// Preflight decisions for captured provider failures and valid media fixtures.
struct SourcePreflightTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - The placeholder that corrupted the library

    @Test func slateIsRejectedAndQuotesTheProvidersReason() {
        let slate = url(
            "https://slate.elfhosted.com/cache/a884f0d9/slate.mp4"
            + "?preset=default&w=1280&h=720&title=No+matching+file"
            + "&body=No+file+in+this+torrent+matched+the+requested+title+or+episode."
            + "+Try+a+different+source."
        )
        // 4.2 MB served where the addon advertised nothing at all — the case a
        // byte-count check cannot see, which is why the URL is checked too.
        let verdict = SourcePreflight.verdict(
            finalURL: slate,
            servedBytes: 4_375_418,
            advertisedBytes: nil
        )
        #expect(
            verdict == .placeholder(
                reason: "No matching file — No file in this torrent matched the requested "
                    + "title or episode. Try a different source."
            )
        )
    }

    @Test func slateWithoutAReasonStillFails() {
        let verdict = SourcePreflight.verdict(
            finalURL: url("https://slate.elfhosted.com/cache/x/slate.mp4"),
            servedBytes: 4_375_418,
            advertisedBytes: nil
        )
        guard case .placeholder = verdict else {
            Issue.record("a slate with no query string is still a slate")
            return
        }
    }

    /// Detection is by host, not filename. An earlier version also matched any
    /// file called `slate.mp4`, and it refused a working source served from a
    /// plain HTTP server that happened to use that name — caught the first time
    /// the change was exercised against a real file.
    @Test func slateIsDetectedByHostAndNotByFilename() {
        #expect(SourcePreflight.isProviderSlate(url("https://slate.elfhosted.com/cache/x/slate.mp4")))
        #expect(!SourcePreflight.isProviderSlate(url("http://192.168.0.239:8899/slate.mp4")))
        #expect(!SourcePreflight.isProviderSlate(url("https://store-026.wnam.tb-cdn.io/dld/abc")))
    }

    // MARK: - Healthy sources must not be refused

    /// The six real sources measured: served total matched `videoSize` exactly.
    @Test(arguments: [
        Int64(2_729_844_538),   // Alien: Earth S01E01
        Int64(9_026_108_933),   // It Ends
        Int64(9_662_991_160),   // Dolly
        Int64(10_396_015_481),  // Mutiny
        Int64(24_202_514_822),  // The Gorge
        Int64(59_773_593_032)   // Shawshank 4K remux
    ])
    func exactSizeMatchIsPlayable(size: Int64) {
        let verdict = SourcePreflight.verdict(
            finalURL: url("https://store-026.wnam.tb-cdn.io/dld/abc"),
            servedBytes: size,
            advertisedBytes: size
        )
        #expect(verdict == .playable)
    }

    /// The trap: `folderSize` is the whole torrent folder, and a healthy episode
    /// served 15% of it. If a caller ever passes it, that is a bug in the caller —
    /// this test exists so the ratio it would produce is on the record as one the
    /// check *does* reject, and nobody wires `folderSize` in by accident.
    @Test func fifteenPercentOfTheAdvertisedSizeIsRejected() {
        let verdict = SourcePreflight.verdict(
            finalURL: url("https://store-026.wnam.tb-cdn.io/dld/abc"),
            servedBytes: 2_729_844_538,
            advertisedBytes: 18_791_422_917
        )
        guard case .placeholder = verdict else {
            Issue.record("15% of the advertised size must not pass as the film")
            return
        }
    }

    @Test func aSourceSlightlySmallerThanAdvertisedIsStillPlayed() {
        // No real source was off by anything, but refusing to play a film over a
        // rounding difference is far worse than playing it.
        let verdict = SourcePreflight.verdict(
            finalURL: url("https://store-026.wnam.tb-cdn.io/dld/abc"),
            servedBytes: 9_000_000_000,
            advertisedBytes: 9_026_108_933
        )
        #expect(verdict == .playable)
    }

    @Test func unknownSizesArePlayed() {
        #expect(
            SourcePreflight.verdict(
                finalURL: url("https://store-026.wnam.tb-cdn.io/dld/abc"),
                servedBytes: nil,
                advertisedBytes: 9_026_108_933
            ) == .playable
        )
        #expect(
            SourcePreflight.verdict(
                finalURL: url("https://store-026.wnam.tb-cdn.io/dld/abc"),
                servedBytes: 9_026_108_933,
                advertisedBytes: nil
            ) == .playable
        )
    }

    // MARK: - Content-Range parsing

    @Test func totalIsReadFromContentRange() {
        #expect(SourcePreflight.totalBytes(fromContentRange: "bytes 0-0/4375418") == 4_375_418)
        #expect(SourcePreflight.totalBytes(fromContentRange: "bytes 0-0/*") == nil)
        #expect(SourcePreflight.totalBytes(fromContentRange: nil) == nil)
    }

    @Test("Small videos without an advertised size remain playable")
    func smallVideoIsPlayable() {
        #expect(SourcePreflight.verdict(finalURL: url("https://cdn.example.test/short.mp4"), servedBytes: 2048, advertisedBytes: nil) == .playable)
    }

    @Test(arguments: ["master.m3u8", "manifest.mpd"])
    func playlistIsNotComparedToMediaSize(path: String) {
        #expect(SourcePreflight.verdict(finalURL: url("https://cdn.example.test/" + path), servedBytes: 2048, advertisedBytes: 1_000_000_000) == .playable)
    }

    @Test func opaquePlaylistUsesMIMEType() {
        #expect(SourcePreflight.verdict(finalURL: url("https://cdn.example.test/token"), servedBytes: 2048, advertisedBytes: 1_000_000_000, contentType: "application/vnd.apple.mpegurl; charset=utf-8") == .playable)
        #expect(!SourcePreflight.isProviderSlate(url("https://slate.example.test/short.mp4")))
    }

    @Test("A large response with nothing advertised is playable")
    func largeUnadvertisedIsPlayable() {
        let url = URL(string: "https://cdn.example.test/file.mkv")!
        #expect(SourcePreflight.verdict(finalURL: url, servedBytes: 4_000_000_000, advertisedBytes: nil) == .playable)
    }

    /// A small file matching the advertised size is valid media.
    @Test("A small file matching its advertisement is playable")
    func advertisedSizeOutranksTheFloor() {
        let url = URL(string: "https://cdn.example.test/short.mp4")!
        #expect(SourcePreflight.verdict(finalURL: url, servedBytes: 20_000_000, advertisedBytes: 20_000_000) == .playable)
    }
}
