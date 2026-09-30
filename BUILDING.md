# Build Stream

Stream shares SwiftUI code across macOS, iOS, and tvOS. The downloadable beta is for Mac. Get the current build from [GitHub Releases](https://github.com/chrishansen1984x-lang/stream/releases); the earlier download remains on [itch.io](https://streammac.itch.io/stream).

## Requirements

- Xcode 26 or later. The Mac build was tested with Xcode 27.0 (27A5194q).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), installed with `brew install xcodegen`.
- macOS 15 or later for the Mac app. The iOS and tvOS targets require version 18 or later.

## Build the Mac app

Clone this repository, then run these commands from its root:

```sh
xcodegen generate
xcodebuild -project Stream.xcodeproj -scheme StreamMac -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/stream-source-build CODE_SIGNING_ALLOWED=NO build
```

The app will be at `/tmp/stream-source-build/Build/Products/Debug/Stream.app`. This unsigned local build does not require a paid Apple Developer membership. Xcode downloads SwiftVLC 1.1.0-beta.8 and its binary dependencies during the build.

**This build uses upstream VLC, including GPL modules. It differs from the filtered library in the itch.io Mac beta.** Read [THIRD-PARTY.md](THIRD-PARTY.md) before distributing a build.

The Xcode project is generated from `project.yml`. Make project changes there, then run XcodeGen again.

## Tests

```sh
swift test --package-path Packages/StreamCore --scratch-path /tmp/stream-core-tests
```

The temporary build directory avoids a signing error caused by file metadata in some synced Documents folders. The updated source passed 213 core tests in 34 suites and a universal Mac Release build. iOS and tvOS builds are checked separately; playback on Intel hardware has not been tested.

For the optional sync worker:

```sh
cd Sync/worker
npm ci
npm test
```

Its nine tests passed locally. See the [worker guide](Sync/worker/README.md) for configuration and migration details. Building Stream does not deploy the worker.

## Personal configuration

Add your own addon manifest URLs in Settings. Stream installs Cinemeta for metadata on first launch; playback sources come from your configured addons. TMDB enrichment requires your own API key.

For iOS and tvOS device builds, choose your own bundle identifiers and signing team in Xcode. The development-team field is empty in this repository. iCloud sync requires a matching key-value-store entitlement and a supported signing profile; without them, data stays local.

The optional Screen integration is off by default. To use it, enable diagnostics to show the Screen settings, then enter your own HTTPS server URL and device token. No server address is bundled. For a personal sync worker, replace the placeholder KV namespace ID and configure your own secrets.

Addon URLs can contain credentials. Keep personal configurations, tokens, and logs out of source control.

## Project layout

- `Packages/StreamCore`: addon protocol, ranking, watch state, integrations, and sync.
- `Apps/Shared`: shared SwiftUI views and playback controls.
- `Apps/macOS`, `Apps/iOS`, `Apps/tvOS`: platform-specific app code and resources.
- `Sync/worker`: optional Cloudflare Worker for personal cross-device sync.

## Playback design

Source requests run in parallel. A settle window lets playback use early results without waiting for the slowest addon. Preflight resolves redirects and checks for known provider placeholder clips. Opening failures, playback errors, and stalls can trigger fallback to the next ranked source.
