// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeckKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "DeckKit", targets: ["DeckKit"]),
        .library(name: "LatticesTerminalKit", targets: ["LatticesTerminalKit"]),
        .library(name: "LatticesLayoutKit", targets: ["LatticesLayoutKit"]),
        .library(name: "LatticesWorkspaceCore", targets: ["LatticesWorkspaceCore"])
    ],
    targets: [
        .target(
            name: "DeckKit",
            resources: [
                .copy("Resources/deck-tactile-catalog.json")
            ]
        ),
        .target(name: "LatticesTerminalKit"),
        .target(name: "LatticesLayoutKit"),
        .target(name: "LatticesWorkspaceCore"),
        .testTarget(
            name: "DeckKitTests",
            dependencies: ["DeckKit"]
        ),
        .testTarget(
            name: "LatticesTerminalKitTests",
            dependencies: ["LatticesTerminalKit"]
        ),
        .testTarget(
            name: "LatticesLayoutKitTests",
            dependencies: ["LatticesLayoutKit"]
        ),
        .testTarget(
            name: "LatticesWorkspaceCoreTests",
            dependencies: ["LatticesWorkspaceCore"]
        )
    ]
)
