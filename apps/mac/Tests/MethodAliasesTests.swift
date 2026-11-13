import XCTest
@testable import Lattices

final class MethodAliasesTests: XCTestCase {
    func testOldNamesResolveToDomainNames() {
        let expected: [String: String] = [
            "window.place": "windows.place",
            "window.pick.start": "windows.pick",
            "window.tile": "windows.place",
            "layer.switch": "layers.switch",
            "space.optimize": "spaces.optimize",
            "session.launch": "sessions.launch",
            "group.kill": "groups.kill",
            "tabStacks.create": "tabs.stack",
            "tabStacks.delete": "tabs.unstack",
            "lattices.search": "search.query",
            "focus.toggle": "solo.toggle",
            "tmux.sessions": "tmux.list",
            "tmux.inventory": "tmux.list",
            "ocr.recent": "ocr.history",
            "intents.execute": "intents.run",
            "actions.undo": "history.undo",
        ]
        for (old, new) in expected {
            XCTAssertEqual(MethodAliases.canonical(old), new, old)
        }
        XCTAssertEqual(MethodAliases.canonical("windows.list"), "windows.list")
        XCTAssertEqual(MethodAliases.canonical("actions.execute"), "actions.execute")
    }

    func testCuaDomainResolvesToComputer() {
        XCTAssertEqual(MethodAliases.canonical("cua.click"), "computer.click")
        XCTAssertEqual(MethodAliases.canonical("cua.typeText"), "computer.typeText")
        XCTAssertEqual(MethodAliases.canonical("computer.click"), "computer.click")
        // Only the leading domain is swapped.
        XCTAssertEqual(MethodAliases.canonical("cuaz.click"), "cuaz.click")
        XCTAssertEqual(MethodAliases.canonical("windows.cua.x"), "windows.cua.x")
    }

    func testDispatchAcceptsCuaAndSchemaListsIt() throws {
        let api = LatticesApi()
        api.register(Endpoint(
            method: "computer.click",
            description: "test",
            access: .mutate,
            params: [],
            returns: .ok,
            handler: { _ in .string("clicked") }
        ))
        XCTAssertEqual(try api.dispatch(method: "cua.click", params: nil), .string("clicked"))
        XCTAssertEqual(api.schema()["aliases"]?["cua.click"], .string("computer.click"))
        XCTAssertNil(api.schema()["aliases"]?["cua.drag"])
    }

    func testWindowTileMapsPositionToPlacement() {
        let resolved = MethodAliases.resolve("window.tile", params: .object([
            "session": .string("vox"),
            "position": .string("left"),
        ]))
        XCTAssertEqual(resolved.method, "windows.place")
        XCTAssertEqual(resolved.params?["placement"], .string("left"))
        XCTAssertEqual(resolved.params?["session"], .string("vox"))
    }

    func testTmuxInventoryAsksForOrphans() {
        let resolved = MethodAliases.resolve("tmux.inventory", params: nil)
        XCTAssertEqual(resolved.method, "tmux.list")
        XCTAssertEqual(resolved.params?["includeOrphans"], .bool(true))
    }

    func testDispatchRoutesOldNamesAndSchemaListsAliases() throws {
        let api = LatticesApi()
        api.register(Endpoint(
            method: "windows.place",
            description: "test",
            access: .mutate,
            params: [],
            returns: .ok,
            handler: { params in params?["placement"] ?? .null }
        ))
        let result = try api.dispatch(method: "window.tile", params: .object([
            "session": .string("vox"),
            "position": .string("right"),
        ]))
        XCTAssertEqual(result, .string("right"))
        XCTAssertThrowsError(try api.dispatch(method: "window.nope", params: nil))

        let schema = api.schema()
        XCTAssertEqual(schema["aliases"]?["window.place"], .string("windows.place"))
        // Aliases whose target this instance does not serve are left out.
        XCTAssertNil(schema["aliases"]?["session.launch"])
    }
}
