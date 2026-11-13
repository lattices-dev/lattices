import AppKit
import Carbon
import SwiftUI
import XCTest
@testable import Lattices

final class OnboardingPracticeTests: XCTestCase {
    func testArrowKeysMirrorPlacementHotkeys() {
        XCTAssertEqual(OnboardingPractice.position(for: .leftArrow), .left)
        XCTAssertEqual(OnboardingPractice.position(for: .rightArrow), .right)
        XCTAssertEqual(OnboardingPractice.position(for: .upArrow), .top)
        XCTAssertEqual(OnboardingPractice.position(for: .downArrow), .bottom)
        XCTAssertEqual(OnboardingPractice.position(for: "c"), .center)
    }

    /// Return and Escape belong to Continue and Back.
    func testLeavesNavigationKeysAlone() {
        XCTAssertNil(OnboardingPractice.position(for: .return))
        XCTAssertNil(OnboardingPractice.position(for: .escape))
        XCTAssertNil(OnboardingPractice.position(for: .tab))
    }

    /// The sample window stays inside the board for every reachable placement,
    /// and every other tile position, at the sizes the window can take.
    func testSampleWindowLandsWithinBoard() {
        for size in [CGSize(width: 464, height: 158), CGSize(width: 528, height: 158), CGSize(width: 900, height: 300)] {
            let board = CGRect(origin: .zero, size: size)
            for position in OnboardingPractice.positions + TilePosition.allCases {
                let frame = OnboardingPractice.windowFrame(for: position, in: size)
                XCTAssertTrue(board.contains(frame), "\(position) at \(size): \(frame)")
                XCTAssertGreaterThan(frame.width, 0, "\(position)")
                XCTAssertGreaterThan(frame.height, 0, "\(position)")
            }
        }
        let left = OnboardingPractice.windowFrame(for: .left, in: CGSize(width: 400, height: 200))
        XCTAssertEqual(left, CGRect(x: 2, y: 2, width: 196, height: 196))
    }

    func testClearedActionShowsUnassigned() {
        var bindings = HotkeyStore.defaultBindings
        bindings.removeValue(forKey: .tileLeft)
        XCTAssertNil(OnboardingPractice.keycaps(for: bindings[.tileLeft]))
        XCTAssertTrue(OnboardingPractice.realWorldHint(bindings: bindings).contains("no shortcut"))
    }

    func testRemappedActionShowsItsOwnBinding() {
        var bindings = HotkeyStore.defaultBindings
        let parts = KeyBinding.displayParts(keyCode: 4, carbonModifiers: UInt32(cmdKey | shiftKey))
        bindings[.tileLeft] = KeyBinding(keyCode: 4, carbonModifiers: UInt32(cmdKey | shiftKey), displayParts: parts)
        XCTAssertEqual(OnboardingPractice.keycaps(for: bindings[.tileLeft]), ["⇧⌘", "H"])
        XCTAssertTrue(OnboardingPractice.realWorldHint(bindings: bindings).contains("⇧⌘H"))
        // Remapping one arrow leaves the others on their own bindings.
        XCTAssertEqual(OnboardingPractice.keycaps(for: bindings[.tileRight]), ["⌃⌥", "→"])
    }

    func testDefaultBindingsRead() {
        XCTAssertEqual(OnboardingPractice.keycaps(for: HotkeyStore.defaultBindings[.commandBar]), ["⌃⌥", "Space"])
        XCTAssertEqual(OnboardingPractice.keycaps(for: HotkeyStore.defaultBindings[.tileMaximize]), ["⌃⌥", "↩"])
    }
}

@MainActor
final class OnboardingRenderTests: XCTestCase {
    func testRenderEachStep() throws {
        guard let dir = ProcessInfo.processInfo.environment["ONBOARDING_RENDER_DIR"] else { throw XCTSkip("Opt-in offline render") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for step in OnboardingView.Step.allCases {
            let view = OnboardingView(step: step) { _ in }
                .frame(width: 560, height: 520)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("onboarding-\(step.rawValue + 1).png"))
        }
    }
}
