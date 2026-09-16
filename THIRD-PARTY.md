# Third-party components

The MIT license covers Stream’s original application code. It does not relicense dependencies, third-party artwork, film posters, or trademarks shown in screenshots.

SwiftVLC 1.1.0-beta.8 (commit `051b780bfe8bd56fb8e6a921dec8c2dae52c3126`) is an MIT-licensed wrapper. Its bundled VLC library and dependencies have separate licenses, including LGPL and GPL components.

The standard Xcode build downloads the upstream library, which includes GPL modules. It does not reproduce the filtered library in the published Mac beta. The combined binary is subject to the bundled libraries’ licenses as well as Stream’s MIT license.

The published Mac beta removes seven GPL-declared modules. Its license notices, corresponding library sources, patches, and relinking files are available on [itch.io](https://streammac.itch.io/stream). Consult those materials and the applicable licenses before redistributing either build. Rebuilding VLC and all its dependencies from source has not been verified.

The library packages include SwiftVLC’s MIT notice and VLC/dependency licenses. Keep those notices with redistributed builds. The optional sync worker’s npm dependencies retain their respective licenses.
