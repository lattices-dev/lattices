import XCTest
@testable import Lattices

final class LatticesCLIRootResolverTests: XCTestCase {
    private var scratch: URL!
    private let version = "0.15.3"

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LatticesCLIRootResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        scratch = scratch.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testPackagedBundleFindsRootThreeParentsUp() throws {
        let installed = try package("installed/node_modules/@lattices/lattices")
        let result = resolve(bundle: installed.appendingPathComponent("apps/mac/Lattices.app"))

        XCTAssertEqual(result, .init(root: installed.path, source: .bundle))
    }

    func testApplicationsSymlinkResolvesToOwningInstalledPackage() throws {
        let installed = try package("installed/node_modules/@lattices/lattices")
        _ = try package("home/dev/lattices", source: true)
        let appLink = try symlink("Applications/Lattices.app", to: installed.appendingPathComponent("apps/mac/Lattices.app"))

        XCTAssertEqual(resolve(bundle: appLink), .init(root: installed.path, source: .bundle))
    }

    func testStandaloneFinderLaunchFindsMatchingBunPackageWithoutShellPath() throws {
        let installed = try package("home/.bun/install/global/node_modules/@lattices/lattices")
        _ = try package("home/dev/lattices", source: true)
        let paths = LatticesCLIRootResolver.installedSearchPaths(
            home: scratch.appendingPathComponent("home"), environment: [:]
        )

        XCTAssertEqual(resolve(paths: paths), .init(root: installed.path, source: .installed))
    }

    func testStandaloneAppDoesNotAdoptConventionalDevCheckout() throws {
        _ = try package("home/dev/lattices", source: true)

        XCTAssertNil(resolve())
    }

    func testInstalledBinSymlinkChainFindsCanonicalPackage() throws {
        let installed = try package("custom-prefix/lib/node_modules/@lattices/lattices")
        let first = try symlink("custom-prefix/bin/lattices", to: installed.appendingPathComponent("bin/lattices"))
        let second = try symlink("home/bin/lats", to: first)

        XCTAssertEqual(
            resolve(paths: .init(executables: [second])),
            .init(root: installed.path, source: .installed)
        )
    }

    func testGloballyLinkedSourceIsRejectedEvenWithMatchingVersion() throws {
        let checkout = try package("home/dev/lattices", source: true)
        let linkedPackage = try symlink("home/.bun/install/global/node_modules/@lattices/lattices", to: checkout)
        let linkedBin = try symlink("home/.bun/bin/lattices", to: linkedPackage.appendingPathComponent("bin/lattices"))

        XCTAssertNil(resolve(paths: .init(executables: [linkedBin], packageRoots: [linkedPackage])))
    }

    func testSourceArchiveWithoutGitIsRejectedAsInstalledPackage() throws {
        let checkout = try package("source-archive")
        try Data().write(to: checkout.appendingPathComponent("apps/mac/Package.swift"))

        XCTAssertNil(resolve(paths: .init(packageRoots: [checkout])))
    }

    func testMatchingReleaseWinsAfterOldOrLinkedCliCandidates() throws {
        let old = try package("old", version: "0.14.0")
        let checkout = try package("home/dev/lattices", source: true)
        let installed = try package("current")

        XCTAssertEqual(
            resolve(paths: .init(packageRoots: [old, checkout, installed])),
            .init(root: installed.path, source: .installed)
        )
    }

    func testMismatchedInstalledOrBundlePackageIsNotSelected() throws {
        let old = try package("old", version: "0.14.0")

        XCTAssertNil(resolve(paths: .init(packageRoots: [old])))
        XCTAssertNil(resolve(bundle: old.appendingPathComponent("apps/mac/Lattices.app")))
    }

    func testDeliberateSourceBundleUsesItsOwnCheckout() throws {
        let checkout = try package("worktree", version: "0.16.0", source: true)

        XCTAssertEqual(
            resolve(bundle: checkout.appendingPathComponent("apps/mac/Lattices.app")),
            .init(root: checkout.path, source: .bundle)
        )
    }

    func testExplicitRootKeepsDeliberateSourceOverrideAndCanonicalizesIt() throws {
        let checkout = try package("worktree", version: "0.16.0", source: true)
        let alias = try symlink("source-link", to: checkout)
        let installed = try package("installed")

        XCTAssertEqual(
            resolve(
                arguments: ["Lattices", "--lattices-cli-root", alias.path],
                paths: .init(packageRoots: [installed])
            ),
            .init(root: checkout.path, source: .explicit)
        )
    }

    func testUnrelatedAncestorPackageDoesNotOwnStandaloneBundle() throws {
        let checkout = try package("worktree", source: true)

        XCTAssertNil(resolve(bundle: checkout.appendingPathComponent("Applications/Lattices.app")))
    }

    func testMissingOrWrongPackageIdentityIsRejected() throws {
        let wrong = try package("other", name: "unrelated-tool")
        let missingHelper = try package("broken")
        try FileManager.default.removeItem(at: missingHelper.appendingPathComponent("bin/lattices-app.ts"))

        XCTAssertNil(resolve(paths: .init(packageRoots: [wrong, missingHelper])))
    }

    func testSupportedLegacyPackageIdentityStillResolves() throws {
        let legacy = try package("legacy", name: "@arach/lattices")

        XCTAssertEqual(resolve(paths: .init(packageRoots: [legacy])), .init(root: legacy.path, source: .installed))
    }

    func testSearchPathsIgnoreRelativeEntriesAndSupportConfiguredPrefixes() {
        let home = scratch.appendingPathComponent("home")
        let paths = LatticesCLIRootResolver.installedSearchPaths(home: home, environment: [
            "PATH": ":.:relative:/custom/bin",
            "BUN_INSTALL": "/custom/bun",
            "npm_config_prefix": "/custom/npm",
            "PNPM_HOME": "/custom/pnpm",
        ])

        XCTAssertEqual(paths.executables.first?.path, "/custom/bin/lattices")
        XCTAssertTrue(paths.executables.contains { $0.path == "/custom/bun/bin/lattices" })
        XCTAssertTrue(paths.packageRoots.contains { $0.path == "/custom/npm/lib/node_modules/@lattices/lattices" })
        XCTAssertTrue(paths.packageRoots.contains { $0.path == "/custom/pnpm/global/5/node_modules/@lattices/lattices" })
        XCTAssertFalse(paths.executables.contains { $0.path.contains("relative") || $0.path.contains("/dev/lattices") })
    }

    private func resolve(
        arguments: [String] = ["Lattices"],
        bundle: URL? = nil,
        paths: LatticesCLIRootResolver.SearchPaths = .init()
    ) -> LatticesCLIRootResolver.Resolution? {
        LatticesCLIRootResolver.resolve(
            arguments: arguments,
            bundleURL: bundle ?? scratch.appendingPathComponent("Applications/Lattices.app"),
            appVersion: version,
            searchPaths: paths
        )
    }

    private func package(
        _ relativePath: String,
        version: String = "0.15.3",
        name: String = "@lattices/lattices",
        source: Bool = false
    ) throws -> URL {
        let root = scratch.appendingPathComponent(relativePath, isDirectory: true)
        for path in ["bin", "apps/mac/Lattices.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["bin/lattices", "bin/lattices.ts", "bin/lattices-app.ts"] {
            let script = root.appendingPathComponent(path)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        try JSONSerialization.data(withJSONObject: ["name": name, "version": version])
            .write(to: root.appendingPathComponent("package.json"))
        if source { try Data("gitdir: /worktree-metadata\n".utf8).write(to: root.appendingPathComponent(".git")) }
        return root
    }

    private func symlink(_ relativePath: String, to target: URL) throws -> URL {
        let link = scratch.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }
}
