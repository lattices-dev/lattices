import AppKit
import SwiftUI

struct MachineHostDetail: View {
    let host: RemoteHostsModel.Host
    @ObservedObject var model: RemoteHostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: Chrome.inset) {
                screen
                    .frame(maxWidth: .infinity)
                windowList
                    .frame(width: 260)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border, lineWidth: Chrome.hairline))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(host.status == .online ? Palette.textDim : Palette.textMuted)
                .frame(width: 6, height: 6)
            Text(host.name)
                .font(Typo.heading(13))
                .foregroundColor(Palette.text)
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

    @ViewBuilder
    private var screen: some View {
        let canGoLive = host.status == .online && host.capabilities.contains("capture.live")
        Button {
            model.openLive(host.name)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .fill(Color.black.opacity(0.3))
                if let still = host.still {
                    Image(nsImage: still)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .opacity(host.status == .online ? 1 : 0.45)
                } else {
                    Text(host.status == .online ? "Capturing" : "No screen")
                        .font(Typo.mono(11))
                        .foregroundColor(Palette.textMuted)
                }
            }
            .aspectRatio(stillAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Chrome.controlRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Chrome.controlRadius)
                    .strokeBorder(Palette.border, lineWidth: Chrome.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canGoLive)
        .help(canGoLive ? "Open \(host.name) live" : "")
        .overlay(alignment: .bottomLeading) {
            if let error = host.liveError {
                Text(error)
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.text)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.7)))
                    .padding(8)
            }
        }
    }

    private var stillAspect: CGFloat {
        guard let size = host.still?.size, size.height > 0 else { return 16.0 / 9.0 }
        return size.width / size.height
    }

    private var windowList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(host.windows) { window in
                HStack(spacing: 6) {
                    Text(window.app)
                        .font(Typo.mono(10))
                        .foregroundColor(window.isFocused ? Palette.text : Palette.textDim)
                        .frame(width: 70, alignment: .leading)
                    Text(window.title.isEmpty ? "—" : window.title)
                        .font(Typo.body(11))
                        .foregroundColor(window.isFocused ? Palette.text : Palette.textDim)
                    Spacer(minLength: 0)
                    if let space = window.space {
                        Text("\(space)")
                            .font(Typo.mono(10))
                            .foregroundColor(Palette.textMuted)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.vertical, 3)
            }
        }
    }
}
