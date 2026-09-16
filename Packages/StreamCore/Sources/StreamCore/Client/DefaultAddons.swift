import Foundation

/// Addons offered on first run.
///
/// Deliberately metadata-only. Per `AUDIT.md` §4.6, the compliance pattern that
/// passes App Review is to ship **zero** preloaded content/stream addons — the user
/// installs those themselves by URL. Cinemeta is the official Stremio catalog addon
/// and serves nothing but titles, artwork, and episode lists.
public enum DefaultAddons {
    public static let cinemeta = "https://v3-cinemeta.strem.io/manifest.json"

    /// Installed automatically on first launch so the app is not an empty shell.
    public static let firstRun: [String] = [cinemeta]
}
