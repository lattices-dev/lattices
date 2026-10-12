import SwiftUI
import AppKit
import HudsonObservability

/// The workspace log uses a native table; the floating logger remains independent.
struct ActivityPageView: View {
    @ObservedObject private var store = HudLogStore.shared
    @State private var level: HudLogLevel?
    @State private var selection: UUID?

    private var entries: [HudLogEntry] {
        store.entries.reversed().filter { entry in
            guard let level else { return true }
            return entry.level == level || (level == .error && entry.level == .fault)
        }
    }

    private var selectedEntry: HudLogEntry? {
        entries.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            Table(entries, selection: $selection) {
                TableColumn("Time") { entry in
                    Text(entry.formattedTime)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .width(100)
                TableColumn("Level") { entry in
                    Text(entry.level.rawValue.capitalized)
                        .foregroundStyle(tint(entry.level))
                }
                .width(65)
                TableColumn("Category") { entry in
                    Text(entry.category).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100, max: 160)
                TableColumn("Message") { entry in
                    Text(entry.message)
                        .lineLimit(1)
                        .help(entry.message)
                }
                .width(min: 180, ideal: 600)
            }
            .font(.system(size: 12))
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                    Button("Copy Entry") { copy([entry]) }
                }
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No activity", systemImage: "list.bullet.rectangle",
                        description: Text(level == nil ? "Events appear as Lattices runs." : "No events at this level."))
                }
            }

            if let entry = selectedEntry {
                Divider()
                detail(entry)
            }
        }
        .onChange(of: level) { _, _ in selection = nil }
        .onAppear { DiagnosticLog.shared.info("Activity page opened") }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Level", selection: $level) {
                Text("All").tag(nil as HudLogLevel?)
                Text("Debug").tag(HudLogLevel.debug as HudLogLevel?)
                Text("Info").tag(HudLogLevel.info as HudLogLevel?)
                Text("Notice").tag(HudLogLevel.notice as HudLogLevel?)
                Text("Warning").tag(HudLogLevel.warning as HudLogLevel?)
                Text("Error").tag(HudLogLevel.error as HudLogLevel?)
            }
            .pickerStyle(.menu)
            .buttonStyle(.borderless)
            .labelsHidden()
            .frame(width: 90)

            Text(level == nil ? "\(entries.count) events" : "\(entries.count) of \(store.entries.count) events")
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()
            Label {
                Text("Live")
            } icon: {
                Circle().fill(Color.green).frame(width: 5, height: 5)
            }
            .foregroundStyle(.secondary)

            Button { copy(entries) } label: {
                Image(systemName: "doc.on.doc")
                    .frame(width: 24, height: 24)
            }
            .help("Copy visible events")
            .accessibilityLabel("Copy visible events")
            .disabled(entries.isEmpty)

            Button {
                store.clear()
                selection = nil
            } label: {
                Image(systemName: "trash")
                    .frame(width: 24, height: 24)
            }
            .help("Clear activity")
            .accessibilityLabel("Clear activity")
            .disabled(store.entries.isEmpty)
        }
        .font(.system(size: 12))
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func detail(_ entry: HudLogEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(entry.subsystem) · \(entry.category)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Entry") { copy([entry]) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    Button { selection = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Close details")
                        .accessibilityLabel("Close details")
                }
                Text(entry.message)
                    .font(.system(size: 12, design: .monospaced))
                ForEach(entry.metadata.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                    Text("\(key): \(value)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .font(.system(size: 11))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(height: 150)
    }

    private func tint(_ level: HudLogLevel) -> Color {
        switch level {
        case .warning: return .orange
        case .error, .fault: return .red
        default: return .secondary
        }
    }

    private func copy(_ entries: [HudLogEntry]) {
        let text = entries.map { entry in
            let metadata = entry.metadata.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return [entry.formattedTime, entry.level.rawValue.uppercased(), entry.subsystem,
                    entry.category, entry.message, metadata].filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
