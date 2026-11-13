// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlyDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PlyDesktop", targets: ["PlyDesktop"])],
    targets: [
        .executableTarget(name: "PlyDesktop", resources: [.copy("Resources/ply-desktop-v1.png")]),
        .testTarget(name: "PlyDesktopTests", dependencies: ["PlyDesktop"]),
    ]
)
