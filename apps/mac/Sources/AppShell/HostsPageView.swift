import AppKit
import SwiftUI

/// Another machine's state and its windows. The canvas above shows its
/// monitors; any window here opens on its own in the remote viewer.
struct MachineHostDetail: View {
    let host: RemoteHostsModel.Host

    private var online: Bool { host.status == .online }
    private var canView: Bool { online && host.capabilities.contains("capture.still") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let error = host.liveError {
                Text(error).font(Typo.mono(10)).foregroundColor(Palette.text).textSelection(.enabled)
            }
            windowList
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(detail)
                .font(Typo.mono(10))
                .foregroundColor(Palette.textDim)
            Spacer()
            if let stillAt = host.stillAt {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(freshness(stillAt))
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)
                }
            }
        }
    }

    private var detail: String {
        switch host.status {
        case .connecting:
            return "\(host.address):\(host.port) · connecting"
        case .offline(let reason):
            return "\(host.address):\(host.port) · \(reason)"
        case .online:
            let system = [host.platform, host.compositor].compactMap { $0 }.joined(separator: " · ")
            let count = "\(host.windows.count) window\(host.windows.count == 1 ? "" : "s")"
            return system.isEmpty ? count : "\(system) · \(count)"
        }
    }

    private func freshness(_ date: Date) -> String {
        let seconds = max(0, Int(-date.timeIntervalSinceNow))
        let age = seconds < 5 ? "now" : seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
        return host.stillMilliseconds.map { "\(age) · \($0) ms" } ?? age
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(host.windows) { window in
                RemoteWindowRow(window: window, enabled: canView) {
                    RemoteViewerWindows.shared.show(host, target: .window(wid: window.id, app: window.app, title: window.title))
                }
            }
            if host.windows.isEmpty {
                Text(online ? "No windows" : "—")
                    .font(Typo.body(11))
                    .foregroundColor(Palette.textMuted)
                    .padding(.vertical, 4)
            }
        }
    }
}

/// A window on another machine. Clicking opens just that app's window.
private struct RemoteWindowRow: View {
    let window: RemoteHostsModel.Window
    let enabled: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Text(window.app)
                    .font(Typo.mono(10))
                    .foregroundColor(window.isFocused ? Palette.text : Palette.textDim)
                    .frame(width: 76, alignment: .leading)
                Text(window.title.isEmpty ? "—" : window.title)
                    .font(Typo.body(11))
                    .foregroundColor(window.isFocused ? Palette.text : Palette.textDim)
                Spacer(minLength: 0)
                ZStack(alignment: .trailing) {
                    if let space = window.space {
                        Text("\(space)")
                            .font(Typo.mono(10))
                            .foregroundColor(Palette.textMuted)
                            .opacity(hovering && enabled ? 0 : 1)
                    }
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.textDim)
                        .opacity(hovering && enabled ? 1 : 0)
                }
                .frame(width: 18, alignment: .trailing)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering && enabled ? Palette.surfaceHov : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(enabled ? "View \(window.app) on its own" : "")
    }
}
