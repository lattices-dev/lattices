// swift-tools-version: 6.0
import PackageDescription

// A clean Lattices checkout must resolve the same Hudson contract every time.
// Keep the revision in this manifest rather than following Hudson's moving
// `main`: Hudson can raise its deployment floor for products Blink does not use.
// Local Hudson development remains available as an explicit path override.
let hudsonSource = Context.environment["BLINK_HUDSON_SOURCE"] ?? "git"
let hudsonDependency: Package.Dependency

switch hudsonSource {
case "git":
    let hudsonRevision = Context.environment["BLINK_HUDSON_REVISION"]
        ?? "79ca548b2b30335a3c37fb031a753481dedaaf79"
    hudsonDependency = .package(
        url: "git@github.com:arach/hudson.git",
        revision: hudsonRevision
    )
case "path":
    let hudsonPath = Context.environment["BLINK_HUDSON_PATH"] ?? "../../../hudson"
    hudsonDependency = .package(path: hudsonPath)
default:
    fatalError("BLINK_HUDSON_SOURCE must be either 'git' or 'path'")
}

let package = Package(
    name: "Canvas",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .executable(name: "CanvasApp", targets: ["BlinkApp"]),
        .executable(name: "canvas", targets: ["BlinkCLI"]),
        // Build aliases for existing scripts; modules and storage keep their identity.
        .executable(name: "BlinkApp", targets: ["BlinkApp"]),
        .executable(name: "blink", targets: ["BlinkCLI"]),
        .library(name: "BlinkCore", targets: ["BlinkCore"]),
        .library(name: "BlinkPeer", targets: ["BlinkPeer"]),
    ],
    dependencies: [
        hudsonDependency,
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "BlinkApp",
            dependencies: [
                "BlinkCore",
                "BlinkPeer",
                .product(name: "HudsonUI", package: "hudson"),
                .product(name: "HudsonShell", package: "hudson"),
                .product(name: "HudsonObservability", package: "hudson"),
            ],
            path: "Sources/BlinkApp"
        ),
        .executableTarget(
            name: "BlinkCLI",
            dependencies: [
                "BlinkCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BlinkCLI"
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "BlinkCore",
            dependencies: ["CSQLite"],
            path: "Sources/BlinkCore"
        ),
        .target(
            name: "BlinkPeer",
            dependencies: ["BlinkCore"],
            path: "Sources/BlinkPeer"
        ),
        .testTarget(
            name: "BlinkCoreTests",
            dependencies: ["BlinkCore"],
            path: "Tests/BlinkCoreTests"
        ),
        .testTarget(
            name: "BlinkPeerTests",
            dependencies: ["BlinkCore", "BlinkPeer"],
            path: "Tests/BlinkPeerTests"
        ),
    ]
)
