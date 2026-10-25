import AppKit
import SwiftUI

/// Where everything sits in the world: this Mac's displays at their CG
/// frames, each other machine as a group of its monitors. Drafts win over
/// stored placements so a drag shows where it will land.
struct MachineCanvasScene {
    struct Node: Identifiable {
        var machine: MachineInventory.Machine
        var rect: CGRect
        var monitors: [MachineArrangementStore.Monitor]
        /// The union of the monitors in the host's own layout coordinates.
        var local: CGRect
        var id: String { machine.id }

        /// Each monitor's rectangle in the world.
        func tiles() -> [CGRect] {
            let k = min(rect.width / max(local.width, 1), rect.height / max(local.height, 1))
            return monitors.map { m in
                let f = m.frame.rect
                return CGRect(x: rect.minX + (f.minX - local.minX) * k, y: rect.minY + (f.minY - local.minY) * k,
                              width: f.width * k, height: f.height * k)
            }
        }
    }

    var screens: [(screen: VisitController.Screen, rect: CGRect)]
    var nodes: [Node]

    var bounds: CGRect { (screens.map(\.rect) + nodes.map(\.rect)).reduce(CGRect.null) { $0.union($1) } }
    /// Changes when something is added or removed, not when something moves.
    var signature: String { "\(screens.count)|" + nodes.map { "\($0.id):\($0.monitors.count)" }.joined(separator: ",") }

    init(screens: [VisitController.Screen], machines: [MachineInventory.Machine],
         monitors: (MachineInventory.Machine) -> [MachineArrangementStore.Monitor],
         placement: (MachineInventory.Machine) -> CGRect? = { $0.visit?.placement?.rect ?? MachineArrangementStore.placement($0.name)?.rect },
         screenDraft: [CGDirectDisplayID: CGRect] = [:], machineDraft: [String: CGRect] = [:]) {
        let placed = screens.map { (screen: $0, rect: screenDraft[$0.displayID] ?? $0.frame) }
        self.screens = placed
        let resolved = machines.map { m -> (MachineInventory.Machine, [MachineArrangementStore.Monitor], CGRect, CGRect?) in
            let found = monitors(m)
            let list = found.isEmpty ? [MachineArrangementStore.Monitor(name: "Display", frame: .init(x: 0, y: 0))] : found
            let local = list.reduce(CGRect.null) { $0.union($1.frame.rect) }
            let rect: CGRect?
            if let r = machineDraft[m.id] { rect = r }
            else if let p = placement(m) { rect = CGRect(origin: p.origin, size: local.size) }
            else if let s = placed.first(where: { $0.screen.elsewhere && $0.screen.machine == m.name }) { rect = s.rect }
            else { rect = nil }
            return (m, list, local, rect)
        }
        // Unplaced machines queue to the right of everything placed, a gap apart.
        let taken = (placed.map(\.rect) + resolved.compactMap(\.3)).reduce(CGRect.null) { $0.union($1) }
        let origin = taken.isNull ? CGPoint.zero : CGPoint(x: taken.maxX + 600, y: taken.minY)
        var y = origin.y
        self.nodes = resolved.map { m, list, local, rect in
            let r = rect ?? CGRect(x: origin.x, y: y, width: local.width, height: local.height)
            if rect == nil { y += local.height + 300 }
            return Node(machine: m, rect: r, monitors: list, local: local)
        }
    }

    static func monitors(_ m: MachineInventory.Machine, fixtures: [String: [MachineArrangementStore.Monitor]]? = nil) -> [MachineArrangementStore.Monitor] {
        fixtures?[m.name] ?? MachineArrangementStore.monitors(m.visit?.name ?? m.remote ?? m.name)
    }
}

/// The arrangement as a canvas: pan, zoom, drag displays and machines into
/// place, and open any remote monitor (or a piece of one) in the viewer.
struct MachineArrangementCanvas: View {
    @ObservedObject var model: MachinesModel
    var machines: [MachineInventory.Machine]
    @Binding var selection: String?
    var monitorFixtures: [String: [MachineArrangementStore.Monitor]]? = nil
    var onlineNames: Set<String> = []
    /// Off for offline renders, which can't draw AppKit views.
    var trackpad = true
    @ObservedObject private var trial = DisplayArrangement.shared
    @ObservedObject private var remote = RemoteHostsModel.shared
    @ObservedObject private var inputs = MonitorInputs.shared
    @State private var camera: MachineCanvasCamera?
    @State private var panStart: CGSize?
    @State private var hovered: String?
    @State private var draft: [CGDirectDisplayID: CGRect] = [:]
    @State private var machineDraft: [String: CGRect] = [:]
    @State private var dragStart: CGRect?
    /// A rectangle being dragged across one monitor, in world points.
    @State private var region: (node: String, tile: Int, rect: CGRect)?
    /// False once the user pans or zooms; resizes and new machines then keep their view.
    @State private var fitted = true
    /// Resets when a drag ends or is cancelled, so stale drag state can't outlive it.
    @GestureState private var gesturing = false

    private var scene: MachineCanvasScene {
        MachineCanvasScene(screens: model.shownScreens, machines: machines,
                           monitors: { MachineCanvasScene.monitors($0, fixtures: monitorFixtures) },
                           screenDraft: draft, machineDraft: machineDraft)
    }
    private var dragging: Bool { dragStart != nil || region != nil || panStart != nil }

    var body: some View {
        GeometryReader { proxy in
            let scene = scene
            let cam = camera ?? .fitting(scene.bounds, in: proxy.size)
            ZStack(alignment: .topLeading) {
                MachineCanvasGrid(camera: cam)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { fit(scene, proxy.size) }
                    .gesture(DragGesture(minimumDistance: 3).updating($gesturing) { _, s, _ in s = true }.onChanged { value in
                        let start = panStart ?? cam.pan
                        panStart = start
                        var next = cam
                        next.pan = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                        move(next.clamped(to: scene.bounds))
                    }.onEnded { _ in panStart = nil })
                ForEach(scene.screens, id: \.screen.displayID) { item in
                    display(item.screen, rect: item.rect, scene: scene, camera: cam)
                }
                ForEach(scene.nodes) { node in
                    machine(node, scene: scene, camera: cam)
                }
                if let region {
                    let r = cam.viewportRect(region.rect.standardized)
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(Palette.text.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                }
                if trackpad { CanvasScrollInput(
                    // Events can outrun renders, so build on the live camera.
                    // A drag maps translation through one camera, so hold still during it.
                    onPan: { delta in if !dragging { move((camera ?? cam).panned(by: delta).clamped(to: scene.bounds)) } },
                    onZoom: { factor, anchor in if !dragging { move((camera ?? cam).zoomed(by: factor, around: anchor).clamped(to: scene.bounds)) } })
                    .allowsHitTesting(false) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .overlay(alignment: .bottomTrailing) { zoomPill(cam, scene: scene, size: proxy.size).padding(10) }
            .overlay(alignment: .bottomLeading) { arrangementBar.padding(10) }
            .onAppear { if camera == nil { fit(scene, proxy.size) } }
            .onChange(of: proxy.size) { _, size in refit(scene, size) }
            .onChange(of: scene.signature) { _, _ in refit(scene, proxy.size) }
            .onChange(of: gesturing) { _, active in
                guard !active else { return }
                dragStart = nil; region = nil; panStart = nil; machineDraft = [:]
            }
        }
        .background(MachineTone.well)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MachineTone.wellEdge, lineWidth: 1))
        .onChange(of: trial.pending) { _, pending in if !pending { draft = [:]; model.refresh() } }
    }

    private func fit(_ scene: MachineCanvasScene, _ size: CGSize) {
        guard !dragging, size.width > 0, size.height > 0 else { return }
        camera = .fitting(scene.bounds, in: size)
        fitted = true
    }

    /// Follows the content while the view is fitted; after the user has moved
    /// it, keeps their pan and zoom and only rebases 100% on the new fit.
    private func refit(_ scene: MachineCanvasScene, _ size: CGSize) {
        guard !fitted, var next = camera, size.width > 0, size.height > 0 else { return fit(scene, size) }
        next.viewport = size
        next.fitScale = MachineCanvasCamera.fitting(scene.bounds, in: size).fitScale
        camera = next.clamped(to: scene.bounds)
    }

    private func move(_ next: MachineCanvasCamera) {
        camera = next
        fitted = false
    }

    // MARK: This Mac

    private func display(_ screen: VisitController.Screen, rect: CGRect, scene: MachineCanvasScene, camera cam: MachineCanvasCamera) -> some View {
        let r = cam.viewportRect(rect)
        let label = screen.main && !screen.elsewhere ? "This Mac" : screen.name
        let key = inputs.local[screen.displayID]
        let away = inputs.showing(key, machine: MonitorInputs.here) == false
        let hidden = model.showVirtual ? [] : model.screens.filter(\.virtual)
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(MachineTone.tile)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(MachineTone.tileEdge, style: StrokeStyle(lineWidth: 1, dash: away || screen.virtual ? [4, 3] : [])))
            .overlay(alignment: .bottomLeading) {
                if r.width > 70 && r.height > 32 {
                    Text(label).font(Typo.body(11)).foregroundStyle(MachineTone.label).lineLimit(1).padding(6)
                }
            }
            .frame(width: r.width, height: r.height)
            .opacity(screen.elsewhere ? MachineTone.away : 1)
            .overlay(alignment: .topTrailing) {
                if r.width > 90, r.height > 40 {
                    // DDC says which input is on; otherwise the user does.
                    if let key, inputs.states[key] != nil {
                        MonitorInputChip(inputs: inputs, key: key, machine: MonitorInputs.here, machines: assignable).padding(5)
                    } else if !screen.virtual, !(screen.main && !screen.elsewhere), MonitorIdentity.builtinSize(screen.displayID) == nil {
                        DisplayShowingChip(screen: screen, machines: assignable) { model.show(screen, machine: $0) }.padding(5)
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if screen.main, !hidden.isEmpty, r.width > 160, r.height > 40 {
                    Button { model.showVirtual = true } label: {
                        Text(hidden.count == 1 ? "+ \(hidden[0].name)" : "+ \(hidden.count) virtual")
                            .font(Typo.mono(9)).foregroundStyle(Palette.textDim).lineLimit(1)
                            .padding(.horizontal, 6).frame(height: 18)
                            .background(Capsule().fill(MachineTone.chip))
                    }
                    .buttonStyle(.plain).padding(5)
                    .help("Virtual displays are hidden; click to show them")
                }
            }
            .offset(x: r.minX, y: r.minY)
            .gesture(DragGesture().updating($gesturing) { _, s, _ in s = true }.onChanged { value in
                guard !trial.pending else { return }
                let start = dragStart ?? rect
                dragStart = start
                draft[screen.displayID] = start.offsetBy(dx: value.translation.width / cam.scale, dy: value.translation.height / cam.scale)
            }.onEnded { _ in
                defer { dragStart = nil }
                guard !trial.pending else { return }
                let others = scene.screens.filter { $0.screen.displayID != screen.displayID }.map(\.rect)
                draft[screen.displayID] = MachineGeometry.snap(draft[screen.displayID] ?? rect, to: others, tolerance: 18 / cam.scale)
            })
            .accessibilityLabel("\(screen.name), drag to rearrange; Apply commits changes")
    }

    // MARK: Other machines

    private func host(_ m: MachineInventory.Machine) -> RemoteHostsModel.Host? {
        remote.hosts.first { $0.name == (m.remote ?? m.name) }
    }
    private func viewable(_ host: RemoteHostsModel.Host?) -> Bool {
        host.map { $0.status == .online && $0.capabilities.contains("capture.still") } ?? false
    }
    private func placed(_ rect: CGRect, scene: MachineCanvasScene) -> Bool {
        scene.screens.contains { !MachineGeometry.contacts(display: $0.rect, machine: rect).isEmpty || ($0.screen.elsewhere && $0.rect == rect) }
    }

    private func machine(_ node: MachineCanvasScene.Node, scene: MachineCanvasScene, camera cam: MachineCanvasCamera) -> some View {
        let m = node.machine
        let r = cam.viewportRect(node.rect)
        let tiles = node.tiles()
        let online = model.reachable[m.name] == true || onlineNames.contains(m.remote ?? m.name)
        let visiting = m.visit != nil && model.visit.visiting == m.visit?.name
        let selected = selection == m.id
        let locked = !draft.isEmpty || trial.pending
        return ZStack(alignment: .topLeading) {
            ForEach(Array(node.monitors.enumerated()), id: \.offset) { index, monitor in
                let t = cam.viewportRect(tiles[index])
                remoteMonitor(node, index: index, monitor: monitor, size: t.size)
                    .offset(x: t.minX - r.minX, y: t.minY - r.minY)
            }
            if r.width > 64 {
                Text(m.name).font(Typo.heading(11)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().fill(MachineTone.chip))
                    .foregroundStyle(visiting ? Long.coral : Palette.text)
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: r.width, height: r.height, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.text.opacity(selected ? 0.7 : 0), lineWidth: 1)
                .padding(-4)
        }
        .contentShape(Rectangle())
        .opacity(placed(node.rect, scene: scene) && online ? 1 : MachineTone.offline)
        .offset(x: r.minX, y: r.minY)
        .onTapGesture { selection = m.id }
        .gesture(DragGesture().updating($gesturing) { _, s, _ in s = true }.onChanged { value in
            guard !locked else { return }
            if dragStart == nil, region == nil {
                // ⌥-drag across a monitor frames a piece of it to view.
                if NSEvent.modifierFlags.contains(.option), viewable(host(m)) {
                    // The gesture sits outside .offset, so its points are viewport points.
                    let at = cam.worldPoint(value.startLocation)
                    if let tile = tiles.firstIndex(where: { $0.contains(at) }) { region = (m.id, tile, .zero) }
                }
                if region == nil { dragStart = node.rect; selection = m.id }
            }
            if let current = region {
                let a = cam.worldPoint(value.startLocation)
                region = (current.node, current.tile, CGRect(x: a.x, y: a.y, width: value.translation.width / cam.scale, height: value.translation.height / cam.scale))
            } else if let start = dragStart {
                machineDraft[m.id] = start.offsetBy(dx: value.translation.width / cam.scale, dy: value.translation.height / cam.scale)
            }
        }.onEnded { _ in
            if let current = region {
                region = nil
                let monitor = node.monitors[current.tile]
                if let host = host(m), let rect = MachineCanvasCamera.hostRegion(current.rect, tile: tiles[current.tile], monitor: monitor.frame.rect) {
                    RemoteViewerWindows.shared.show(host, target: .region(rect))
                }
                return
            }
            guard dragStart != nil else { return }
            dragStart = nil
            guard !locked else { machineDraft.removeValue(forKey: m.id); return }
            drop(m, at: machineDraft[m.id] ?? node.rect, size: node.local.size, scene: scene, scale: cam.scale)
        })
        .help(locked ? "Apply or revert the display arrangement first" : "Drag to place · ⌥-drag to view part of a monitor")
        .accessibilityLabel("\(m.name), drag to place")
    }

    /// `size` is the machine's own: a drag that starts on an Elsewhere screen
    /// carries that screen's size, which must not be stored as the machine's.
    private func drop(_ m: MachineInventory.Machine, at rect: CGRect, size: CGSize, scene: MachineCanvasScene, scale: CGFloat) {
        var placed = rect
        let elsewhere = scene.screens.first { $0.screen.elsewhere && $0.rect.contains(CGPoint(x: rect.midX, y: rect.midY)) }
        if let elsewhere { placed = elsewhere.rect }
        else {
            let own = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            placed = MachineGeometry.snap(own, to: scene.screens.map(\.rect), tolerance: 18 / scale)
        }
        do {
            try MachineArrangementStore.place(m.name, placed)
            for s in model.screens where s.machine == m.name { _ = VisitController.shared.setDisplayMachine(s.number, name: nil) }
            if let elsewhere { _ = VisitController.shared.setDisplayMachine(elsewhere.screen.number, name: m.name) }
            model.error = nil
            model.refresh()
        } catch { model.error = String(describing: error) }
        machineDraft.removeValue(forKey: m.id)
    }

    /// A monitor on another machine, showing what is on it when the host can
    /// send pictures. Double-click, or the eye on hover, opens the viewer.
    private func remoteMonitor(_ node: MachineCanvasScene.Node, index: Int, monitor: MachineArrangementStore.Monitor, size: CGSize) -> some View {
        let host = host(node.machine)
        let image = host?.thumbnails[index] ?? (index == 0 ? host?.still : nil)
        let canView = viewable(host)
        let key = "\(node.id)#\(index)"
        let hovering = hovered == key && canView
        func open() { if let host, canView { RemoteViewerWindows.shared.show(host, target: .display(index: index, name: monitor.name)) } }
        // Cabled here but showing another machine: same tile, still viewable.
        let away = inputs.showing(monitor.key, machine: node.machine.name) == false
        return ZStack {
            Rectangle().fill(MachineTone.backing)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .opacity(away ? MachineTone.away : 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(hovering ? Palette.text.opacity(0.6) : MachineTone.tileEdge, style: StrokeStyle(lineWidth: 1, dash: away ? [4, 3] : [])))
        .overlay(alignment: .topTrailing) {
            if let key = monitor.key, size.width > 90, size.height > 40 {
                MonitorInputChip(inputs: inputs, key: key, machine: node.machine.name, machines: assignable).padding(5)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if node.monitors.count > 1, size.width > 120, size.height > 48 {
                Text(monitor.name).font(Typo.mono(9)).foregroundStyle(Palette.textDim).lineLimit(1)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(MachineTone.chip))
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if hovering, size.width > 40, size.height > 28 {
                Button(action: open) {
                    Image(systemName: "eye").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.text)
                        .frame(width: 22, height: 18)
                        .background(Capsule().fill(MachineTone.chip))
                }
                .buttonStyle(.plain).padding(5)
                .help("View \(monitor.name) on \(node.machine.name)")
            }
        }
        .onHover { inside in
            if inside { hovered = key } else if hovered == key { hovered = nil }
        }
        .onTapGesture(count: 2, perform: open)
    }

    /// Who an input can belong to: this Mac and every machine on the canvas.
    private var assignable: [String] { [MonitorInputs.here] + machines.map(\.name) }

    // MARK: Chrome

    @ViewBuilder private var arrangementBar: some View {
        if trial.pending || !draft.isEmpty {
            HStack(spacing: 8) {
                if trial.pending {
                    Text("Keep this arrangement? Reverts in 15 s").foregroundStyle(Palette.textDim)
                    Button("Revert") { trial.revert(); draft = [:] }
                    Button("Keep") { trial.keep(); draft = [:] }
                } else {
                    Button("Revert") { draft = [:] }
                    Button("Apply") {
                        do { model.error = nil; try trial.apply(Dictionary(uniqueKeysWithValues: model.screens.map { ($0.displayID, draft[$0.displayID] ?? $0.frame) })) }
                        catch { model.error = String(describing: error) }
                    }
                }
            }
            .font(Typo.body(11))
            .padding(.horizontal, 10).frame(height: 32)
            .background(Capsule().fill(MachineTone.chip))
            .overlay(Capsule().strokeBorder(MachineTone.chipEdge, lineWidth: Chrome.hairline))
        }
    }

    private func zoomPill(_ cam: MachineCanvasCamera, scene: MachineCanvasScene, size: CGSize) -> some View {
        HStack(spacing: 0) {
            pillButton("minus", help: "Zoom out") { move(cam.zoomed(by: 0.8).clamped(to: scene.bounds)) }
            Button { fit(scene, size) } label: {
                Text("\(cam.percent)%").font(Typo.mono(10)).foregroundStyle(Palette.textDim)
                    .frame(width: 44, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Fit everything")
            pillButton("plus", help: "Zoom in") { move(cam.zoomed(by: 1.25).clamped(to: scene.bounds)) }
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
}

/// Which machine a display without DDC shows, as the user says: picking another
/// machine marks it Elsewhere and names it, This Mac brings it back.
struct DisplayShowingChip: View {
    let screen: VisitController.Screen
    let machines: [String]
    let choose: (String) -> Void

    var body: some View {
        let current = screen.elsewhere ? screen.machine : MonitorInputs.here
        let mine = current == MonitorInputs.here
        Menu {
            Section("Showing") {
                ForEach(machines, id: \.self) { machine in
                    Button { choose(machine) } label: {
                        if machine == current { Label(MonitorInputChip.title(machine), systemImage: "checkmark") }
                        else { Text(MonitorInputChip.title(machine)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(mine ? Long.coral : Palette.textMuted).frame(width: 5, height: 5)
                Text(current.map(MonitorInputChip.title) ?? "Elsewhere")
                    .font(Typo.mono(9)).foregroundStyle(mine ? Palette.text : Palette.textDim).lineLimit(1)
            }
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(MachineTone.chip))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Which machine \(screen.name) is showing")
    }
}

/// Which machine a shared monitor shows. The dot is coral on the tile of the
/// machine on screen; clicking another machine's tile switches the input to it.
struct MonitorInputChip: View {
    @ObservedObject var inputs: MonitorInputs
    let key: String
    let machine: String
    let machines: [String]

    var body: some View {
        if let state = inputs.states[key] {
            let owner = inputs.owner(key)
            let mine = owner == machine
            Group {
                // Off screen with a known input: a click switches to it, a hold opens the menu.
                if !mine, inputs.map[key]?[machine] != nil {
                    Menu { MonitorInputMenu(inputs: inputs, key: key, machines: machines) } label: { label(state, owner: owner, mine: mine) }
                        primaryAction: { inputs.show(key, machine: machine) }
                        .help("Show \(Self.title(machine)) on this monitor")
                } else {
                    Menu { MonitorInputMenu(inputs: inputs, key: key, machines: machines) } label: { label(state, owner: owner, mine: mine) }
                        .help(owner.map { "Showing \(Self.title($0))" } ?? "Which machine is on this input?")
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func label(_ state: MonitorInputs.State, owner: String?, mine: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(mine ? Long.coral : Palette.textMuted).frame(width: 5, height: 5)
            Text(mine ? (state.input?.name ?? "") : owner.map(Self.title) ?? state.input?.name ?? "")
                .font(Typo.mono(9)).foregroundStyle(mine ? Palette.text : Palette.textDim).lineLimit(1)
        }
        .padding(.horizontal, 6).frame(height: 18)
        .background(Capsule().fill(MachineTone.chip))
        .opacity(inputs.working.contains(key) ? 0.5 : 1)
    }

    static func title(_ machine: String) -> String { machine == MonitorInputs.here ? "This Mac" : machine }
}

/// The input menu: switch to any input, and say which machine the current one is.
struct MonitorInputMenu: View {
    @ObservedObject var inputs: MonitorInputs
    let key: String
    let machines: [String]

    var body: some View {
        if let state = inputs.states[key] {
            let owner = inputs.owner(key)
            let map = inputs.map[key] ?? [:]
            let codes = state.inputs.isEmpty ? Array(Set(map.values)).sorted().map { MonitorDDC.Input(code: $0) } : state.inputs
            Section("Switch to") {
                ForEach(codes, id: \.code) { input in
                    let who = MonitorInputs.owner(of: input.code, in: map)
                    Toggle(who.map { "\(input.name) · \(MonitorInputChip.title($0))" } ?? input.name, isOn: Binding(
                        get: { state.input?.code == input.code },
                        set: { _ in inputs.show(key, input: input.code) }))
                }
            }
            if let current = state.input {
                Section("\(current.name) is") {
                    ForEach(machines, id: \.self) { m in
                        Toggle(MonitorInputChip.title(m), isOn: Binding(get: { owner == m }, set: { _ in inputs.assign(key, machine: m) }))
                    }
                }
            }
        }
    }
}

/// A dot grid that moves with the camera. The step doubles or halves so dots
/// stay 12–48 points apart at any zoom; every fifth is brighter.
struct MachineCanvasGrid: View {
    var camera: MachineCanvasCamera

    var body: some View {
        Canvas { context, size in
            var step: CGFloat = 100
            while step * camera.scale < 12 { step *= 2 }
            while step * camera.scale > 48 { step /= 2 }
            let s = step * camera.scale
            let first = camera.worldPoint(.zero)
            let i0 = Int((first.x / step).rounded(.down)), j0 = Int((first.y / step).rounded(.down))
            let columns = Int(size.width / s) + 2, rows = Int(size.height / s) + 2
            guard columns * rows < 40_000 else { return }
            var minor = Path(), major = Path()
            for i in i0..<(i0 + columns) {
                for j in j0..<(j0 + rows) {
                    let p = camera.viewportPoint(CGPoint(x: CGFloat(i) * step, y: CGFloat(j) * step))
                    let dot = CGRect(x: p.x - 0.75, y: p.y - 0.75, width: 1.5, height: 1.5)
                    if i % 5 == 0 && j % 5 == 0 { major.addEllipse(in: dot.insetBy(dx: -0.25, dy: -0.25)) } else { minor.addEllipse(in: dot) }
                }
            }
            context.fill(minor, with: .color(MachineTone.gridMinor))
            context.fill(major, with: .color(MachineTone.gridMajor))
        }
    }
}
