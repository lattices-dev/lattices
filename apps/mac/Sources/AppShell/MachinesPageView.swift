import AppKit
import HudsonUI
import SwiftUI
import UniformTypeIdentifiers

struct MachinesPageView: View {
    @ObservedObject private var hosts = RemoteHostsModel.shared
    @ObservedObject private var trial = DisplayArrangement.shared
    @ObservedObject private var inputs = MonitorInputs.shared
    @ObservedObject private var deskStore = DeskStore.shared
    @StateObject private var model = MachinesModel()
    @State private var selection: String?
    @State private var pairing = false
    @AppStorage("machines.canvas") private var canvasMode = "desk"
    /// This Mac's monitors, read on appear and when the displays change.
    @State private var identities: [CGDirectDisplayID: MonitorIdentity] = [:]

    private var machines: [MachineInventory.Machine] { model.machines(hosts.hosts) }
    private var selected: MachineInventory.Machine? { machines.first { $0.id == selection } ?? machines.first }

    var body: some View {
        GeometryReader { page in
            let machines = machines
            VStack(spacing: 0) {
                Group {
                    if canvasMode == "hosts" {
                        let bounds = MachineCanvasScene(screens: model.screens, machines: machines, monitors: { MachineCanvasScene.monitors($0) }).bounds
                        MachineArrangementCanvas(model: model, machines: machines,
                                                 selection: Binding(get: { selected?.id }, set: { selection = $0 }),
                                                 onlineNames: Set(hosts.hosts.filter { $0.status == .online }.map(\.name)))
                            .frame(height: MachineCanvasCamera.bandHeight(content: bounds, width: page.size.width - Chrome.inset * 2, available: page.size.height))
                    } else {
                        let desk = desk(machines)
                        DeskCanvas(desk: desk, image: { host, key in image(host, key, machines) }, inputs: inputs, store: deskStore)
                            .frame(height: MachineCanvasCamera.bandHeight(content: desk.bounds, width: page.size.width - Chrome.inset * 2,
                                                                          available: page.size.height) + DeskCanvas.legendHeight)
                    }
                }
                .overlay(alignment: .topTrailing) { MachinesCanvasModePicker(mode: $canvasMode).padding(10) }
                .padding([.horizontal, .top], Chrome.inset)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(Set([model.error, trial.error, inputs.error].compactMap { $0 })).sorted(), id: \.self) { error in
                            Text(error).font(Typo.body(11)).foregroundStyle(Palette.text).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10).outlinedBox()
                        }
                        machineList(machines)
                        if let selected { inspector(selected) }
                        thisMac
                    }
                    .padding(Chrome.inset)
                }
            }
        }
        .font(Typo.body(11))
        .foregroundStyle(Palette.text)
        .tint(Palette.textDim)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .background(PanelBackground())
        .pageActions(pageActions)
        .onAppear { hosts.retain(); model.appear(); inputs.appear(); identities = DeskCanvas.identities(model.screens) }
        .onChange(of: model.screens.map(\.displayID)) { _, _ in identities = DeskCanvas.identities(model.screens) }
        // Hosts report their monitors after they connect; read each once as it arrives.
        .onChange(of: hosts.hosts.map { "\($0.name):\($0.status == .online):\($0.monitors.compactMap(\.key))" }) { _, _ in inputs.readNew() }
        .onDisappear { model.disappear(); hosts.release() }
        .onReceive(NotificationCenter.default.publisher(for: VisitController.changed)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refresh(); inputs.refreshLocal(); inputs.readNew()
        }
        .sheet(isPresented: $pairing) { MachinePairSheet { model.refresh(); hosts.reload() } }
    }

    private var pageActions: [PageAction] {
        var actions = [
            PageAction(id: "machines-add", title: "Add machine", icon: "plus") { pairing = true },
            PageAction(id: "machines-arm", title: model.visit.armed ? "Disarm visiting" : "Arm visiting",
                       isEnabled: !model.visit.hosts.isEmpty || model.visit.armed) {
                VisitController.shared.arm(!model.visit.armed)
            },
        ]
        if model.visit.visiting != nil {
            actions.append(PageAction(id: "machines-end-visit", title: "End visit") { VisitController.shared.end(because: "ended") })
        }
        actions.append(PageAction(id: "machines-refresh", title: "Refresh", icon: "arrow.clockwise") {
            model.refresh()
            inputs.readAll()
            for host in hosts.hosts {
                if host.status == .online { hosts.refresh(host.name) } else { hosts.reconnect(host.name) }
            }
        })
        return actions
    }

    // MARK: Desk

    private func desk(_ machines: [MachineInventory.Machine]) -> Desk {
        DeskLayout.stitch(hosts: DeskCanvas.hosts(screens: model.screens, identities: identities,
                                                  machines: machines.map { ($0.name, MachineCanvasScene.monitors($0)) }),
                          origins: deskStore.origins)
    }
    /// The picture a remote host last sent of that monitor; this Mac draws none.
    private func image(_ host: String, _ key: String, _ machines: [MachineInventory.Machine]) -> NSImage? {
        guard let machine = machines.first(where: { $0.name == host }), let remote = remoteHost(machine),
              let index = remote.monitors.firstIndex(where: { $0.key == key || ($0.key == nil && $0.builtin == true && key == DeskCanvas.builtinKey(host)) })
        else { return nil }
        return remote.thumbnails[index] ?? (index == 0 ? remote.still : nil)
    }

    private func section<Content: View, Accessory: View>(_ title: String, count: Int? = nil,
                                                         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
                                                         @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Typo.heading(13))
                if let count { Text("\(count)").font(Typo.mono(11)).foregroundStyle(Palette.textMuted) }
                Spacer(minLength: 0)
                accessory()
            }
            content()
        }
    }

    // MARK: Machines

    private func machineList(_ machines: [MachineInventory.Machine]) -> some View {
        section("Machines", count: machines.count) {
            VStack(spacing: 2) {
                if machines.isEmpty {
                    Text("No machines").foregroundStyle(Palette.textMuted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                }
                ForEach(machines) { machine in
                    let host = remoteHost(machine)
                    MachineRow(name: machine.name, address: machine.address, status: status(machine),
                        build: build(machine).label,
                        visiting: model.visit.visiting == machine.visit?.name && machine.visit != nil,
                        selected: selected?.id == machine.id,
                        canVisit: machine.visit.map { _ in model.visit.visiting == nil },
                        canView: host.map { $0.status == .online && $0.capabilities.contains("capture.still") } ?? false,
                        select: { selection = machine.id },
                        visit: { model.perform("visit.start", .object(["host": .string(machine.name)])) },
                        view: {
                            guard let host else { return }
                            RemoteViewerWindows.shared.show(host, target: .display(index: 0, name: host.monitors.first?.name ?? "Display"))
                        })
                }
            }
        }
    }
    private func remoteHost(_ machine: MachineInventory.Machine) -> RemoteHostsModel.Host? {
        machine.remote.flatMap { name in hosts.hosts.first { $0.name == name } }
    }
    private func build(_ machine: MachineInventory.Machine) -> MachineBuild {
        remoteHost(machine)?.build ?? model.builds[machine.name] ?? MachineBuild([:])
    }
    private func status(_ machine: MachineInventory.Machine) -> String {
        if let host = remoteHost(machine), host.status == .online { return "Reachable" }
        if let visit = machine.visit {
            return model.reachable[visit.name].map { $0 ? "Reachable" : "Unreachable" } ?? "Checking"
        }
        if let host = remoteHost(machine) {
            return host.status == .connecting ? "Connecting" : "Unreachable"
        }
        return "Unknown"
    }

    /// The selected machine: who it is, and its windows to open one by one.
    private func inspector(_ machine: MachineInventory.Machine) -> some View {
        let host = remoteHost(machine)
        return section(machine.name) {
            if let visit = machine.visit {
                Text(visit.bridgeFingerprint).font(Typo.mono(10)).foregroundStyle(Palette.textMuted).textSelection(.enabled)
                Button("Forget") { model.forget(visit.name) }
            }
        } content: {
            if let host { MachineHostDetail(host: host) }
        }
    }

    // MARK: This Mac

    private var thisMac: some View {
        section("This Mac", count: model.screens.count) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.screens, id: \.number) { screen in
                    HStack(spacing: 10) {
                        Text("\(screen.number) · \(screen.name)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Int(screen.frame.width)) × \(Int(screen.frame.height))").font(Typo.mono(10)).foregroundStyle(Palette.textDim)
                        Button("Bring everything here") { model.perform("bring", displayParams(screen)) }.frame(width: 140)
                        Button("Make main") { model.perform("main", displayParams(screen)) }
                            .opacity(screen.main ? 0 : 1).disabled(screen.main || trial.pending)
                            .frame(width: 80)
                        Toggle("Elsewhere", isOn: Binding(get: { screen.elsewhere }, set: {
                            model.perform($0 ? "elsewhere" : "here", displayParams(screen))
                        })).toggleStyle(.checkbox).frame(width: 90, alignment: .leading)
                    }
                    .padding(.horizontal, 8).frame(height: 32)
                }
                #if LATTICES_BUNDLE
                Toggle("Let other machines visit this Mac", isOn: Binding(
                    get: { MacVisitHost.enabled }, set: { MacVisitHost.setEnabled($0); model.refresh() }
                )).toggleStyle(.checkbox).padding(.horizontal, 8).padding(.top, 8)
                #endif
            }
        }
    }
    private func displayParams(_ screen: VisitController.Screen) -> JSON {
        .object(["display": .int(screen.number)])
    }
}

private struct MachinePairSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var kind = "both"
    @State private var waiting = false
    @State private var error: String?
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add machine").font(Typo.heading(15))
            TextField("Name", text: $name).disabled(waiting)
            TextField("Bridge address · host:9399", text: $address).disabled(waiting)
            Picker("Type", selection: $kind) {
                Text("Lattices host").tag("host")
                Text("Visit host").tag("visit")
                Text("Both").tag("both")
            }.disabled(waiting)
            if waiting {
                Text("Approve code on \(name)").font(Typo.body(12))
                Text(VisitTrust.shared.fingerprint).font(Typo.mono(14)).textSelection(.enabled)
                ProgressView().controlSize(.small)
            }
            if let error { Text(error).font(Typo.body(11)).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(waiting).keyboardShortcut(.cancelAction)
                Button("Add") { pair() }.keyboardShortcut(.defaultAction)
                    .disabled(waiting || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .interactiveDismissDisabled(waiting)
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 360)
        .foregroundStyle(Palette.text).tint(Palette.textDim)
    }
    private func pair() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let side = VisitTrust.Side.right
        let target = address.isEmpty ? name : address
        guard let base = VisitTrust.bridgeURL(target), let hostname = base.host,
              let port = UInt16(exactly: base.port ?? 9399), port > 0 else { error = "Invalid address"; return }
        if kind != "visit" {
            do {
                try MachineArrangementStore.addHost(name: name, address: hostname, port: kind == "host" ? port : 9399)
                RemoteHostsModel.shared.reload()
            } catch { self.error = String(describing: error); return }
        }
        if kind == "host" { done(); dismiss(); return }
        var bridge = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        bridge.port = base.port ?? 9399
        let bridgeAddress = String(bridge.url!.absoluteString.dropFirst("http://".count))
        waiting = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = VisitTrust.shared.pair(name: name, address: bridgeAddress, side: side)
            DispatchQueue.main.async {
                waiting = false
                switch result {
                case .success: done(); dismiss()
                case .failure(let failure): error = failure.description
                }
            }
        }
    }
}

/// Two lines at a fixed height: who and where, then state and build. The
/// Visit slot is reserved on every row so the buttons line up.
struct MachineRow: View {
    let name: String
    let address: String
    let status: String
    let build: String
    let visiting: Bool
    let selected: Bool
    /// Nil when the machine isn't paired for visits.
    let canVisit: Bool?
    let canView: Bool
    let select: () -> Void
    let visit: () -> Void
    let view: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: select) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text(name).font(Typo.heading(12))
                        Text(address).font(Typo.mono(10)).foregroundStyle(Palette.textMuted)
                    }
                    HStack(spacing: 10) {
                        Text(visiting ? "Visiting" : status).foregroundStyle(visiting ? Long.coral : Palette.textDim)
                        Text(build).font(Typo.mono(10)).foregroundStyle(Palette.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button("Visit", action: visit).disabled(canVisit != true).opacity(canVisit == nil ? 0 : 1).frame(width: 52)
            Button("View", action: view).disabled(!canView).frame(width: 52)
        }
        .font(Typo.body(11)).lineLimit(1)
        .padding(.horizontal, 8).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Palette.surface : hovering ? Palette.surface.opacity(0.5) : .clear))
        .onHover { hovering = $0 }
    }
}
