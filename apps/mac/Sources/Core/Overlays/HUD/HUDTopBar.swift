import SwiftUI

// MARK: - HUDTopBar

struct HUDTopBar: View {
    @ObservedObject var state: HUDState
    @ObservedObject private var handsOff = HandsOffSession.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var liveTabs = LiveTabGroupStore.shared
    @ObservedObject private var xp = HUDExperienceStore.shared
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Logo
            logo
                .padding(.leading, 16)

            // Experience badge
            if xp.presetIndex > 0 {
                experienceBadge
                    .padding(.leading, 10)
            }

            // Voice status (when active)
            if state.voiceActive {
                voiceStatus
                    .padding(.leading, 12)
            }

            if let group = liveTabs.activeGroup {
                liveTabStrip(group)
                    .padding(.leading, 12)
            } else if let group = workspace.activeLayerGroups.first {
                mixedTabStrip(group)
                    .padding(.leading, 12)
            }

            Spacer()

            // Layer strip (Hyprland-style)
            if let layers = workspace.config?.layers, !layers.isEmpty {
                layerStrip(layers)
                    .padding(.trailing, 12)
            }

            // Quick actions
            HStack(spacing: 6) {
                quickAction(icon: "rectangle.3.group", label: "Map", shortcut: "⌃⌥⇧⌘1") {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        ScreenMapWindowController.shared.toggle()
                    }
                }

                quickAction(icon: "command", label: "Command Bar", shortcut: "⌃⌥Space") {
                    onDismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        UnifiedCommandBarWindow.shared.toggle(mode: .search)
                    }
                }
            }
            .padding(.trailing, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(HUDPanelBackground())
        .hudEdgeGlow()
    }

    // MARK: - Cross-app tabs

    private func liveTabStrip(_ group: LiveTabGroup) -> some View {
        HStack(spacing: 3) {
            Text(group.name)
                .font(Typo.monoBold(8))
                .foregroundColor(Palette.textMuted)
                .padding(.horizontal, 5)

            ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                let isSelected = group.selectedIndex == index
                Button {
                    liveTabs.select(groupID: group.id, index: index)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 8, weight: .semibold))
                        Text(member.app)
                            .lineLimit(1)
                    }
                    .font(Typo.monoBold(8))
                    .foregroundColor(isSelected ? Palette.bg : Palette.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Palette.running : Color.white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
                .help("Show \(member.app): \(member.label)")
            }

            Button {
                liveTabs.toggleLayout(id: group.id)
            } label: {
                Image(systemName: group.isExpanded ? "rectangle.stack.fill" : "rectangle.split.2x1")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(group.isExpanded ? Palette.running : Palette.textMuted)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                    )
            }
            .buttonStyle(.plain)
            .help(group.isExpanded ? "Return to tabs" : "Split inside the tab group's bounds")

            Button {
                liveTabs.delete(id: group.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Palette.textMuted)
                    .frame(width: 20, height: 22)
            }
            .buttonStyle(.plain)
            .help("Ungroup live tabs")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.running.opacity(0.45), lineWidth: 0.5)
                )
        )
    }

    /// A layer group can mix terminal projects and native app windows. All tabs
    /// occupy the group's configured tile until the grid button fans them out.
    private func mixedTabStrip(_ group: TabGroup) -> some View {
        HStack(spacing: 3) {
            Text(group.label)
                .font(Typo.monoBold(8))
                .foregroundColor(Palette.textMuted)
                .padding(.horizontal, 5)

            ForEach(Array(group.tabs.enumerated()), id: \.offset) { index, tab in
                let isSelected = workspace.selectedTabIndex(in: group) == index
                let isRunning = workspace.isTabRunning(tab)
                Button {
                    workspace.focusTab(group: group, tabIndex: index)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.isTerminal ? "terminal" : "macwindow")
                            .font(.system(size: 8, weight: .semibold))
                        Text(tab.displayLabel)
                            .lineLimit(1)
                    }
                    .font(Typo.monoBold(8))
                    .foregroundColor(isSelected ? Palette.bg : Palette.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? Palette.running : Color.white.opacity(0.04))
                    )
                }
                .buttonStyle(.plain)
                .opacity(isRunning ? 1 : 0.55)
                .help(isRunning ? "Show \(tab.displayLabel)" : "Open \(tab.displayLabel)")
            }

            Button {
                workspace.toggleGroupLayout(group)
            } label: {
                Image(systemName: workspace.isGroupExpanded(group)
                    ? "rectangle.stack.fill"
                    : "square.grid.2x2")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(workspace.isGroupExpanded(group) ? Palette.running : Palette.textMuted)
                    .frame(width: 24, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.white.opacity(0.04))
                    )
            }
            .buttonStyle(.plain)
            .help(workspace.isGroupExpanded(group) ? "Collapse to tabs" : "Expand to grid")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Palette.border, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Experience badge

    private var experienceBadge: some View {
        Button {
            let name = xp.cyclePreset()
            state.showFeedback(name, autoClearAfter: 1.4)
        } label: {
            HStack(spacing: 4) {
                Text(xp.currentPreset.name)
                    .font(Typo.mono(8))
                    .foregroundColor(HUDChrome.cyan.opacity(0.75))
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(HUDChrome.cyan.opacity(0.40))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(HUDChrome.cyan.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(HUDChrome.cyan.opacity(0.22), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Cycle experience (⌥X)")
    }

    // MARK: - Layer strip (Hyprland-style workspace bar)

    private func layerStrip(_ layers: [Layer]) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { idx, layer in
                let isActive = idx == workspace.activeLayerSelection

                Button {
                    workspace.focusLayer(index: idx)
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isActive ? Palette.running : Palette.textMuted.opacity(0.3))
                            .frame(width: 5, height: 5)

                        Text(LayerSlots.slot(forIndex: idx).map(String.init) ?? "·")
                            .font(Typo.mono(9))
                            .foregroundColor(Palette.textDim)

                        Text(layer.label)
                            .font(Typo.monoBold(9))
                            .foregroundColor(isActive ? Palette.text : Palette.textMuted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .hudGlass(cornerRadius: 7, active: isActive)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Logo

    private var logo: some View {
        HStack(spacing: 7) {
            latticesGrid
            Text("lattices")
                .font(Typo.monoBold(11))
                .foregroundColor(Palette.text.opacity(0.72))
        }
    }

    /// 3×3 grid matching the menu bar icon — L-shape bright, rest dim
    private var latticesGrid: some View {
        let cellSize: CGFloat = 3
        let gap: CGFloat = 1.5
        let solidCells: Set<Int> = [0, 3, 6, 7, 8]

        return Canvas { ctx, _ in
            for row in 0..<3 {
                for col in 0..<3 {
                    let idx = row * 3 + col
                    let x = CGFloat(col) * (cellSize + gap)
                    let y = CGFloat(row) * (cellSize + gap)
                    let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                    let opacity: Double = solidCells.contains(idx) ? 0.75 : 0.18
                    ctx.fill(
                        Path(roundedRect: rect, cornerRadius: 0.5),
                        with: .color((solidCells.contains(idx) ? Palette.running : Color.white).opacity(opacity))
                    )
                }
            }
        }
        .frame(width: 3 * 3 + 2 * 1.5, height: 3 * 3 + 2 * 1.5)
    }

    // MARK: - Voice status

    private var voiceStatus: some View {
        HStack(spacing: 8) {
            // Pulsing dot + state
            Circle()
                .fill(voiceColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(voiceColor.opacity(0.4), lineWidth: 1)
                        .scaleEffect(handsOff.state == .listening ? 2.0 : 1.0)
                        .opacity(handsOff.state == .listening ? 0 : 1)
                        .animation(
                            handsOff.state == .listening
                                ? .easeOut(duration: 1.0).repeatForever(autoreverses: false)
                                : .default,
                            value: handsOff.state
                        )
                )

            Text(voiceLabel)
                .font(Typo.monoBold(9))
                .foregroundColor(voiceColor)

            // Dialogue: last user message → last response
            if let transcript = handsOff.lastTranscript {
                Rectangle().fill(Palette.border).frame(width: 0.5, height: 16)

                // What user said
                HStack(spacing: 3) {
                    Text("you")
                        .font(Typo.monoBold(8))
                        .foregroundColor(Palette.textMuted)
                    Text(transcript)
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)
                }
                .frame(maxWidth: 300, alignment: .leading)
            }

            if let response = handsOff.lastResponse {
                // What Lattices said back
                HStack(spacing: 3) {
                    Text("→")
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.running)
                    Text(response)
                        .font(Typo.mono(9))
                        .foregroundColor(Palette.textMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: 350, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(voiceColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(voiceColor.opacity(0.24), lineWidth: 0.5)
                )
        )
    }

    private var voiceColor: Color {
        switch handsOff.state {
        case .idle:       return Palette.running
        case .connecting: return Palette.detach
        case .listening:  return Palette.running
        case .thinking:   return Palette.detach
        }
    }

    private var voiceLabel: String {
        switch handsOff.state {
        case .idle:       return "ready"
        case .connecting: return "connecting"
        case .listening:  return "listening"
        case .thinking:   return "thinking"
        }
    }

    // MARK: - Quick action button

    private func quickAction(icon: String, label: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(Typo.mono(10))
            }
            .foregroundColor(Palette.text.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .hudGlass(cornerRadius: 8)
        }
        .buttonStyle(.plain)
        .help("\(label) (\(shortcut))")
    }
}
