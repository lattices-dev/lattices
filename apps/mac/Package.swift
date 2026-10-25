// swift-tools-version: 6.2
import PackageDescription
import Foundation

// HudsonKit source: a local sibling checkout for fast local iteration, or the
// git dependency for CI/release builds that have no sibling repo. Set
// LATTICES_HUDSON_SOURCE=git in CI (and rewrite git@ → token HTTPS for the
// private repo). LATTICES_HUDSON_PATH points the path build at another checkout
// (a worktree); its directory must be named `hudson`. HudsonVoice requires HUDSONKIT_WITH_VOICE=1 at build time.
let hudsonSource = Context.environment["LATTICES_HUDSON_SOURCE"] ?? "path"
let hudsonDependency: Package.Dependency = hudsonSource == "git"
    ? .package(url: "git@github.com:arach/hudson.git", revision: "57e71397163a097c8507a008426bfb5da6fed47b")
    : .package(path: Context.environment["LATTICES_HUDSON_PATH"] ?? "../../../hudson")

let voiceEnabled = Context.environment["HUDSONKIT_WITH_VOICE"] == "1"

// The bundle tier: LATTICES_BUNDLE=1 compiles Sources/Bundle and defines
// LATTICES_BUNDLE. Without it the free build excludes that directory whole.
let bundleEnabled = Context.environment["LATTICES_BUNDLE"] == "1"

var latticesDefines: [SwiftSetting] = []
if voiceEnabled { latticesDefines.append(.define("LATTICES_VOICE")) }
if bundleEnabled { latticesDefines.append(.define("LATTICES_BUNDLE")) }

// Vox is already a HudsonVoice transitive dep; Lattices also links VoxService
// directly so it can host the live-session runtime in-process on boot. Local
// Hudson builds use the sibling Vox checkout as well; release builds select
// both git dependencies with LATTICES_HUDSON_SOURCE=git.
let voxHasGitOverride = ["HUDSON_VOX_GIT_URL", "HUDSON_VOX_GIT_REVISION", "HUDSON_VOX_GIT_BRANCH", "HUDSON_VOX_PACKAGE"].contains {
    !(Context.environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
}
let voxSource = Context.environment["LATTICES_VOX_SOURCE"] ?? Context.environment["HUDSON_VOX_PATH"]
    ?? (hudsonSource == "git" || voxHasGitOverride ? nil : "../../../vox")
let voxGitURL = Context.environment["HUDSON_VOX_GIT_URL"] ?? "https://github.com/arach/vox.git"
let voxPackageIdentity = Context.environment["HUDSON_VOX_PACKAGE"]
    ?? URL(fileURLWithPath: voxSource ?? voxGitURL).deletingPathExtension().lastPathComponent.lowercased()
let voxDependency: Package.Dependency? = voiceEnabled ? {
    if let voxSource { return .package(path: voxSource) }
    if let revision = Context.environment["HUDSON_VOX_GIT_REVISION"] {
        return .package(url: voxGitURL, revision: revision)
    }
    if let branch = Context.environment["HUDSON_VOX_GIT_BRANCH"] {
        return .package(url: voxGitURL, branch: branch)
    }
    if Context.environment["HUDSON_VOX_GIT_URL"] != nil {
        return .package(url: voxGitURL, branch: "main")
    }
    return .package(url: voxGitURL, revision: "e1895152859779f4427296e8c5a8d0e38a16f123")
}() : nil

var latticesDependencies: [Target.Dependency] = [
    .product(name: "DeckKit", package: "swift"),
    .product(name: "LatticesLayoutKit", package: "swift"),
    .product(name: "LatticesWorkspaceCore", package: "swift"),
    .product(name: "HudsonObservability", package: "hudson"),
    .product(name: "HudsonUI", package: "hudson"),
    .product(name: "HudsonAI", package: "hudson"),
    .product(name: "HudsonShell", package: "hudson"),
]
if voiceEnabled {
    latticesDependencies.append(.product(name: "HudsonVoice", package: "hudson"))
    latticesDependencies.append(.product(name: "VoxService", package: voxPackageIdentity))
}

var packageDependencies: [Package.Dependency] = [
    .package(path: "../../swift"),
    hudsonDependency,
]
if let voxDependency {
    packageDependencies.append(voxDependency)
}

var testDependencies: [Target.Dependency] = ["Lattices"]
if voiceEnabled {
    // Lets optional live voice probes import HudsonVoice under LATTICES_VOICE.
    testDependencies.append(.product(name: "HudsonVoice", package: "hudson"))
}

let package = Package(
    name: "Lattices",
    platforms: [.macOS(.v26)],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "Lattices",
            dependencies: latticesDependencies,
            path: "Sources",
            exclude: bundleEnabled ? [] : ["Bundle"],
            resources: [
                .copy("../Resources/tap.wav"),
                .copy("../Resources/Pets"),
                .copy("../Resources/DeckBuilder"),
                .copy("../Resources/Editor"),
            ],
            swiftSettings: latticesDefines
        ),
        .testTarget(
            name: "LatticesTests",
            dependencies: testDependencies,
            path: "Tests",
            exclude: bundleEnabled ? [] : ["Bundle"],
            swiftSettings: latticesDefines
        )
    ],
    // Stay in Swift 5 language mode: adopt macOS 26 / the 6.2 toolchain without
    // forcing a Swift 6 strict-concurrency migration across the existing app.
    swiftLanguageModes: [.v5]
)
