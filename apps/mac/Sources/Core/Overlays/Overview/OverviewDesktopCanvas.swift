import AppKit
import SwiftUI

/// Desktop regions share edges within each monitor. Geometry is independent of
/// the camera, so zooming and panning never changes desktop or window identity.
struct OverviewCanvasLayout {
    struct Cell: Identifiable {
        let monitor: Int
        let space: Int
        let frame: CGRect
        var id: String { "\(monitor):\(space)" }
    }
    let cells: [Cell]
    let size: CGSize

    init(counts: [Int], aspects: [CGFloat]) {
        var cells: [Cell] = []
        var x: CGFloat = 0
        var height: CGFloat = 0
        for (monitor, count) in counts.enumerated() where count > 0 {
            let columns = Int(ceil(sqrt(Double(count))))
            let rows = (count + columns - 1) / columns
            let aspect = monitor < aspects.count && aspects[monitor] > 0 ? aspects[monitor] : 1.6
            let cell = CGSize(width: 400, height: 400 / aspect)
            if !cells.isEmpty { x += 32 }
            for space in 0..<count {
                cells.append(Cell(monitor: monitor, space: space, frame: CGRect(
                    x: x + CGFloat(space % columns) * cell.width,
                    y: CGFloat(space / columns) * cell.height,
                    width: cell.width, height: cell.height)))
            }
            x += CGFloat(columns) * cell.width
            height = max(height, CGFloat(rows) * cell.height)
        }
        self.cells = cells
        self.size = CGSize(width: max(1, x), height: max(1, height))
    }

    func fit(in room: CGSize) -> CGFloat {
        max(0.01, min(max(1, room.width - 64) / size.width, max(1, room.height - 100) / size.height))
    }

    static func window(_ frame: CGRect, display: CGRect, cell: CGRect) -> CGRect? {
        guard display.width > 0, display.height > 0 else { return nil }
        let clipped = frame.intersection(display)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return CGRect(x: cell.minX + (clipped.minX - display.minX) / display.width * cell.width,
                      y: cell.minY + (clipped.minY - display.minY) / display.height * cell.height,
                      width: clipped.width / display.width * cell.width,
                      height: clipped.height / display.height * cell.height)
    }
}

/// Uses Overview's existing projection, selection, drag/drop and verified
/// actions. This camera only changes the view; it never moves a real window.
struct OverviewDesktopCanvas: View {
    @ObservedObject var model: OverviewModel
    @State private var zoom: CGFloat = 1
    @State private var center: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var magnifyStart: CGFloat?

    private var layout: OverviewCanvasLayout {
        OverviewCanvasLayout(counts: model.projection.desk.map { $0.spaces.count },
                             aspects: model.projection.desk.map { $0.display.bounds.width / max(1, $0.display.bounds.height) })
    }

    var body: some View {
        GeometryReader { geo in
            let layout = layout
            let scale = layout.fit(in: geo.size) * zoom
            let camera = center ?? CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.12)
                    .contentShape(Rectangle())
                    .onTapGesture { model.clearSelection() }
                    .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                        let start = dragStart ?? camera
                        dragStart = start
                        center = clamped(CGPoint(x: start.x - value.translation.width / scale,
                                                 y: start.y - value.translation.height / scale), in: layout)
                    }.onEnded { _ in dragStart = nil })
                ForEach(layout.cells) { cell in
                    let rect = screen(cell.frame, camera: camera, scale: scale, room: geo.size)
                    if rect.intersects(CGRect(origin: .zero, size: geo.size)) {
                        let monitor = model.projection.desk[cell.monitor]
                        let space = monitor.spaces[cell.space]
                        if cell.space == 0 {
                            Text(monitor.display.name)
                                .font(Typo.mono(10))
                                .foregroundStyle(Palette.textMuted)
                                .frame(width: rect.width, alignment: .leading)
                                .position(x: rect.midX, y: rect.minY - 14)
                                .allowsHitTesting(false)
                        }
                        OverviewMap(model: model, display: monitor.display, space: space,
                                    size: rect.size, quiet: true, connected: true)
                            .overlay(alignment: .bottomLeading) {
                                HStack(spacing: 5) {
                                    if space.isCurrent { Circle().fill(Palette.running).frame(width: 4, height: 4) }
                                    Text(space.title)
                                    if let note = space.mapNote { Text("· \(note)").opacity(0.65) }
                                }
                                .font(Typo.mono(9))
                                .foregroundStyle(Palette.textDim)
                                .lineLimit(1)
                                .padding(7)
                                .allowsHitTesting(false)
                            }
                            .position(x: rect.midX, y: rect.midY)
                    }
                }
            }
            .clipped()
            .background(OverviewCanvasInput(enabled: !model.membershipShown, onScroll: { delta, location, magnifying in
                if magnifying {
                    changeZoom(zoom * exp(delta.height * 0.008), at: location, room: geo.size, layout: layout)
                } else {
                    center = clamped(CGPoint(x: camera.x - delta.width / scale, y: camera.y - delta.height / scale), in: layout)
                }
            }, onZoom: { out in
                withAnimation(.easeInOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18)) {
                    changeZoom(zoom * (out ? 1 / 1.35 : 1.35), at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), room: geo.size, layout: layout)
                }
            }))
            .simultaneousGesture(MagnificationGesture().onChanged { value in
                let initial = magnifyStart ?? zoom
                magnifyStart = initial
                changeZoom(initial * value, at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), room: geo.size, layout: layout)
            }.onEnded { _ in magnifyStart = nil })
            .overlay(alignment: .bottomLeading) {
                minimap(layout, camera: camera, scale: scale, room: geo.size)
                    .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    Button { changeZoom(zoom / 1.35, at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), room: geo.size, layout: layout) } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Zoom out canvas")
                    Text("\(Int(zoom * 100))%")
                        .font(Typo.mono(10)).monospacedDigit().frame(width: 40)
                    Button { changeZoom(zoom * 1.35, at: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2), room: geo.size, layout: layout) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Zoom in canvas")
                    Divider().frame(height: 12)
                    Button("Fit") { zoom = 1; center = nil }
                }
                .buttonStyle(.plain)
                .padding(10)
                .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.border))
                .padding(16)
            }
        }
        .help("Scroll to pan · ↑/↓, pinch or ⌃⌥-scroll to zoom · Fit to show all desktops")
        .onChange(of: model.projection.desk.map { $0.spaces.map(\.spaceId) }) { _, _ in center = nil; zoom = 1 }
    }

    private func screen(_ rect: CGRect, camera: CGPoint, scale: CGFloat, room: CGSize) -> CGRect {
        CGRect(x: (rect.minX - camera.x) * scale + room.width / 2,
               y: (rect.minY - camera.y) * scale + room.height / 2,
               width: rect.width * scale, height: rect.height * scale)
    }

    private func clamped(_ point: CGPoint, in layout: OverviewCanvasLayout) -> CGPoint {
        CGPoint(x: min(max(0, point.x), layout.size.width), y: min(max(0, point.y), layout.size.height))
    }

    private func changeZoom(_ value: CGFloat, at point: CGPoint, room: CGSize, layout: OverviewCanvasLayout) {
        let next = min(4, max(0.7, value))
        let oldScale = layout.fit(in: room) * zoom
        let newScale = layout.fit(in: room) * next
        let old = center ?? CGPoint(x: layout.size.width / 2, y: layout.size.height / 2)
        center = clamped(CGPoint(x: old.x + (point.x - room.width / 2) * (1 / oldScale - 1 / newScale),
                                y: old.y + (point.y - room.height / 2) * (1 / oldScale - 1 / newScale)), in: layout)
        zoom = next
    }

    private func minimap(_ layout: OverviewCanvasLayout, camera: CGPoint, scale: CGFloat, room: CGSize) -> some View {
        let miniScale = min(164 / layout.size.width, 100 / layout.size.height)
        let size = CGSize(width: layout.size.width * miniScale, height: layout.size.height * miniScale)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3")
                Text("LATTICES")
                Spacer(minLength: 8)
                Text("\(layout.cells.count)").foregroundStyle(Palette.textMuted)
            }.font(Typo.mono(9)).foregroundStyle(Palette.textDim)
            Canvas { context, _ in
                for cell in layout.cells {
                    let monitor = model.projection.desk[cell.monitor]
                    let space = monitor.spaces[cell.space]
                    let rect = cell.frame.applying(CGAffineTransform(scaleX: miniScale, y: miniScale))
                    context.fill(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(space.isCurrent ? 0.12 : 0.035)))
                    context.stroke(Path(rect), with: .color(.white.opacity(0.2)), lineWidth: 0.5)
                    for row in space.rows {
                        guard let frame = row.frame,
                              let zone = OverviewCanvasLayout.window(frame, display: monitor.display.bounds, cell: cell.frame) else { continue }
                        context.fill(Path(zone.applying(CGAffineTransform(scaleX: miniScale, y: miniScale))), with: .color(.white.opacity(0.2)))
                    }
                }
                let viewport = CGRect(x: (camera.x - room.width / scale / 2) * miniScale,
                                      y: (camera.y - room.height / scale / 2) * miniScale,
                                      width: room.width / scale * miniScale, height: room.height / scale * miniScale)
                    .intersection(CGRect(origin: .zero, size: size))
                if !viewport.isNull {
                    context.stroke(Path(viewport.insetBy(dx: 0.7, dy: 0.7)), with: .color(.white.opacity(0.85)), lineWidth: 1.2)
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                center = clamped(CGPoint(x: value.location.x / miniScale, y: value.location.y / miniScale), in: layout)
            })
            .accessibilityLabel("Canvas minimap")
            .accessibilityHint("Drag to pan. Use Fit to show all desktops.")
        }
        .frame(width: size.width)
        .padding(10)
        .background(Palette.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    }
}

/// AppKit supplies trackpad deltas while SwiftUI owns camera state. The local
/// monitor is scoped to this view's window and bounds and removed on dismantle.
private struct OverviewCanvasInput: NSViewRepresentable {
    var enabled: Bool
    var onScroll: (CGSize, CGPoint, Bool) -> Void
    var onZoom: (Bool) -> Void
    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.onScroll = enabled ? onScroll : nil
        view.onZoom = enabled ? onZoom : nil
        view.refreshOwnership()
    }
    static func dismantleNSView(_ view: InputView, coordinator: ()) { view.stop() }

    final class InputView: NSView {
        var onScroll: ((CGSize, CGPoint, Bool) -> Void)?
        var onZoom: ((Bool) -> Void)?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        func refreshOwnership() {
            let active = window?.isKeyWindow == true && !isHiddenOrHasHiddenAncestor && onScroll != nil && !(window?.firstResponder is NSTextView)
            SpaceZoomInput.onCanvasZoom = active ? onZoom.map { zoom in { out, _ in zoom(out) } } : nil
            SpaceZoomInput.setCanvas(active)
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.didUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.refreshOwnership() })
            }
            refreshOwnership()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor, self.onScroll != nil else { return event }
                if event.type == .keyDown {
                    // Text editors and modified app shortcuts keep their arrows.
                    guard !(window.firstResponder is NSTextView), [125, 126].contains(event.keyCode),
                          event.modifierFlags.intersection([.command, .option, .shift]).isEmpty else { return event }
                    if !event.isARepeat { self.onZoom?(event.keyCode == 125) }
                    return nil
                }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                self.onScroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), point, event.modifierFlags.contains(.command) || event.modifierFlags.contains([.control, .option]))
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            SpaceZoomInput.onCanvasZoom = nil
            SpaceZoomInput.setCanvas(false)
        }
        deinit { stop() }
    }
}
