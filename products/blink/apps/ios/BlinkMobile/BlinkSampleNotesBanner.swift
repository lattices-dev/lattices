import SwiftUI

struct BlinkSampleNotesBanner: View {
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label("Sample Notes", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 12)
                Button("Exit Samples", action: onExit)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
            }
            Text("Examples only. Your saved notes are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

extension View {
    /// Keep this inside each navigation destination. Ordinary layout reserves
    /// space below native navigation chrome without changing its safe-area region.
    func sampleNotesBanner(isPresented: Bool, onExit: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            if isPresented {
                BlinkSampleNotesBanner(onExit: onExit)
            }
            self
        }
    }
}
