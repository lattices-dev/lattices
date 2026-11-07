import Foundation

struct DistributeIntent: LatticeIntent {
    static let name = "distribute"
    static let title = "Distribute windows evenly across the screen"

    static let phrases = [
        // Primary: spread / distribute
        "distribute",
        "distribute windows",
        "distribute everything",
        "spread",
        "spread out",
        "spread out the windows",
        "spread them out",
        // organize / arrange
        "organize",
        "organize windows",
        "organize my windows",
        "organize everything",
        "arrange",
        "arrange windows",
        "arrange my windows",
        "arrange everything",
        "arrange them evenly",
        // tidy / clean
        "tidy",
        "tidy up",
        "tidy up the desktop",
        "tidy up my windows",
        "clean up",
        "clean up the layout",
        "clean up my desktop",
        // other
        "even out",
        "even out the windows",
        "fix the layout",
        "reset the layout",
        "make a grid",
        "grid layout",
        "line them up",
        "line everything up",
        "get everything organized",
        "clean up the windows",
        "clean up windows",
    ]

    static let slots: [SlotDef] = []

    func perform(slots: [String: JSON]) throws -> JSON {
        try LatticesApi.onMain {
            WindowTiler.distributeVisible()
        }
        return .object(["ok": .bool(true)])
    }
}
