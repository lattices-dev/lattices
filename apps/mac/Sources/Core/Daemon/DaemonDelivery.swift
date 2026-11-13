import Foundation

/// Whether a mutation reached the desktop, and so whether the caller may send
/// it again. Every reply to a `.mutate` endpoint carries one. Mirrors
/// packages/host-linux/src/delivery.ts: both hosts answer the same client.
enum DaemonDelivery: String {
    /// Refused before the handler ran, or by a check that acts on nothing.
    case notDelivered = "not_delivered"
    /// The handler ran and threw. It may have pressed the key first.
    case uncertain = "delivery_uncertain"
    /// The handler returned. Nothing read the result back.
    case deliveredUnverified = "delivered_unverified"

    /// Mutations that land the same however often they run: a second focus is still one focus.
    static let repeatableMethods: Set<String> = [
        "windows.focus", "windows.place", "windows.move", "windows.present",
        "computer.prepare", "computer.focusWindow", "computer.launchApp", "computer.setValue",
        "computer.showCursor", "computer.windowState", "computer.verify",
        "layers.switch", "layers.activate", "layers.assign", "layers.unassign", "layers.rename", "layers.delete",
        "solo.enter", "solo.exit", "stage.enter", "stage.exit",
        "sessions.launch", "sessions.kill", "sessions.detach", "sessions.sync",
        "groups.launch", "groups.kill", "tabs.select", "tabs.layout",
        "layout.distribute", "spaces.optimize", "projects.scan", "ocr.scan",
        "overlay.publish", "overlay.clear",
        "overlay.actor.publish", "overlay.actor.moveTo", "overlay.actor.hud", "overlay.actor.visibility",
        "settings.cursorAppearance.set", "settings.spaceBezel.set",
        "app.show", "mouse.home", "views.save", "views.open", "views.remove", "hosts.add",
        "visit.host", "visit.side",
        "mouse.shortcuts.set", "mouse.shortcuts.upsert", "mouse.shortcuts.remove", "mouse.shortcuts.restoreDefaults",
        "voice.listen", "voice.stopListening", "voice.reconnect",
        "capture.screenshotWindow", "capture.screenshotRegion", "capture.screenshotDisplay",
        "capture.zoomArtifact", "capture.stopRecording", "vision.analyzeWindow", "vision.analyzeArtifact",
    ]

    /// A thrown RouterError other than `.custom` is a refusal that acted on nothing.
    static func failed(_ error: Error) -> DaemonDelivery {
        switch error as? RouterError {
        case .unknownMethod?, .missingParam?, .notFound?: return .notDelivered
        default: return .uncertain
        }
    }

    func json(method: String) -> JSON {
        let repeatable = Self.repeatableMethods.contains(method)
        let retrySafe: Bool
        let recovery: String
        switch self {
        case .notDelivered: (retrySafe, recovery) = (true, "retry")
        case .uncertain: (retrySafe, recovery) = repeatable ? (true, "retry") : (false, "observe_then_retry")
        case .deliveredUnverified: (retrySafe, recovery) = (repeatable, "none")
        }
        return .object(["status": .string(rawValue), "retrySafe": .bool(retrySafe), "recovery": .string(recovery)])
    }
}
