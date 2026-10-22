// swift-tools-version: 6.2
import PackageDescription
import Foundation
let env = ProcessInfo.processInfo.environment
let hudson: Package.Dependency = env["SPEECH_HUDSON_PATH"].map { .package(name: "hudson", path: $0) }
    ?? .package(url: "git@github.com:arach/hudson.git", revision: "d7647584f85ad2227ed2acc83a6ffcbef6f527df")
let package = Package(name: "Voice", platforms: [.macOS(.v26)],
    products: [.executable(name: "Voice", targets: ["SpeechAppRuntime"])],
    dependencies: [
        // Build with HUDSONKIT_WITH_VOICE=0, as tools/package.sh does, so Hudson leaves out Vox.
        hudson,
        // Kokoro (FluidAudio's KokoroAne) is left out for now: FluidAudio's NeMo text normalizer and
        // Phonon each ship a Rust staticlib defining rust_eh_personality, so the two cannot link
        // together. Hudson pulls FluidAudio with its default traits, so `traits: []` here is not
        // enough. Kokoro's sources compile out without FluidAudio (SpeechKokoro.isCompiledIn).
        // Phonon runs on the Neural Engine through Gradium's Core ML runtime. 0.4.0 is the newest
        // tag with a published release; the v0.4.1 tag points at a binary that was never uploaded.
        .package(url: "https://github.com/gradium-ai/xn-ptts.git", exact: "0.4.0"),
    ], targets: [
        .executableTarget(name: "SpeechAppRuntime", dependencies: [
            .product(name: "HudsonUI", package: "hudson"),
            .product(name: "HudsonUIAudio", package: "hudson"),
            .product(name: "ptts", package: "xn-ptts")], path: "Sources/Speech"),
        .testTarget(name: "SpeechTests", dependencies: [
            "SpeechAppRuntime"], swiftSettings: [.define("SPEECH_FORWARDING_TESTS")])
    ], swiftLanguageModes: [.v5])
