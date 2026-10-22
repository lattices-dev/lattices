import AppKit
import SwiftUI

/// Trackpad and wheel input for a bounded canvas. Two-finger scroll pans;
/// ⌘-scroll and pinch zoom at the pointer. The local monitor only claims
/// events over this view in its own window, and is removed on dismantle.
struct CanvasScrollInput: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (_ factor: CGFloat, _ anchor: CGPoint) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onPan = onPan
        view.onZoom = onZoom
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                if event.type == .magnify {
                    self.onZoom?(1 + event.magnification, point)
                } else if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                    let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
                    self.onZoom?(exp(event.scrollingDeltaY * step), point)
                } else {
                    let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                    self.onPan?(CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
                }
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { stop() }
    }
}
