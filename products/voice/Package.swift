// swift-tools-version: 6.2
import PackageDescription
import Foundation
let env = ProcessInfo.processInfo.environment
let hudson: Package.Dependency = env["SPEECH_HUDSON_PATH"].map { .package(name: "hudson", path: $0) }
    ?? .package(url: "git@github.com:arach/hudson.git", branch: "main")
let package = Package(name: "Voice", platforms: [.macOS(.v26)],
    products: [.executable(name: "Voice", targets: ["SpeechAppRuntime"])],
    dependencies: [
        // Build with HUDSONKIT_WITH_VOICE=0, as tools/package.sh does, so Hudson leaves out Vox.
        hudson,
        // Kokoro runs on the Neural Engine through KokoroAne. Pinned explicitly; keep aligned with Talkie.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ], targets: [
        .executableTarget(name: "SpeechAppRuntime", dependencies: [
            .product(name: "HudsonUI", package: "hudson"),
            .product(name: "HudsonUIAudio", package: "hudson"),
            .product(name: "FluidAudio", package: "FluidAudio")], path: "Sources/Speech"),
        .testTarget(name: "SpeechTests", dependencies: [
            "SpeechAppRuntime",
            .product(name: "FluidAudio", package: "FluidAudio")], swiftSettings: [.define("SPEECH_FORWARDING_TESTS")])
    ], swiftLanguageModes: [.v5])
