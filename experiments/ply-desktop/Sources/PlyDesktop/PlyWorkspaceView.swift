import SwiftUI

struct PlyWorkspaceView: View {
    @ObservedObject var store: PlyWorkspaceStore
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Where to?").font(.headline)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close workspaces")
            }
            Text("Your Lattices workspaces").font(.subheadline).foregroundStyle(.secondary)
            if let snapshot = store.snapshot {
                if snapshot.layers.isEmpty {
                    Text("No workspaces yet. Add a layer in Lattices to give Ply somewhere to take you.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(snapshot.layers) { layer in
                                Button {
                                    Task { await store.focus(layer) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: snapshot.isCurrent(layer) ? "checkmark.circle.fill" : "square.stack")
                                            .foregroundStyle(snapshot.isCurrent(layer) ? Color.accentColor : .secondary)
                                        Text(layer.label).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: 6)
                                        Text(snapshot.isCurrent(layer) ? "Here" : "Switch")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(snapshot.isCurrent(layer) ? Color.accentColor.opacity(0.09) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .disabled(store.phase.busy || snapshot.isCurrent(layer))
                                .help("Switch to \(layer.label) using its saved layout")
                                .accessibilityLabel("\(layer.label), \(snapshot.isCurrent(layer) ? "current workspace" : "switch workspace")")
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            } else {
                Spacer(minLength: 0)
            }
            phaseLabel
            Divider()
            HStack {
                Text("No background checks").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await store.refresh() } }
                    .disabled(store.phase.busy)
            }
            Text("Switching applies the workspace’s saved layout.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        // Reserve the final size before the async read. Growing a popover after
        // presentation can clip its footer at the edge of the desktop.
        .padding(16).frame(width: 306, height: 440)
    }

    @ViewBuilder private var phaseLabel: some View {
        switch store.phase {
        case .loading:
            Label("Finding your workspaces…", systemImage: "ellipsis").foregroundStyle(.secondary)
        case .switching(let label):
            Text("Switching to \(label)…").font(.callout).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        case .success(let label):
            Label("Now in \(label)", systemImage: "checkmark").font(.callout)
        default: EmptyView()
        }
    }
}
