import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// An Overview drag identifies one existing window. It carries no Desktop
/// number, frame, or cached eligibility; those are resolved again on drop.
struct OverviewWindowDragPayload: Codable, Equatable, Transferable {
    let wid: UInt32

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "com.lattices.overview-window", conformingTo: .data))
            .visibility(.ownProcess)
    }
}

/// The drop's explicit display and Space must still be a valid destination
/// in the latest projection. Desktop numbers are presentation only.
enum OverviewWindowDrop {
    static func destination(on display: OverviewDisplay, spaceId: Int) -> OverviewMoveDestination? {
        guard let desktop = display.desktopNumber(of: spaceId) else { return nil }
        return OverviewMoveDestination(
            displayIndex: display.index, displayId: display.displayId,
            displayName: display.name, spaceId: spaceId, desktop: desktop
        )
    }

    static func window(
        from items: [OverviewWindowDragPayload],
        to destination: OverviewMoveDestination,
        projection: OverviewProjection,
        moving: Set<UInt32>
    ) -> UInt32? {
        guard items.count == 1, let wid = items.first?.wid, wid != 0,
              moving.isEmpty,
              projection.moveTargets(for: wid).contains(destination) else { return nil }
        return wid
    }
}

/// Shared by map glyphs, tray chips, and the full window list.
struct OverviewWindowDragSource: ViewModifier {
    @ObservedObject var model: OverviewModel
    let row: OverviewRow?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let row, model.moving.isEmpty, !model.projection.moveTargets(for: row.wid).isEmpty {
            content.draggable(OverviewWindowDragPayload(wid: row.wid)) {
                HStack(spacing: 7) {
                    Image(systemName: "macwindow")
                    Text(row.app).font(Typo.monoBold(10))
                    Text(row.title.isEmpty ? "Untitled" : row.title)
                        .font(Typo.mono(10))
                        .lineLimit(1)
                }
                .foregroundColor(Palette.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 300)
                .background(Palette.bg, in: RoundedRectangle(cornerRadius: 6))
            }
            .dragConfiguration(DragConfiguration(
                operationsWithinApp: .init(allowCopy: false, allowMove: true),
                operationsOutsideApp: .init(allowCopy: false)
            ))
            .onDragSessionUpdated { session in
                if session.phase != .active {
                    DiagnosticLog.shared.info("Overview: drag wid=\(row.wid) phase=\(session.phase)")
                }
            }
        } else {
            content
        }
    }
}

struct OverviewWindowDropTarget: ViewModifier {
    @ObservedObject var model: OverviewModel
    let destination: OverviewMoveDestination?
    var compact = false
    @State private var isTargeted = false

    init(model: OverviewModel, destination: OverviewMoveDestination?, compact: Bool = false) {
        self.model = model
        self.destination = destination
        self.compact = compact
    }

    init(model: OverviewModel, display: OverviewDisplay, spaceId: Int, compact: Bool = false) {
        self.init(model: model, destination: OverviewWindowDrop.destination(on: display, spaceId: spaceId), compact: compact)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let destination {
            content
                .overlay {
                    if isTargeted, model.moving.isEmpty {
                        RoundedRectangle(cornerRadius: compact ? 3 : 6)
                            .fill(Palette.text.opacity(0.08))
                            .overlay {
                                RoundedRectangle(cornerRadius: compact ? 3 : 6)
                                    .strokeBorder(Palette.text, lineWidth: 2)
                            }
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isTargeted, !compact, model.moving.isEmpty {
                        Text("Move to \(destination.title)")
                            .font(Typo.monoBold(10))
                            .foregroundColor(Palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Palette.bg, in: RoundedRectangle(cornerRadius: 5))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }
                .dropDestination(for: OverviewWindowDragPayload.self) { items, _ in
                    isTargeted = false
                    DiagnosticLog.shared.info("Overview: drop windows=\(items.map(\.wid)) destination=\(destination.spaceId)")
                    guard let wid = OverviewWindowDrop.window(
                        from: items, to: destination, projection: model.projection, moving: model.moving
                    ) else { return false }
                    return model.move(wid, toSpace: destination.spaceId)
                } isTargeted: {
                    isTargeted = $0
                    DiagnosticLog.shared.info("Overview: drop target=\(destination.spaceId) active=\($0)")
                }
                .onDropSessionUpdated { session in
                    if session.phase != .active {
                        DiagnosticLog.shared.info("Overview: drop session target=\(destination.spaceId) phase=\(session.phase) operations=\(session.suggestedOperations)")
                    }
                }
                .dropConfiguration { _ in DropConfiguration(operation: model.moving.isEmpty ? .move : .forbidden) }
        } else {
            content
        }
    }
}
