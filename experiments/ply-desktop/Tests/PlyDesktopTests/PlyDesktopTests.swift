import AppKit
import Testing
@testable import PlyDesktop

@Test func returningToGrabPointRemainsADrag() {
    var drag = PlyDrag(pointer: CGPoint(x: 100, y: 100), origin: CGPoint(x: 20, y: 30))
    #expect(drag.update(CGPoint(x: 102, y: 101)) == nil)
    #expect(drag.update(CGPoint(x: 105, y: 100)) == CGPoint(x: 25, y: 30))
    #expect(drag.update(CGPoint(x: 100, y: 100)) == CGPoint(x: 20, y: 30))
    #expect(drag.moved)
}

@Test func clampingKeepsTheWholeCompanionOnNegativeOriginDisplay() {
    let displays = [CGRect(x: 0, y: 30, width: 1440, height: 850), CGRect(x: -1280, y: 0, width: 1280, height: 1024)]
    let frame = PlyPlacement.clamped(CGRect(x: -1320, y: 970, width: 128, height: 128), to: displays)
    #expect(frame == CGRect(x: -1280, y: 896, width: 128, height: 128))
}

@Test func disconnectedScreenRecoversToNearestVisibleDisplay() {
    let visible = CGRect(x: 0, y: 80, width: 1440, height: 800)
    let frame = PlyPlacement.clamped(CGRect(x: 2500, y: -400, width: 176, height: 176), to: [visible])
    #expect(visible.contains(frame))
    #expect(frame.origin == CGPoint(x: 1264, y: 80))
}

@Test func alreadyVisiblePlacementDoesNotJump() {
    let frame = CGRect(x: 320, y: 200, width: 128, height: 128)
    #expect(PlyPlacement.clamped(frame, to: [CGRect(x: 0, y: 30, width: 1440, height: 850)]) == frame)
}

@Test @MainActor func allEightFramesContainTheCreatureAndTransparentCorners() throws {
    let atlas = try PlyAtlas()
    #expect(atlas.frames.count == 8)
    for pose in PlyPose.allCases {
        #expect(atlas.frames[pose.rawValue].width >= 440)
        #expect(atlas.alpha(at: CGPoint(x: 0.5, y: 0.5), pose: pose) > 0.9)
        #expect(atlas.alpha(at: CGPoint(x: 0.01, y: 0.01), pose: pose) < 0.02)
        #expect(atlas.alpha(at: CGPoint(x: 0.99, y: 0.99), pose: pose) < 0.02)
    }
}

@Test @MainActor func draggingUsesTheIncomingEventCoordinates() throws {
    // No OS input is posted and the window is never shown. The real mouse may
    // be anywhere; only the received event should determine this movement.
    _ = NSApplication.shared
    let view = PlyView(atlas: try PlyAtlas())
    let panel = PlyPanel(contentRect: CGRect(x: 100, y: 100, width: 128, height: 128),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.contentView = view
    defer { panel.close() }
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 64, y: 64)))
    view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 24, y: 104)))
    #expect(panel.frame.origin == CGPoint(x: 60, y: 140))
    view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 24, y: 104)))
}
