import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class LongCardModel: ObservableObject {
    @Published var visit = VisitController.shared.status()
    @Published var screens: [DisplayGather.Screen] = []
    @Published var layers: [String] = []
    @Published var activeLayer: Int?
    /// Closes the card; actions that take you somewhere else close it first.
    var dismiss: () -> Void = {}
    var hideLong: () -> Void = {}

    func refresh() {
        visit = VisitController.shared.status()
        screens = DisplayGather.screens()
        layers = WorkspaceManager.shared.config?.layers?.map(\.label) ?? []
        activeLayer = WorkspaceManager.shared.activeLayerSelection
    }

    func run(_ method: String, _ params: JSON? = nil, close: Bool = true) {
        if close { dismiss() }
        ClusterVerbs.run(method, params)
        if !close { refresh() }
    }
}

// MARK: - View

/// What you can do through Lattices from where Long sits: search, layers,
/// machines, displays. Long's own settings are the footer.
struct LongCardView: View {
    @Environment(\.colorScheme) private var scheme
    private var palette: LongPalette { LongPalette(scheme: scheme) }
    @ObservedObject var model: LongCardModel
    /// A new main display is a 15 s trial; Keep shows on it until then.
    @ObservedObject private var arrangement = DisplayArrangement.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.dismiss()
                UnifiedCommandBarWindow.shared.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11))
                    Text("Search")
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(LongCardButton())

            if !model.layers.isEmpty {
                section("Layers") { layersGrid }
            }
            if !model.visit.hosts.isEmpty {
                section("Machines") { machines }
            }
            if !model.screens.isEmpty {
                section("Displays") { displays }
            }

            Divider().overlay(palette.border)
            HStack(spacing: 12) {
                Button("Cursor home") { model.dismiss(); PointerHome.bringHome() }
                Spacer()
                Button {
                    model.dismiss()
                    model.hideLong()
                } label: {
                    Image(systemName: "eye.slash")
                }
                .help("Hide Long")
                .accessibilityLabel("Hide Long")
            }
            .buttonStyle(.plain)
            .font(Typo.body(10))
            .foregroundStyle(palette.textMuted)
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.bg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.borderLit, lineWidth: 0.5))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(Typo.mono(9)).tracking(0.6).foregroundStyle(palette.textMuted)
            content()
        }
    }

    private var layersGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
            ForEach(Array(model.layers.enumerated()), id: \.offset) { index, label in
                Button {
                    model.dismiss()
                    WorkspaceManager.shared.focusLayer(index: index)
                } label: {
                    Text(label).lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(LongCardButton(selected: index == model.activeLayer))
            }
        }
    }

    private var machines: some View {
        VStack(spacing: 4) {
            ForEach(model.visit.hosts, id: \.name) { host in
                let visiting = model.visit.visiting == host.name
                HStack(spacing: 6) {
                    Text(host.name).font(Typo.monoBold(11)).foregroundStyle(palette.text)
                    Spacer()
                    if visiting {
                        Button("End visit") { model.run("home", close: false) }.buttonStyle(LongCardButton(accent: true))
                    } else {
                        Button("Visit") { model.run("visit.start", .object(["host": .string(host.name)])) }
                            .buttonStyle(LongCardButton())
                            .disabled(model.visit.visiting != nil)
                    }
                }
                .frame(height: 24)
            }
        }
    }

    private var displays: some View {
        VStack(spacing: 4) {
            ForEach(model.screens, id: \.index) { screen in
                let params: JSON = .object(["display": .int(screen.index)])
                HStack(spacing: 6) {
                    Text(screen.name).font(Typo.monoBold(11)).foregroundStyle(palette.text).lineLimit(1)
                    Spacer()
                    Button("Bring here") { model.run("bring", params) }.buttonStyle(LongCardButton())
                    if screen.isMain && arrangement.pending {
                        Button("Keep") { arrangement.keep() }.buttonStyle(LongCardButton(accent: true))
                    } else if screen.isMain {
                        Text("main").font(Typo.mono(10)).foregroundStyle(palette.textMuted).frame(width: 46)
                    } else {
                        Button("Main") { model.run("main", params, close: false) }.buttonStyle(LongCardButton()).frame(width: 46)
                    }
                }
                .frame(height: 24)
            }
        }
    }
}

private struct LongCardButton: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    private var palette: LongPalette { LongPalette(scheme: scheme) }
    var accent = false
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.body(11))
            .foregroundStyle(accent ? Long.ink : selected ? palette.text : palette.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(accent ? Long.coral : configuration.isPressed || selected ? palette.surfaceHov : palette.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(selected ? palette.borderLit : palette.border, lineWidth: 0.5))
    }
}

// MARK: - Panel

/// Long's card: opens above him, closes on a click anywhere else or on him again.
@MainActor
final class LongCard {
    private let model = LongCardModel()
    private let panel: NSPanel
    private var outside: Any?
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void, onHideLong: @escaping () -> Void = {}) {
        self.onClose = onClose
        model.hideLong = onHideLong
        let host = NSHostingView(rootView: LongCardView(model: model))
        panel = LongPanel(contentRect: CGRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        model.dismiss = { [weak self] in self?.close() }
    }

    func show(above anchor: CGRect) {
        model.refresh()
        guard let host = panel.contentView else { return }
        let size = host.fittingSize
        let visible = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })?.visibleFrame ?? anchor
        var origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 4)
        if origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 4 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if outside == nil {
            outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
    }

    func refresh() { model.refresh() }

    func close() {
        if let outside { NSEvent.removeMonitor(outside) }
        outside = nil
        panel.orderOut(nil)
        onClose()
    }
}
