import XCTest
@testable import Lattices

final class RemoteAppDefinitionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("remote-apps-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSlugJoinsAppAndHost() {
        XCTAssertEqual(RemoteAppDefinition.slug(app: "Spotify", host: "archie"), "spotify-archie")
        XCTAssertEqual(RemoteAppDefinition.slug(app: "Google Chrome", host: "arts-mini"), "google-chrome-arts-mini")
    }

    func testSaveListRemoveRoundTrip() throws {
        let spotify = RemoteAppDefinition(id: "spotify-archie", host: "archie", app: "Spotify", name: "Spotify", width: 1300, height: 876)
        try RemoteAppDefinitions.save(spotify, in: directory)
        XCTAssertEqual(RemoteAppDefinitions.all(in: directory), [spotify])
        XCTAssertEqual(RemoteAppDefinitions.get("spotify-archie", in: directory), spotify)
        XCTAssertTrue(RemoteAppDefinitions.remove("spotify-archie", in: directory))
        XCTAssertEqual(RemoteAppDefinitions.all(in: directory), [])
    }

    func testFileNameIsTheID() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let written = #"{"id":"other","host":"archie","app":"Spotify","name":"Music"}"#
        try Data(written.utf8).write(to: directory.appendingPathComponent("music.json"))
        XCTAssertEqual(RemoteAppDefinitions.all(in: directory).map(\.id), ["music"])
    }

    func testPathLikeIDsAreRefused() {
        let escape = RemoteAppDefinition(id: "../escape", host: "archie", app: "Spotify", name: "Spotify")
        XCTAssertThrowsError(try RemoteAppDefinitions.save(escape, in: directory))
        XCTAssertFalse(RemoteAppDefinitions.remove("../escape", in: directory))
    }

    func testLedgerKeepsEachOpenAppOnce() {
        let file = directory.appendingPathComponent("open.json")
        let entry = RemoteAppLedger.Entry(host: "archie", wid: 402653195, display: "LATS-1")
        RemoteAppLedger.add(entry, at: file)
        RemoteAppLedger.add(entry, at: file)
        XCTAssertEqual(RemoteAppLedger.entries(at: file), [entry])
        RemoteAppLedger.remove(entry, at: file)
        XCTAssertEqual(RemoteAppLedger.entries(at: file), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
