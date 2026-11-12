// swift-tools-version: 5.9
import PackageDescription

// One engine, one interface.
//
// There used to be four front-ends over this engine: a GTK window, a terminal
// interface, a local web interface and a SwiftUI app for macOS. Keeping them in
// step was most of the work and none of the value — every setting had to be
// built three times, and a release could be green while the one front-end
// anybody ran was broken. The three that nobody ran are gone, along with
// SwiftNIO, which only the web server needed.
//
// What is left: MediaIdentifierCore, which does the work and carries the
// tests; mediafin-gtk, the window; and mediafin, a headless runner whose only
// job is to hold the engine so scheduled runs happen while the window is shut.
var products: [Product] = [
    .library(name: "MediaIdentifierCore", targets: ["MediaIdentifierCore"]),
    .executable(name: "mediafin", targets: ["mediafin"]),
]

var targets: [Target] = [
    // Pure-Foundation domain logic: no interface imports of any kind, so it
    // stays portable and testable without a screen.
    .target(
        name: "MediaIdentifierCore",
        path: "Sources/MediaIdentifierCore"
    ),
    .testTarget(
        name: "MediaIdentifierCoreTests",
        dependencies: ["MediaIdentifierCore"],
        path: "Tests/MediaIdentifierCoreTests"
    ),
    // Draws nothing. It exists because the schedule has to fire when the
    // window is closed, and the timer that fires it lives inside the engine —
    // so some process has to be holding one.
    .executableTarget(
        name: "mediafin",
        dependencies: ["MediaIdentifierCore"],
        path: "Sources/mediafin"
    ),
]

#if os(Linux)
// The native Linux front-end, and now the only one. GTK3 rather than GTK4:
// Mint, and every other desktop Mediafin is likely to meet, is GTK3 itself, so
// the window inherits the user's theme instead of fighting it.
//
// Linux-only in the manifest because pkg-config would fail to find gtk+-3.0 on
// a Mac and break `swift build` for everyone there.
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

let package = Package(
    name: "MediaIdentifier",
    platforms: [
        .macOS(.v13)
    ],
    products: products,
    // None. The engine was always dependency-free; SwiftNIO came in for the
    // web server alone and left with it.
    dependencies: [],
    targets: targets
)
