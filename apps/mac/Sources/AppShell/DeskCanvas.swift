import AppKit
import SwiftUI

/// The physical desk as a canvas: every monitor once at its size in
/// millimetres, the hosts cabled to each, and which one is on screen. Drag a
/// monitor to fix where it really sits; the hosts' own layouts don't move.
struct DeskCanvas: View {
    var desk: Desk
    /// What a host shows on a monitor, when it has sent a picture of it.
    var image: (_ host: String, _ key: String) -> NSImage? = { _, _ in nil }
    @ObservedObject var inputs: MonitorInputs
    @ObservedObject var store: DeskStore
    /// Off for offline renders, which can't draw AppKit views.
    var trackpad = true
    @State private var camera: MachineCanvasCamera?
    @State private var panStart: CGSize?
    @State private var draft: (key: String, rect: CGRect)?
    @State private var dragStart: CGPoint?
    @State private var fitted = true
    /// The host under the pointer in the legend, or the one clicked there.
    @State private var hovered: String?
    @State private var pinned: String?
    @GestureState private var gesturing = false

    static let legendHeight: CGFloat = 30

    init(desk: Desk, image: @escaping (_ host: String, _ key: String) -> NSImage? = { _, _ in nil },
         inputs: MonitorInputs, store: DeskStore, trackpad: Bool = true, pinned: String? = nil) {
        self.desk = desk
        self.image = image
        _inputs = ObservedObject(wrappedValue: inputs)
        _store = ObservedObject(wrappedValue: store)
        self.trackpad = trackpad
        _pinned = State(initialValue: pinned)
    }

    private var monitors: [(monitor: DeskMonitor, rect: CGRect)] {
        desk.monitors.map { m in (m, draft?.key == m.key ? draft!.rect : m.rect) }
    }
    private var bounds: CGRect { monitors.reduce(CGRect.null) { $0.union($1.rect) } }
    private var signature: String { desk.monitors.map(\.key).joined(separator: ",") }
    private var dragging: Bool { dragStart != nil || panStart != nil }
    /// Hosts in the order they cable to the desk.
    private var hosts: [String] {
        var seen: [String] = []
        for m in desk.monitors { for h in m.hosts where !seen.contains(h) { seen.append(h) } }
        return seen
    }
    private var highlighted: String? { hovered ?? pinned }

    var body: some View {
        VStack(spacing: 0) {
            canvas
            legend.frame(height: Self.legendHeight)
        }
    }

    private var canvas: some View {
        GeometryReader { proxy in
            let monitors = monitors
            let bounds = desk.bounds
            let cam = camera ?? .fitting(bounds, in: proxy.size)
            ZStack(alignment: .topLeading) {
                MachineCanvasGrid(camera: cam)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { fit(bounds, proxy.size) }
                    .gesture(DragGesture(minimumDistance: 3).updating($gesturing) { _, s, _ in s = true }.onChanged { value in
                        let start = panStart ?? cam.pan
                        panStart = start
                        var next = cam
                        next.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                        move(next.clamped(to: bounds))
                    }.onEnded { _ in panStart = nil })
                ForEach(monitors, id: \.monitor.key) { item in
                    tile(item.monitor, rect: item.rect, others: monitors.filter { $0.monitor.key != item.monitor.key }.map(\.rect), camera: cam)
                }
                if desk.monitors.isEmpty {
                    Text("No monitors").foregroundStyle(Palette.textMuted)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                if trackpad { CanvasScrollInput(
                    onPan: { delta in if !dragging { move((camera ?? cam).panned(by: delta).clamped(to: bounds)) } },
                    onZoom: { factor, anchor in if !dragging { move((camera ?? cam).zoomed(by: factor, around: anchor).clamped(to: bounds)) } })
                    .allowsHitTesting(false) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .bottomTrailing) { zoomPill(cam, bounds: bounds, size: proxy.size).padding(10) }
            .overlay(alignment: .bottomLeading) { resetBar.padding(10) }
            .onAppear { if camera == nil { fit(bounds, proxy.size) } }
            .onChange(of: proxy.size) { _, size in refit(bounds, size) }
            .onChange(of: signature) { _, _ in refit(bounds, proxy.size) }
            .onChange(of: gesturing) { _, active in
                guard !active else { return }
                draft = nil; dragStart = nil; panStart = nil
            }
        }
        .background(MachineTone.well)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MachineTone.wellEdge, lineWidth: 1))
    }

    private func fit(_ bounds: CGRect, _ size: CGSize) {
        guard !dragging, size.width > 0, size.height > 0 else { return }
        camera = .fitting(bounds, in: size)
        fitted = true
    }

    private func refit(_ bounds: CGRect, _ size: CGSize) {
        guard !fitted, var next = camera, size.width > 0, size.height > 0 else { return fit(bounds, size) }
        next.viewport = size
        next.fitScale = MachineCanvasCamera.fitting(bounds, in: size).fitScale
        camera = next.clamped(to: bounds)
    }

    private func move(_ next: MachineCanvasCamera) {
        camera = next
        fitted = false
    }

    // MARK: Monitors

    /// The host on screen: the owner of the current input, or the only host
    /// cabled unless the sensor says that host isn't showing.
    static func current(_ m: DeskMonitor, owner: String?, onlyShowing: Bool? = nil) -> String? {
        if let owner, let host = m.hosts.first(where: { MonitorInputs.same($0, owner) }) { return host }
        return m.hosts.count == 1 && onlyShowing != false ? m.hosts[0] : nil
    }

    private func tile(_ m: DeskMonitor, rect: CGRect, others: [CGRect], camera cam: MachineCanvasCamera) -> some View {
        let r = cam.viewportRect(rect)
        let current = Self.current(m, owner: inputs.owner(m.key),
                                   onlyShowing: m.hosts.count == 1 ? inputs.showing(m.key, machine: m.hosts[0]) : nil)
        let picture = current.flatMap { image($0, m.key) }
        let outlined = highlighted.map { h in m.hosts.contains { MonitorInputs.same($0, h) } } ?? false
        return ZStack {
            Rectangle().fill(MachineTone.tile)
            if let picture {
                Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: r.width, height: r.height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        // Tiles touch, so a host's outline stays inside the tile's own border.
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(outlined ? Palette.text.opacity(0.85) : MachineTone.tileEdge, lineWidth: outlined ? 1.5 : 1))
        .overlay(alignment: .bottomLeading) {
            if r.width > 70 && r.height > 32 {
                Text(m.model ?? m.key).font(Typo.body(11)).foregroundStyle(MachineTone.label).lineLimit(1).padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if r.width > 90 && r.height > 40 { strip(m, current: current).padding(5) }
        }
        .offset(x: r.minX, y: r.minY)
        .gesture(DragGesture(minimumDistance: 3).updating($gesturing) { _, s, _ in s = true }.onChanged { value in
            let start = dragStart ?? m.origin
            dragStart = start
            draft = (m.key, CGRect(origin: CGPoint(x: start.x + value.translation.width / cam.scale,
                                                   y: start.y + value.translation.height / cam.scale), size: m.size))
        }.onEnded { _ in
            defer { dragStart = nil }
            guard let moved = draft, moved.key == m.key else { return }
            // Edge to edge within 10 mm, or a dozen points when zoomed far out.
            let origin = MachineGeometry.snap(moved.rect, to: others, tolerance: max(10, 12 / cam.scale)).origin
            var map = Dictionary(desk.monitors.map { ($0.key, $0.origin) }, uniquingKeysWith: { a, _ in a })
            map[m.key] = origin
            store.set(map.mapValues { CGPoint(x: $0.x - desk.shift.x, y: $0.y - desk.shift.y) })
            draft = nil
        })
        .accessibilityLabel("\(m.model ?? m.key), drag to where it sits on the desk")
    }

    /// The hosts cabled to a monitor. The one on screen has the coral dot; a
    /// click on another switches to it when its input is known, else opens the menu.
    private func strip(_ m: DeskMonitor, current: String?) -> some View {
        let state = inputs.states[m.key]
        let live = state != nil || m.hosts.count == 1
        return HStack(spacing: 0) {
            ForEach(m.hosts, id: \.self) { host in
                let on = live && current.map { MonitorInputs.same($0, host) } == true
                if state != nil {
                    let flips = !on && MonitorInputs.code(of: host, in: inputs.map[m.key] ?? [:]) != nil
                    Group {
                        if flips {
                            Menu { MonitorInputMenu(inputs: inputs, key: m.key, machines: m.hosts) } label: { segment(host, on: on) }
                                primaryAction: { inputs.show(m.key, machine: host) }
                                .help("Show \(MonitorInputChip.title(host)) on this monitor")
                        } else {
                            Menu { MonitorInputMenu(inputs: inputs, key: m.key, machines: m.hosts) } label: { segment(host, on: on) }
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                } else {
                    segment(host, on: on)
                }
            }
        }
        .background(Capsule().fill(MachineTone.chip))
        .opacity(inputs.working.contains(m.key) ? 0.5 : 1)
    }

    private func segment(_ host: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            if on { Circle().fill(Long.coral).frame(width: 5, height: 5) }
            Text(MonitorInputChip.title(host)).font(Typo.mono(9)).foregroundStyle(on ? Palette.text : Palette.textDim).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 18)
        .contentShape(Rectangle())
    }

    // MARK: Chrome

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(hosts, id: \.self) { host in
                Button { pinned = pinned == host ? nil : host } label: {
                    HStack(spacing: 6) {
                        Text(MonitorInputChip.title(host)).font(Typo.body(11))
                            .foregroundStyle(highlighted == host ? Palette.text : Palette.textDim)
                        if desk.mismatches[host]?.isEmpty == false {
                            Text("arrangement differs").font(Typo.body(10)).foregroundStyle(Palette.textMuted)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { hovered = host } else if hovered == host { hovered = nil }
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var resetBar: some View {
        if desk.monitors.contains(where: { $0.source == .user }) {
            Button("Reset") { store.reset() }
                .font(Typo.body(11))
                .padding(.horizontal, 10).frame(height: 32)
                .background(Capsule().fill(MachineTone.chip))
                .overlay(Capsule().strokeBorder(MachineTone.chipEdge, lineWidth: Chrome.hairline))
                .help("Place every monitor from the hosts' arrangements again")
        }
    }

    private func zoomPill(_ cam: MachineCanvasCamera, bounds: CGRect, size: CGSize) -> some View {
        HStack(spacing: 0) {
            pillButton("minus", help: "Zoom out") { move(cam.zoomed(by: 0.8).clamped(to: bounds)) }
            Button { fit(bounds, size) } label: {
                Text("\(cam.percent)%").font(Typo.mono(10)).foregroundStyle(Palette.textDim)
                    .frame(width: 44, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Fit everything")
            pillButton("plus", help: "Zoom in") { move(cam.zoomed(by: 1.25).clamped(to: bounds)) }
        }
        .background(Capsule().fill(MachineTone.chip))
        .overlay(Capsule().strokeBorder(MachineTone.chipEdge, lineWidth: Chrome.hairline))
    }

    private func pillButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.textDim)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: Sources

    /// This Mac's monitors by display, read from EDID. Walks the registry, so
    /// callers keep the result rather than reading it per render.
    static func identities(_ screens: [VisitController.Screen]) -> [CGDirectDisplayID: MonitorIdentity] {
        var found: [CGDirectDisplayID: MonitorIdentity] = [:]
        for screen in screens where screen.displayID != 0 {
            if let identity = MonitorIdentity.forDisplay(screen.displayID), !identity.key.isEmpty { found[screen.displayID] = identity }
        }
        return found
    }

    /// The desk's inputs: this Mac first (as `MonitorInputs.here`, so it
    /// anchors the layout), then each machine's reported monitors.
    static func hosts(screens: [VisitController.Screen], identities: [CGDirectDisplayID: MonitorIdentity],
                      machines: [(name: String, monitors: [MachineArrangementStore.Monitor])]) -> [DeskLayout.Host] {
        let here = DeskLayout.Host(name: MonitorInputs.here, displays: screens.map { screen in
            if let identity = identities[screen.displayID] {
                return DeskLayout.Display(key: identity.key, model: identity.model, frame: screen.frame,
                                          widthMm: identity.widthMm, heightMm: identity.heightMm)
            }
            let builtin = MonitorIdentity.builtinSize(screen.displayID)
            return DeskLayout.Display(key: builtin == nil ? nil : builtinKey(MonitorInputs.here), model: builtin == nil ? nil : builtinModel,
                                      frame: screen.frame, widthMm: builtin.map { Int($0.width.rounded()) },
                                      heightMm: builtin.map { Int($0.height.rounded()) })
        })
        return [here] + machines.map { machine in
            DeskLayout.Host(name: machine.name, displays: machine.monitors.map {
                let builtin = $0.builtin == true && $0.key == nil
                return DeskLayout.Display(key: builtin ? builtinKey(machine.name) : $0.key, model: builtin ? builtinModel : $0.model,
                                          frame: $0.frame.rect, widthMm: $0.widthMm, heightMm: $0.heightMm)
            })
        }
    }

    /// A laptop's own screen is on the desk once, as that host's alone.
    static func builtinKey(_ host: String) -> String { "builtin|\(MachineInventory.key(host))" }
    static let builtinModel = "Built-in"
}

/// Desk or Hosts, over the Machines canvas.
struct MachinesCanvasModePicker: View {
    @Binding var mode: String

    var body: some View {
        HStack(spacing: 0) {
            segment("desk", "Desk")
            segment("hosts", "Hosts")
        }
        .padding(2)
        .background(Capsule().fill(MachineTone.chip))
        .overlay(Capsule().strokeBorder(MachineTone.chipEdge, lineWidth: Chrome.hairline))
    }

    private func segment(_ value: String, _ title: String) -> some View {
        Button { mode = value } label: {
            Text(title).font(Typo.body(11)).foregroundStyle(mode == value ? Palette.text : Palette.textDim)
                .padding(.horizontal, 10).frame(height: 22)
                .background(Capsule().fill(mode == value ? Color.white.opacity(0.1) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
