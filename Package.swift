// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MediaIdentifier",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "MediaIdentifierCore", targets: ["MediaIdentifierCore"]),
        .executable(name: "MediaIdentifierApp", targets: ["MediaIdentifierApp"])
    ],
    targets: [
        // Pure-Foundation domain logic. No SwiftUI / AppKit imports so it stays
        // portable and unit-testable (including on Linux CI).
        .target(
            name: "MediaIdentifierCore",
            path: "Sources/MediaIdentifierCore"
        ),
        // SwiftUI macOS front-end. Only builds on macOS.
        .executableTarget(
            name: "MediaIdentifierApp",
            dependencies: ["MediaIdentifierCore"],
            path: "Sources/MediaIdentifierApp",
            // The asset catalog (app icon) is consumed by the Xcode/XcodeGen
            // build, not by SwiftPM; exclude it so `swift build`/`swift test`
            // don't warn about an unhandled resource.
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "MediaIdentifierCoreTests",
            dependencies: ["MediaIdentifierCore"],
            path: "Tests/MediaIdentifierCoreTests"
        )
    ]
)
