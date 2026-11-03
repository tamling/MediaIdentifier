// swift-tools-version: 5.9
import PackageDescription

// The SwiftUI front-end only exists on Apple platforms. The manifest is
// evaluated on the build machine, so excluding that target on Linux lets
// `swift build` / `swift test` work there for the portable parts.
var products: [Product] = [
    .library(name: "MediaIdentifierCore", targets: ["MediaIdentifierCore"])
]

var targets: [Target] = [
    // Pure-Foundation domain logic. No SwiftUI / AppKit imports so it stays
    // portable and unit-testable (including on Linux).
    .target(
        name: "MediaIdentifierCore",
        path: "Sources/MediaIdentifierCore"
    ),
    .testTarget(
        name: "MediaIdentifierCoreTests",
        dependencies: ["MediaIdentifierCore"],
        path: "Tests/MediaIdentifierCoreTests"
    )
]

#if os(macOS)
products.append(.executable(name: "MediaIdentifierApp", targets: ["MediaIdentifierApp"]))
targets.append(
    // SwiftUI macOS front-end. Only builds on macOS.
    .executableTarget(
        name: "MediaIdentifierApp",
        dependencies: ["MediaIdentifierCore"],
        path: "Sources/MediaIdentifierApp",
        // The asset catalog (app icon) is consumed by the Xcode/XcodeGen
        // build, not by SwiftPM; exclude it so `swift build`/`swift test`
        // don't warn about an unhandled resource.
        exclude: ["Assets.xcassets"]
    )
)
#endif

let package = Package(
    name: "MediaIdentifier",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    targets: targets
)
