// swift-tools-version: 5.9
import PackageDescription

// The SwiftUI front-end only exists on Apple platforms. The manifest is
// evaluated on the build machine, so excluding that target on Linux lets
// `swift build` / `swift test` work there for the portable parts.
var products: [Product] = [
    .library(name: "MediaIdentifierCore", targets: ["MediaIdentifierCore"]),
    .library(name: "MediaIdentifierWeb", targets: ["MediaIdentifierWeb"]),
    .library(name: "MediaIdentifierTUI", targets: ["MediaIdentifierTUI"]),
    // How Mediafin runs on Linux: a binary that serves the web interface.
    .executable(name: "mediafin", targets: ["mediafin"]),
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
    ),
    // HTTPS server for the local web interface. Separate target so the Core
    // stays dependency-free: only this one pulls in SwiftNIO.
    .target(
        name: "MediaIdentifierWeb",
        dependencies: [
            "MediaIdentifierCore",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ],
        path: "Sources/MediaIdentifierWeb"
    ),
    .target(
        name: "CMediafinTerm",
        path: "Sources/CMediafinTerm"
    ),
    // The terminal interface. A third front-end over the same engine, kept
    // in its own target so its rendering can be tested without a screen.
    .target(
        name: "MediaIdentifierTUI",
        dependencies: ["MediaIdentifierCore", "CMediafinTerm"],
        path: "Sources/MediaIdentifierTUI"
    ),
    .testTarget(
        name: "MediaIdentifierTUITests",
        dependencies: ["MediaIdentifierTUI", "MediaIdentifierCore"],
        path: "Tests/MediaIdentifierTUITests"
    ),
    .executableTarget(
        name: "mediafin",
        dependencies: ["MediaIdentifierCore", "MediaIdentifierWeb",
                       "MediaIdentifierTUI"],
        path: "Sources/mediafin"
    ),
    .testTarget(
        name: "MediaIdentifierWebTests",
        dependencies: [
            "MediaIdentifierWeb",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ],
        path: "Tests/MediaIdentifierWebTests"
    ),
]

#if os(Linux)
// The native Linux front-end. GTK3 rather than GTK4: Mint, and every other
// desktop Mediafin is likely to meet, is GTK3 itself, so the window inherits
// the user's theme instead of fighting it.
//
// Linux-only in the manifest for the same reason the SwiftUI app is
// macOS-only: pkg-config would fail to find gtk+-3.0 on a Mac and break
// `swift build` for everyone there.
products.append(.executable(name: "mediafin-gtk", targets: ["mediafin-gtk"]))
targets.append(contentsOf: [
    .systemLibrary(
        name: "CGtk3",
        path: "Sources/CGtk3",
        pkgConfig: "gtk+-3.0",
        providers: [.apt(["libgtk-3-dev"])]
    ),
    // Accepting dropped files, in C. GTK hands its drag callback a
    // GdkDragContext and a GtkSelectionData, and how those arrive in Swift
    // depends on the module map and the GTK version. In C they are simply
    // whatever the installed GTK says they are.
    .target(
        name: "CMediafinGtk",
        dependencies: ["CGtk3"],
        path: "Sources/CMediafinGtk"
    ),
    .executableTarget(
        name: "mediafin-gtk",
        dependencies: ["MediaIdentifierCore", "CGtk3", "CMediafinGtk"],
        path: "Sources/MediaIdentifierGtk"
    ),
])
#endif

#if os(macOS)
products.append(.executable(name: "MediaIdentifierApp", targets: ["MediaIdentifierApp"]))
targets.append(
    // SwiftUI macOS front-end. Only builds on macOS.
    .executableTarget(
        name: "MediaIdentifierApp",
        dependencies: ["MediaIdentifierCore", "MediaIdentifierWeb"],
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
    dependencies: [
        // NIOSSL vendors its own BoringSSL, so TLS needs no system OpenSSL on
        // either macOS or Linux.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
    ],
    targets: targets
)
