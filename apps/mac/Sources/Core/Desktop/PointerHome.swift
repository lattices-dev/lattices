import AppKit

/// Ends the current visit and returns the cursor to this Mac's main display.
enum PointerHome {
    static func bringHome() {
        let work = {
            VisitController.shared.end(because: "home")
            let main = NSScreen.screens.first?.frame ?? .zero
            MouseFinder.shared.summon(to: NSPoint(x: main.midX, y: main.midY))
            DiagnosticLog.shared.info("Pointer home")
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.sync(execute: work) }
    }
}
