// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StreamCore",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "StreamCore", targets: ["StreamCore"])
    ],
    targets: [
        .target(
            name: "StreamCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "StreamCoreTests",
            dependencies: ["StreamCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
