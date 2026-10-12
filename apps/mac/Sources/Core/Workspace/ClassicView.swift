import AppKit

/// Classic: the desktop as if Lattices weren't running. Every window a
/// layer switch parked goes back where it was and every app it hid shows
/// (`LayerStage.showAll`); nothing is tiled or put away. Asked for again
/// while it shows, it becomes Classic · one space: windows on the other
/// desktops of each display are carried to the desktop that display is
/// showing, so everything is on one desktop per monitor.
extension WorkspaceManager {
    func showClassic() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.showClassic() }
            return
        }
        if classicShowing {
            gatherToShowingDesktops()
            return
        }
        let outcome = exitLayers(showFeedback: false)
        classicShowing = true
        let back = outcome.unparked.count + outcome.rescued
        var note: [String] = []
        if back > 0 { note.append("\(back) back") }
        if !outcome.unhiddenApps.isEmpty { note.append("\(outcome.unhiddenApps.count) apps shown") }
        LayerBezel.shared.acknowledge(note.isEmpty ? "Classic" : "Classic · \(note.joined(separator: ", "))")
        DiagnosticLog.shared.info("Classic: \(outcome.summary)")
    }

    /// The windows Classic · one space would carry, with where to: each one
    /// on a single other desktop of its display, to the desktop that display
    /// shows. Fullscreen Spaces, minimized and hidden windows stay.
    static func classicGatherPlan(windows: [WindowEntry], displays: [DisplaySpaces]) -> [(window: WindowEntry, to: Int)] {
        windows.compactMap { window in
            guard DesktopModel.isContent(window), !window.appHidden, !window.collapsed,
                  window.spaceIds.count == 1, let source = window.spaceIds.first,
                  let display = displays.first(where: { $0.spaces.contains { $0.id == source } }),
                  source != display.currentSpaceId,
                  display.spaces.contains(where: { $0.id == display.currentSpaceId })
            else { return nil }
            return (window, display.currentSpaceId)
        }
    }

    private func gatherToShowingDesktops() {
        guard !classicGathering else { return }
        let plan = Self.classicGatherPlan(
            windows: DesktopModel.shared.refreshNow(),
            displays: WindowTiler.getDisplaySpaces()
        )
        guard !plan.isEmpty else {
            LayerBezel.shared.acknowledge("Classic · one space")
            return
        }
        classicGathering = true
        let generation = layerFocus.generation
        LayerBezel.shared.acknowledge("Classic · one space · moving \(plan.count)")
        DispatchQueue.global(qos: .userInitiated).async {
            var moved = 0
            var failed: [String] = []
            for (window, target) in plan {
                guard DispatchQueue.main.sync(execute: {
                    self.classicShowing && self.layerFocus.generation == generation
                }) else { break }
                do {
                    let receipt = try ActionRuntime.shared.executeWindowMove(
                        params: .object(["wid": .int(Int(window.wid)), "spaceId": .int(target)]),
                        source: "app.classic"
                    )
                    if let failure = WindowMovementService.failureMessage(for: receipt) {
                        failed.append("\(window.app): \(failure)")
                    } else {
                        moved += 1
                    }
                } catch {
                    failed.append("\(window.app): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.classicGathering = false
                guard self.classicShowing && self.layerFocus.generation == generation else { return }
                let tail = failed.isEmpty ? "" : ", \(failed.count) stayed"
                LayerBezel.shared.acknowledge("Classic · one space · \(moved) moved\(tail)")
                DiagnosticLog.shared.info("Classic one space: moved \(moved) of \(plan.count)"
                    + (failed.isEmpty ? "" : " — \(failed.joined(separator: "; "))"))
            }
        }
    }
}
