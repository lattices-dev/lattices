import AppKit
import XCTest
@testable import Lattices

@MainActor
final class HyperspaceSelectionFrameTests: XCTestCase {
    func testDesktopGesturesPassThroughTheFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let view = HyperspaceSelectionFrame(frame: frame, usableFrame: frame, line: HyperspaceIsland.explainer)
        view.layoutSubtreeIfNeeded()
        // The island lives on its own panel, so nothing here blocks a window pick.
        for point in [CGPoint(x: 400, y: 400), CGPoint(x: 8, y: 8), CGPoint(x: 720, y: 870)] {
            XCTAssertNil(view.hitTest(point))
        }
    }

    func testIslandExplainsFirstThenHints() {
        XCTAssertEqual(HyperspaceIsland.line(visit: 1, graduated: false).map(\.0), HyperspaceIsland.explainer.map(\.0))
        XCTAssertEqual(HyperspaceIsland.line(visit: 3, graduated: false).map(\.0), HyperspaceIsland.explainer.map(\.0))
        XCTAssertNotEqual(HyperspaceIsland.line(visit: 4, graduated: false).map(\.0), HyperspaceIsland.explainer.map(\.0))
        // Dismissing the explainer graduates straight to hints.
        XCTAssertNotEqual(HyperspaceIsland.line(visit: 2, graduated: true).map(\.0), HyperspaceIsland.explainer.map(\.0))
        // Hints rotate through every entry.
        let seen = Set((4..<(4 + HyperspaceIsland.hints.count)).map {
            HyperspaceIsland.line(visit: $0, graduated: false).map(\.0).joined()
        })
        XCTAssertEqual(seen.count, HyperspaceIsland.hints.count)
    }

    /// Opt-in component renders use synthetic windows, with no display, keyboard
    /// monitor, or AX mutation. They exercise the production AppKit surface.
    func testRenderSelectionFrame() throws {
        guard let output = ProcessInfo.processInfo.environment["HYPERSPACE_FRAME_RENDER_DIR"] else {
            throw XCTSkip("Set HYPERSPACE_FRAME_RENDER_DIR for component renders")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, size) in [("laptop", NSSize(width: 1440, height: 900)),
                             ("ultrawide", NSSize(width: 3440, height: 1440))] {
            let bounds = CGRect(origin: .zero, size: size)
            let root = SyntheticDesktop(frame: bounds)
            root.wantsLayer = true
            let view = HyperspaceSelectionFrame(frame: bounds, usableFrame: bounds.insetBy(dx: 0, dy: 25), line: HyperspaceIsland.explainer)
            root.addSubview(view)
            root.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: bounds))
            root.cacheDisplay(in: bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        }
    }
}

private final class SyntheticDesktop: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.31, green: 0.39, blue: 0.46, alpha: 1).setFill()
        bounds.fill()
        let margin = bounds.width * 0.05
        let gap: CGFloat = 16
        let width = (bounds.width - margin * 2 - gap) / 2
        let height = bounds.height * 0.70
        for index in 0..<2 {
            let rect = CGRect(x: margin + CGFloat(index) * (width + gap), y: bounds.height * 0.12,
                              width: width, height: height)
            (index == 0 ? NSColor(calibratedWhite: 0.97, alpha: 1) : NSColor(calibratedWhite: 0.10, alpha: 1)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            let color: NSColor = index == 0 ? .darkGray : .white
            let text = index == 0 ? "Layout research" : "rex · lattices"
            (text as NSString).draw(at: CGPoint(x: rect.minX + 24, y: rect.maxY - 40), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: color,
            ])
            for line in 0..<12 {
                color.withAlphaComponent(0.12).setFill()
                CGRect(x: rect.minX + 24, y: rect.maxY - 92 - CGFloat(line) * 30,
                       width: width * (line % 3 == 0 ? 0.55 : 0.75), height: 8).fill()
            }
        }
    }
}
