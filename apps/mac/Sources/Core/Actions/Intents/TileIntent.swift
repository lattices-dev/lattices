import Foundation

struct TileIntent: LatticeIntent {
    static let name = "tile_window"
    static let title = "Tile a window to a screen position"

    static let phrases = [
        // Primary operator: tile
        "tile {position}",
        "tile it {position}",
        "tile this {position}",
        "tile the window {position}",
        // snap
        "snap {position}",
        "snap it {position}",
        "snap to the {position}",
        "snap to {position}",
        // move / put
        "move to the {position}",
        "move it to the {position}",
        "move it {position}",
        "move this to the {position}",
        "move this over to the {position}",
        "put it on the {position}",
        "put this on the {position}",
        "put it on the {position} side",
        "put this on the {position} side",
        "put it {position}",
        "throw it {position}",
        "throw it to the {position}",
        "just put it on the {position}",
        // Standalone position phrases
        "{position} half",
        "{position} side",
        // maximize variants (no slot needed — position is the whole phrase)
        "maximize",
        "maximize it",
        "make it full screen",
        "full screen",
        "go full screen",
        "make it big",
        "center it",
        "center the window",
    ]

    static let slots = [
        SlotDef(name: "position", type: .position, required: true, defaultValue: .string("center")),
    ]

    func perform(slots: [String: JSON]) throws -> JSON {
        let posName = slots["position"]?.stringValue ?? "center"
        guard let placement = PlacementSpec(string: posName) else {
            return .object(["ok": .bool(false), "reason": .string("Unknown position '\(posName)'")])
        }

        try LatticesApi.onMain {
            WindowTiler.tileFrontmostViaAX(to: placement)
        }
        return .object(["ok": .bool(true), "position": .string(posName)])
    }
}
