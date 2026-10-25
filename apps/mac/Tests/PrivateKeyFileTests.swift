import Darwin
import Foundation
import XCTest
@testable import Lattices

final class PrivateKeyFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lattices-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func mode(_ url: URL) -> mode_t {
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        return info.st_mode & 0o777
    }

    func testWriteCreatesAnOwnerOnlyFileAndLeavesNoTemporary() throws {
        let url = directory.appendingPathComponent("bridge.key")
        let previous = umask(0)
        defer { umask(previous) }
        XCTAssertTrue(PrivateKeyFile.write(Data([1, 2, 3]), to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data([1, 2, 3]))
        XCTAssertEqual(mode(url), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["bridge.key"])
    }

    func testWriteReplacesALooseFileWithAnOwnerOnlyOne() throws {
        let url = directory.appendingPathComponent("bridge.key")
        FileManager.default.createFile(atPath: url.path, contents: Data([9]), attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(PrivateKeyFile.write(Data([4, 5]), to: url))
        XCTAssertEqual(try Data(contentsOf: url), Data([4, 5]))
        XCTAssertEqual(mode(url), 0o600)
    }

    func testTightenRemovesGroupAndOtherAccessOnly() throws {
        let loose = directory.appendingPathComponent("device-key")
        FileManager.default.createFile(atPath: loose.path, contents: Data([7]), attributes: [.posixPermissions: 0o644])
        XCTAssertTrue(PrivateKeyFile.tighten(loose))
        XCTAssertEqual(mode(loose), 0o600)
        XCTAssertEqual(try Data(contentsOf: loose), Data([7]))

        let strict = directory.appendingPathComponent("strict")
        FileManager.default.createFile(atPath: strict.path, contents: Data([1]), attributes: [.posixPermissions: 0o400])
        XCTAssertTrue(PrivateKeyFile.tighten(strict))
        XCTAssertEqual(mode(strict), 0o400)

        XCTAssertFalse(PrivateKeyFile.tighten(directory.appendingPathComponent("missing")))
    }

    func testTightenDoesNotFollowSymlinks() throws {
        let target = directory.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: Data([1]), attributes: [.posixPermissions: 0o644])
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(PrivateKeyFile.tighten(link))
        XCTAssertEqual(mode(target), 0o644)
    }
}
