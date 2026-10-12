import AppKit
import SwiftUI

struct MachineArrangementCanvas: View {
    @ObservedObject var model: MachinesModel
    var machines: [MachineInventory.Machine]
    var monitorFixtures: [String: [MachineArrangementStore.Monitor]]? = nil
    var onlineNames: Set<String> = []
    @ObservedObject private var trial = DisplayArrangement.shared
    @State private var draft: [CGDirectDisplayID: CGRect] = [:]
    @State private var moving: String?
    @State private var start: CGRect = .zero
    @State private var machineDraft: [String: CGRect] = [:]
    @State private var fixedBounds: CGRect?

    private func screenRect(_ s: VisitController.Screen) -> CGRect { draft[s.displayID] ?? s.frame }
    private func monitors(_ m: MachineInventory.Machine) -> [MachineArrangementStore.Monitor] {
        let cached = monitorFixtures?[m.name] ?? MachineArrangementStore.monitors(m.visit?.name ?? m.remote ?? m.name)
        return cached.isEmpty ? [.init(name: "Display", frame: .init(x: 0, y: 0))] : cached
    }
    private func rect(_ m: MachineInventory.Machine, index: Int) -> CGRect {
        if let r = machineDraft[m.id] { return r }
        if let s = model.screens.first(where: { $0.elsewhere && $0.machine == m.name }) { return screenRect(s) }
        let size = monitors(m).reduce(CGRect.null) { $0.union($1.frame.rect) }.size
        if let p = m.visit?.placement ?? MachineArrangementStore.placement(m.name) {
            return CGRect(origin: p.rect.origin, size: size)
        }
        let bounds = model.screens.reduce(CGRect.null) { $0.union(screenRect($1)) }
        return CGRect(x: bounds.maxX + 350, y: bounds.minY + Double(index) * (size.height + 200), width: size.width, height: size.height)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let rects = machines.enumerated().map { rect($0.element, index: $0.offset) }
                let bounds = fixedBounds ?? (model.screens.map(screenRect) + rects).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -300, dy: -300)
                let scale = min(proxy.size.width / max(bounds.width, 1), proxy.size.height / max(bounds.height, 1))
                ZStack(alignment: .topLeading) {
                    ForEach(model.screens, id: \.displayID) { screen in
                        let r = screenRect(screen)
                        tile(screen.elsewhere ? (screen.machine == nil ? "\(screen.number) · Elsewhere" : "") : (screen.main ? "This Mac" : "Display \(screen.number)"), rect: r, bounds: bounds, scale: scale, dim: screen.elsewhere)
                            .gesture(DragGesture().onChanged { value in
                                guard !trial.pending else { return }
                                if moving == nil { moving = "screen"; start = r; fixedBounds = bounds }
                                draft[screen.displayID] = start.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale)
                            }.onEnded { _ in
                                guard !trial.pending else { return }
                                draft[screen.displayID] = MachineGeometry.snap(screenRect(screen), to: model.screens.filter { $0.displayID != screen.displayID }.map(screenRect), tolerance: 18 / scale)
                                moving = nil; fixedBounds = nil
                            })
                            .accessibilityLabel("\(screen.name), drag to rearrange; Apply commits changes")
                    }
                    ForEach(Array(machines.enumerated()), id: \.element.id) { index, m in
                        let r = rect(m, index: index)
                        let ms = monitors(m)
                        let local = ms.reduce(CGRect.null) { $0.union($1.frame.rect) }
                        let monitorScale = min(r.width / local.width, r.height / local.height) * scale
                        ZStack(alignment: .topLeading) {
                            ForEach(Array(ms.enumerated()), id: \.offset) { _, monitor in
                                let f = monitor.frame.rect
                                RoundedRectangle(cornerRadius: 3).fill(Palette.surface)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Palette.textMuted, lineWidth: 1))
                                    .frame(width: f.width * monitorScale, height: f.height * monitorScale)
                                    .offset(x: (f.minX - local.minX) * monitorScale, y: (f.minY - local.minY) * monitorScale)
                            }
                            Text(m.name).font(Typo.heading(11)).lineLimit(1).padding(5)
                                .foregroundStyle(model.visit.visiting == m.visit?.name && m.visit != nil ? Long.coral : Palette.text)
                        }
                        .frame(width: r.width * scale, height: r.height * scale, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .opacity(isPlaced(r) && (model.reachable[m.name] == true || onlineNames.contains(m.remote ?? m.name)) ? 1 : 0.55)
                        .offset(x: (r.minX - bounds.minX) * scale, y: (r.minY - bounds.minY) * scale)
                        .allowsHitTesting(draft.isEmpty && !trial.pending)
                        .help(draft.isEmpty && !trial.pending ? "Drag to place" : "Apply or revert the display arrangement first")
                        .gesture(DragGesture().onChanged { value in
                            guard draft.isEmpty, !trial.pending else { return }
                            if moving == nil { moving = m.id; start = r; fixedBounds = bounds }
                            machineDraft[m.id] = start.offsetBy(dx: value.translation.width / scale, dy: value.translation.height / scale)
                        }.onEnded { _ in
                            guard draft.isEmpty, !trial.pending else { return }
                            var placed = machineDraft[m.id] ?? r
                            let elsewhere = model.screens.first { $0.elsewhere && screenRect($0).contains(CGPoint(x: placed.midX, y: placed.midY)) }
                            if let elsewhere { placed = screenRect(elsewhere) }
                            else { placed = MachineGeometry.snap(placed, to: model.screens.map(screenRect), tolerance: 18 / scale) }
                            do {
                                try MachineArrangementStore.place(m.name, placed)
                                for s in model.screens where s.machine == m.name { _ = VisitController.shared.setDisplayMachine(s.number, name: nil) }
                                if let elsewhere { _ = VisitController.shared.setDisplayMachine(elsewhere.number, name: m.name) }
                                machineDraft.removeValue(forKey: m.id); model.refresh()
                            } catch { model.error = String(describing: error) }
                            moving = nil; fixedBounds = nil
                        })
                        .accessibilityLabel("\(m.name), drag to place")
                    }
                }
            }.frame(height: 290).clipped()
            HStack {
                if trial.pending {
                    Text("Keep this arrangement? Reverts after 15 seconds.").foregroundStyle(Palette.textDim)
                    Spacer()
                    Button("Keep") { trial.keep(); draft = [:] }
                    Button("Revert") { trial.revert(); draft = [:] }
                } else {
                    Spacer()
                    Button("Revert") { draft = [:] }.disabled(draft.isEmpty)
                    Button("Apply") {
                        do { try trial.apply(Dictionary(uniqueKeysWithValues: model.screens.map { ($0.displayID, screenRect($0)) })) }
                        catch { model.error = String(describing: error) }
                    }.disabled(draft.isEmpty)
                }
            }
            if let error = trial.error { Text(error) }
        }
        .onChange(of: trial.pending) { _, pending in if !pending { draft = [:]; model.refresh() } }
    }
    private func isPlaced(_ r: CGRect) -> Bool { model.screens.contains { !MachineGeometry.contacts(display: screenRect($0), machine: r).isEmpty || ($0.elsewhere && screenRect($0) == r) } }
    private func tile(_ label: String, rect: CGRect, bounds: CGRect, scale: Double, dim: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Palette.surface)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.textDim, lineWidth: 1))
            .overlay(Text(label).font(Typo.body(11)).lineLimit(1).padding(4))
            .frame(width: rect.width * scale, height: rect.height * scale)
            .opacity(dim ? 0.28 : 1)
            .offset(x: (rect.minX - bounds.minX) * scale, y: (rect.minY - bounds.minY) * scale)
    }
}
