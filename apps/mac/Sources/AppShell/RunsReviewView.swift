import AppKit
import SwiftUI

struct RunsReviewView: View {
    @ObservedObject private var store = RunStore.shared
    @State private var selectedRunId: String?
    @State private var selectedArtifactId: String?
    @State private var detailTab = "Artifacts"

    private var selectedRun: RunSession? {
        guard let selectedRunId,
              let match = store.runs.first(where: { $0.id == selectedRunId }) else {
            return store.runs.first
        }
        return match
    }

    private var selectedArtifact: RunArtifact? {
        guard let run = selectedRun else { return nil }
        if let selectedArtifactId,
           let match = run.artifacts.first(where: { $0.id == selectedArtifactId }) {
            return match
        }
        return run.artifacts.first
    }

    var body: some View {
        GeometryReader { geometry in
            if store.runs.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    runList
                        .frame(width: geometry.size.width < 900 ? 232 : 260)
                    Divider().overlay(Palette.border)
                    detailArea
                        .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground())
        .pageActions([
            PageAction(id: "capture-run", title: "Capture", icon: "camera.viewfinder", perform: capture)
        ])
        .onAppear {
            ensureSelection()
            DiagnosticLog.shared.info("Runs review opened")
        }
        .onChange(of: store.runs.map(\.id)) { _, _ in
            ensureSelection()
        }
    }

    private var runList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent runs")
                    .font(Typo.heading(12))
                    .foregroundColor(Palette.textDim)
                Spacer()
                Text(store.runs.count.formatted())
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .help("Trace and artifacts produced by Lattices captures and actions.")

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(store.runs) { run in
                        RunListRow(
                            run: run,
                            isSelected: run.id == selectedRun?.id
                        ) {
                            selectedRunId = run.id
                            selectedArtifactId = run.artifacts.first?.id
                            detailTab = run.artifacts.isEmpty ? "Trace" : "Artifacts"
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .background(Color.black.opacity(0.16))
    }

    @ViewBuilder
    private var detailArea: some View {
        if let run = selectedRun {
            VStack(spacing: 0) {
                runSummary(run)
                Divider().overlay(Palette.border)
                GeometryReader { geometry in
                    if run.artifacts.isEmpty {
                        VStack(spacing: 0) {
                            timeline(run)
                            noArtifacts(run)
                        }
                    } else if geometry.size.width >= 820 {
                        HStack(spacing: 0) {
                            artifactPreview(run)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            Divider().overlay(Palette.border)
                            timeline(run)
                                .frame(width: min(380, geometry.size.width * 0.38))
                        }
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Picker("Run detail", selection: $detailTab) {
                                    Text("Artifacts · \(run.artifacts.count)").tag("Artifacts")
                                    Text("Trace · \(run.trace.count)").tag("Trace")
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .frame(maxWidth: 300)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            if detailTab == "Trace" {
                                timeline(run)
                            } else {
                                artifactPreview(run)
                            }
                        }
                    }
                }
            }
        } else {
            emptyState
        }
    }

    private func runSummary(_ run: RunSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(run.title)
                        .font(Typo.title(18))
                        .foregroundColor(Palette.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(run.id)
                        .font(Typo.mono(10))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(run.id)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                StatePill(state: run.state)
                    .fixedSize()
                runActions(run)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), alignment: .leading)], alignment: .leading, spacing: 12) {
                summaryMetric("Source", run.source)
                summaryMetric("Started", shortTimestamp(run.startedAt))
                summaryMetric("Completed", run.completedAt.map(shortTimestamp) ?? "Open")
                if let surface = run.surfaces.first {
                    summaryMetric("Target", surface.app ?? surface.kind)
                }
            }
        }
        .padding(20)
        .background(Palette.surface.opacity(0.45))
    }

    private func runActions(_ run: RunSession) -> some View {
        Menu {
            Button("Retry capture", systemImage: "arrow.clockwise") { retry(run) }
            Button(selectedArtifact == nil ? "Reveal run folder" : "Reveal artifact", systemImage: "folder") { reveal(run) }
            Button(selectedArtifact == nil ? "Copy run folder path" : "Copy artifact path", systemImage: "doc.on.doc") {
                copyPath(selectedArtifact?.path ?? run.artifactDirectoryPath)
            }
            Divider()
            Button("Delete run", systemImage: "trash", role: .destructive) { delete(run) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Palette.textDim)
                .frame(width: 28, height: 26)
                .buttonBox()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Run actions")
        .help("Run actions")
    }

    private func noArtifacts(_ run: RunSession) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc")
                .font(.system(size: 15))
                .foregroundColor(Palette.textMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text(run.completedAt == nil ? "No files yet" : "No artifacts")
                    .font(Typo.heading(11))
                    .foregroundColor(Palette.textDim)
                Text(run.completedAt == nil ? "Files produced by this run will appear here." : "This run has trace data but did not produce a file.")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Palette.border.frame(height: 0.5) }
    }

    private func artifactPreview(_ run: RunSession) -> some View {
        VStack(spacing: 0) {
            artifactStrip(run)

            Rectangle()
                .fill(Palette.border)
                .frame(height: 0.5)

            if let artifact = selectedArtifact {
                VStack(spacing: 12) {
                    artifactCanvas(artifact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    artifactMetadata(artifact)
                }
                .padding(14)
            } else {
                noArtifacts(run)
            }
        }
    }

    private func artifactStrip(_ run: RunSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(run.artifacts) { artifact in
                    Button {
                        selectedArtifactId = artifact.id
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: artifact.kind == "screenshot" ? "photo" : "doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(artifact.relativePath)
                                .font(Typo.mono(10))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundColor(artifact.id == selectedArtifact?.id ? Palette.running : Palette.textMuted)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(artifact.id == selectedArtifact?.id ? Palette.running.opacity(0.12) : Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(artifact.id == selectedArtifact?.id ? Palette.running.opacity(0.28) : Palette.border, lineWidth: 0.5)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 43)
    }

    @ViewBuilder
    private func artifactCanvas(_ artifact: RunArtifact) -> some View {
        if artifact.mimeType.hasPrefix("image/"),
           let image = NSImage(contentsOfFile: artifact.path) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    )

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            }
        } else {
            VStack(spacing: 9) {
                Image(systemName: "doc")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(Palette.textMuted)
                Text(artifact.relativePath)
                    .font(Typo.mono(11))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(artifact.mimeType)
                    .font(Typo.mono(10))
                    .foregroundColor(Palette.textDim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func artifactMetadata(_ artifact: RunArtifact) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 8) {
            metadataItem("Kind", artifact.kind)
            metadataItem("Type", artifact.mimeType)
            if let width = artifact.metadata["width"]?.intValue,
               let height = artifact.metadata["height"]?.intValue {
                metadataItem("Size", "\(width) × \(height)")
            }
            if let bytes = artifact.metadata["byteSize"]?.intValue {
                metadataItem("File", ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
    }

    private func timeline(_ run: RunSession) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Trace")
                    .font(Typo.heading(12))
                    .foregroundColor(Palette.text)
                Spacer()
                Text("\(run.trace.count) event\(run.trace.count == 1 ? "" : "s")")
                    .font(Typo.caption(11))
                    .foregroundColor(Palette.textMuted)
            }
            .padding(.horizontal, 20)
            .frame(height: 44)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(run.trace) { event in
                        TraceRow(event: event, isLast: event.id == run.trace.last?.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(run.id)
            .overlay {
                if run.trace.isEmpty {
                    Text("No trace events yet")
                        .font(Typo.body(12))
                        .foregroundColor(Palette.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "record.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Palette.textMuted)
            Text("No runs yet")
                .font(Typo.heading(15))
                .foregroundColor(Palette.text)
            Text("Use Capture to save the frontmost window as a Lattices run artifact.")
                .font(Typo.body(12))
                .foregroundColor(Palette.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button(action: capture) {
                Label("Capture Current Window", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summaryMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(Typo.caption(10))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
            Text(value)
                .font(Typo.body(12))
                .monospacedDigit()
                .foregroundColor(Palette.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(Typo.caption(10))
                .foregroundColor(Palette.textDim)
            Text(value)
                .font(Typo.mono(10))
                .foregroundColor(Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func capture() {
        Task.detached(priority: .userInitiated) {
            do {
                _ = try CaptureController.shared.screenshotWindow(params: .object([
                    "source": .string("review"),
                ]))
            } catch {
                DiagnosticLog.shared.warn("Runs: screenshot failed — \(error.localizedDescription)")
            }
        }
    }

    private func ensureSelection() {
        guard !store.runs.isEmpty else {
            selectedRunId = nil
            selectedArtifactId = nil
            return
        }

        if let selectedRunId,
           store.runs.contains(where: { $0.id == selectedRunId }) {
            let artifacts = selectedRun?.artifacts ?? []
            if let selectedArtifactId,
               artifacts.contains(where: { $0.id == selectedArtifactId }) {
                return
            }
            self.selectedArtifactId = artifacts.first?.id
            return
        }

        selectedRunId = store.runs.first?.id
        selectedArtifactId = store.runs.first?.artifacts.first?.id
        detailTab = store.runs.first?.artifacts.isEmpty == false ? "Artifacts" : "Trace"
    }

    private func retry(_ run: RunSession) {
        let surface = run.surfaces.first
        Task.detached(priority: .userInitiated) {
            var params: [String: JSON] = [
                "source": .string("review"),
                "title": .string("Retry \(run.title)"),
            ]
            if let wid = surface?.wid {
                params["wid"] = .int(Int(wid))
            } else if let app = surface?.app {
                params["app"] = .string(app)
                if let title = surface?.title { params["title"] = .string(title) }
            }
            do {
                _ = try CaptureController.shared.screenshotWindow(params: .object(params))
            } catch {
                DiagnosticLog.shared.warn("Runs: retry failed — \(error.localizedDescription)")
            }
        }
    }

    private func reveal(_ run: RunSession) {
        let url = selectedArtifact.map { URL(fileURLWithPath: $0.path) }
            ?? URL(fileURLWithPath: run.artifactDirectoryPath, isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        DiagnosticLog.shared.success("Runs: copied path")
    }

    private func delete(_ run: RunSession) {
        do {
            try store.delete(id: run.id)
            DiagnosticLog.shared.success("Runs: deleted \(run.id)")
        } catch {
            DiagnosticLog.shared.warn("Runs: delete failed — \(error.localizedDescription)")
        }
    }

    private func shortTimestamp(_ timestamp: String) -> String {
        RunReviewDate.string(timestamp, includeDate: true)
    }
}

private struct RunListRow: View {
    let run: RunSession
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                StateDot(state: run.state)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(run.title)
                            .font(Typo.heading(12))
                            .foregroundColor(Palette.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        if !run.artifacts.isEmpty {
                            Label("\(run.artifacts.count)", systemImage: "paperclip")
                                .font(Typo.caption(10))
                                .foregroundColor(Palette.textMuted)
                                .fixedSize()
                        }
                    }
                    HStack(spacing: 8) {
                        Text(run.source)
                            .font(Typo.caption(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(RunReviewDate.string(run.startedAt))
                            .font(Typo.mono(10))
                            .fixedSize()
                    }
                    .foregroundColor(Palette.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Palette.running.opacity(0.10) : (isHovered ? Palette.surfaceHov : .clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? Palette.running.opacity(0.24) : .clear, lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(run.title), \(run.state), \(run.source), \(RunReviewDate.string(run.startedAt, includeDate: true)), \(run.artifacts.count) artifacts")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help([run.title, run.source, run.surfaces.first?.app].compactMap { $0 }.joined(separator: " · "))
    }
}

private struct StatePill: View {
    let state: String

    var body: some View {
        HStack(spacing: 5) {
            StateDot(state: state)
            Text(state.capitalized)
                .font(Typo.caption(10))
                .lineLimit(1)
        }
        .foregroundColor(stateColor(state))
        .padding(.horizontal, 8)
        .frame(height: 25)
        .background(Capsule().fill(stateColor(state).opacity(0.10)))
        .fixedSize()
    }
}

private struct StateDot: View {
    let state: String

    var body: some View {
        Circle()
            .fill(stateColor(state))
            .frame(width: 6, height: 6)
    }
}

private struct TraceRow: View {
    let event: RunTraceEvent
    let isLast: Bool
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(kindColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(event.summary)
                    .font(Typo.body(12))
                    .foregroundColor(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    eventKind
                    Spacer(minLength: 4)
                    eventTime
                }
                if !event.data.isEmpty {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(event.data.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(key)
                                        .foregroundColor(Palette.textMuted)
                                    Text(event.data[key].map(jsonPreview) ?? "")
                                        .foregroundColor(Palette.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                                .font(Typo.mono(10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        Text("Details")
                            .font(Typo.caption(11))
                            .foregroundColor(Palette.textMuted)
                    }
                    .tint(Palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 18)
        .overlay(alignment: .leading) {
            if !isLast {
                Rectangle()
                    .fill(Palette.borderLit)
                    .frame(width: 1)
                    .padding(.leading, 3)
                    .padding(.top, 17)
            }
        }
    }

    private var eventKind: some View {
        Text(event.kind)
            .font(Typo.mono(10))
            .foregroundColor(kindColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(event.kind)
    }

    private var eventTime: some View {
        Text(RunReviewDate.string(event.time))
            .font(Typo.mono(10))
            .foregroundColor(Palette.textMuted)
            .fixedSize()
    }

    private var kindColor: Color {
        if event.kind.contains("failed") { return Palette.kill }
        if event.kind.contains("completed") { return Palette.running }
        return Palette.textDim
    }

    private func jsonPreview(_ json: JSON) -> String {
        if case .string(let value) = json { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(json), let text = String(data: data, encoding: .utf8) else { return "—" }
        return text
    }
}

private enum RunReviewDate {
    private static let iso = ISO8601DateFormatter()
    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm:ss"
        return formatter
    }()
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func string(_ timestamp: String, includeDate: Bool = false) -> String {
        guard let date = iso.date(from: timestamp) ?? fractionalISO.date(from: timestamp) else { return timestamp }
        return (includeDate ? dateTime : time).string(from: date)
    }
}

private func stateColor(_ state: String) -> Color {
    switch state {
    case "completed": return Palette.running
    case "failed", "cancelled": return Palette.kill
    case "running": return Palette.detach
    default: return Palette.textDim
    }
}
