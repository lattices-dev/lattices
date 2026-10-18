import AppKit
import Combine
import SwiftUI

/// One read-only projection and persisted browsing selection for both pages.
final class LayerIndexState: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        let label: String
        let windows: [UInt32]
        var count: Int { windows.count }
    }
    static let shared = LayerIndexState()
    @Published private(set) var rows: [Row] = []
    @Published private(set) var selected: [String]
    @Published private(set) var readAt = Date()
    private var cached: EditorBridge.Snapshot?
    private var capturedAt = Date.distantPast
    private var rowsRevision: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.stringArray(forKey: "layers.sharedSelection.v1") ?? []
    }
    func select(_ ids: [String]) {
        var seen = Set<String>()
        let next = ids.filter { seen.insert($0).inserted }
        guard next != selected else { return }
        selected = next
        defaults.set(next, forKey: "layers.sharedSelection.v1")
    }
    func choose(_ id: String?, additive: Bool = false) {
        guard let id else { select([]); return }
        select(additive ? (selected.contains(id) ? selected.filter { $0 != id } : selected + [id]) : [id])
    }
    func snapshot() throws -> EditorBridge.Snapshot {
        if let cached, Date().timeIntervalSince(capturedAt) < 0.5 { return cached }
        let next = try EditorBridge.liveSnapshot()
        capturedAt = Date()
        cached = next
        updateRows(next)
        return next
    }

    /// Overview's sidebar does not need the editor's live AX layout preview.
    /// Keep this separate from the full snapshot cache so opening the editor
    /// cannot receive a membership-only projection without geometry.
    func refreshRows() throws {
        updateRows(try EditorBridge.liveSnapshot(includeGeometry: false))
    }

    private func updateRows(_ next: EditorBridge.Snapshot) {
        if rowsRevision != next.subject.revision { readAt = Date() }
        rowsRevision = next.subject.revision
        let groups = next.projection["groups"] as? [[String: Any]] ?? []
        let updated = groups.compactMap { group -> Row? in
            guard let id = group["id"] as? String, let label = group["label"] as? String else { return nil }
            let windows = (group["rows"] as? [[String: Any]] ?? []).compactMap { ($0["windowId"] as? NSNumber)?.uint32Value }
            return Row(id: id, label: label, windows: windows)
        }
        if rows != updated { rows = updated }
    }
}

struct OverviewLayerIndex: View {
    let rows: [LayerIndexState.Row]
    let selected: [String]
    let readAt: Date
    var live = true
    let choose: (String?, Bool) -> Void
    @FocusState private var focused: Bool
    private let ink = Color(red: 176 / 255, green: 179 / 255, blue: 184 / 255)
    private let faint = Color(red: 146 / 255, green: 150 / 255, blue: 157 / 255)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LAYERS").tracking(2)
                Spacer()
                Text("\(max(0, rows.count - 1))")
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(faint).frame(height: 15).padding(.horizontal, 12).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(spacing: 0) {
                    row(nil, "All windows", Set(rows.flatMap(\.windows)).count)
                    ForEach(Array(rows.dropLast())) { item in row(item.id, item.label, item.count) }
                    Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1).padding(.vertical, 12)
                    if let last = rows.last { row(last.id, "Unassigned", last.count) }
                }
            }
            Spacer(minLength: 8)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text("workspace.json")
                    Text("Read \(live ? max(0, Int(context.date.timeIntervalSince(readAt))) : 0)s ago")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundColor(faint)
            }.padding(12).padding(.bottom, 10)
        }
        .padding(.horizontal, 12)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .background(Color(red: 23 / 255, green: 25 / 255, blue: 29 / 255))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1) }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard press.key == .upArrow || press.key == .downArrow else { return .ignored }
            step(press.key == .upArrow ? -1 : 1, additive: press.modifiers.contains(.command))
            return .handled
        }
    }
    private func step(_ delta: Int, additive: Bool) {
        let ids: [String?] = [nil] + rows.map { Optional($0.id) }
        let at = ids.firstIndex(of: selected.last) ?? 0
        choose(ids[min(max(at + delta, 0), ids.count - 1)], additive)
    }
    private func row(_ id: String?, _ label: String, _ count: Int) -> some View {
        let active = id.map(selected.contains) ?? selected.isEmpty
        return Button {
            focused = true
            choose(id, NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: 10) {
                if id == nil {
                    RoundedRectangle(cornerRadius: 1).strokeBorder(faint, lineWidth: 1).frame(width: 7, height: 7)
                } else if id == rows.last?.id {
                    Circle().fill(faint).frame(width: 7, height: 7)
                } else {
                    Circle().fill(count > 0 ? Color(red: 51 / 255, green: 199 / 255, blue: 115 / 255) : .clear)
                        .overlay(Circle().strokeBorder(count > 0 ? .clear : Color(red: 108 / 255, green: 113 / 255, blue: 120 / 255), lineWidth: 1))
                        .frame(width: 7, height: 7)
                }
                Text(label).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 4)
                Text(count > 0 || id == nil ? "\(count)" : "—").font(.system(size: 11, design: .monospaced)).foregroundColor(faint)
            }
            .foregroundColor(active ? Color(red: 236 / 255, green: 237 / 255, blue: 239 / 255) : ink)
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color(red: 36 / 255, green: 40 / 255, blue: 46 / 255) : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
}
