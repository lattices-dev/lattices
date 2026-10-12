import SwiftUI

// MARK: - HUDLeftBar

struct HUDLeftBar: View {
    @ObservedObject var state: HUDState
    @ObservedObject private var scanner = ProjectScanner.shared
    @ObservedObject private var desktop = DesktopModel.shared
    @ObservedObject private var workspace = WorkspaceManager.shared
    @ObservedObject private var liveTabs = LiveTabGroupStore.shared
    @ObservedObject private var xp = HUDExperienceStore.shared
    @FocusState private var searchFieldFocused: Bool
    @State private var resizeStartWidth: CGFloat?
    @State private var isSearchHovered: Bool = false
    @State private var hoveredSectionKey: Int?
    @State private var hoveredItemID: String?
    @State private var hoveredLayerID: String?
    @State private var previewClearWorkItem: DispatchWorkItem?
    var onDismiss: () -> Void

    // Section definitions: (number key, title, icon, items builder)
    private struct SectionDef {
        let key: Int        // number-key jump
        let title: String
        let icon: String
        let items: [HUDItem]
    }

    private struct FooterHint: Identifiable {
        let key: String
        let label: String
        var id: String { "\(key)-\(label)" }
    }

    private var footerHints: [FooterHint] {
        [
            FooterHint(key: "⇧↕", label: "Range"),
            FooterHint(key: "⌘", label: "Multi"),
            FooterHint(key: "⇥", label: "Focus"),
            FooterHint(key: "↵", label: "Go"),
            FooterHint(key: "⌥A", label: "Jump"),
            FooterHint(key: "[ ]", label: "Layer"),
        ]
    }

    private var sections: [SectionDef] {
        [
            SectionDef(key: 1, title: "Projects", icon: "folder.fill", items: filteredProjects.map { .project($0) }),
            SectionDef(key: 2, title: "Windows",  icon: "macwindow",   items: filteredWindows.map { .window($0) }),
        ]
    }

    private var visibleItems: [HUDItem] {
        sections
            .filter { state.isSectionExpanded($0.key) }
            .flatMap(\.items)
    }

    // MARK: - Filters

    private var filteredProjects: [Project] {
        let q = state.query.lowercased()
        if q.isEmpty { return scanner.projects }
        return scanner.projects.filter {
            $0.name.lowercased().contains(q) ||
            $0.paneSummary.lowercased().contains(q)
        }
    }

    /// All desktop windows, sorted by z-order (front-to-back)
    /// Filters out: Lattices itself, windows with no title, and windows whose title is just the app name
    private var filteredWindows: [WindowEntry] {
        let q = state.query.lowercased()
        return desktop.allWindows()
            .filter { $0.app != "Lattices" }
            .filter { !$0.title.isEmpty }
            .filter { $0.title != $0.app } // skip helper windows titled "Cursor", "Codex", etc.
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.app.lowercased().contains(q) }
            .sorted { lhs, rhs in
                let lhsDate = desktop.lastInteractionDate(for: lhs.wid) ?? .distantPast
                let rhsDate = desktop.lastInteractionDate(for: rhs.wid) ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return lhs.zIndex < rhs.zIndex
            }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            searchBar

            HUDHairline(opacity: 0.85)

            if let group = liveTabs.activeGroup {
                liveTabDeck(group)
                HUDHairline(opacity: 0.85)
            }

            // Tile mode banner
            if state.tileMode {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.split.2x2")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.running)
                    Text("TILE MODE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Palette.running)
                    Spacer()
                    Text("H/J/K/L to place · ⎋ done")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.42))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Palette.running.opacity(0.08))

                HUDHairline(opacity: 0.8)
            }

            // Scrollable sections
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Sections
                        ForEach(sections, id: \.key) { sec in
                            sectionView(sec, proxy: proxy)
                        }

                        // Layers (at bottom, scroll to find)
                        if let layers = workspace.config?.layers, !layers.isEmpty {
                            layersSection(layers)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 11)
                }
                .onChange(of: state.selectedIndex) { _ in
                    let items = visibleItems
                    if let item = items[safe: state.selectedIndex] {
                        proxy.scrollTo(item.id, anchor: .center)
                    }
                }
            }

            HUDHairline(opacity: 0.75)

            // Minimap (pinned at bottom, docked mode only)
            if state.minimapMode == .docked {
                minimapDocked
            }

            HUDHairline(opacity: 0.65)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(HUDPanelBackground())
        .overlay(alignment: .trailing) {
            // Only show the vertical hairline when chrome is on (adjacent to desktop, not floating)
            if xp.showChrome {
                HUDHairline(axis: .vertical, opacity: 0.8)
            }
        }
        .overlay(alignment: .trailing) {
            resizeHandle
        }
        .clipShape(
            RoundedRectangle(cornerRadius: xp.showChrome ? 0 : 14, style: .continuous)
        )
        .hudEdgeGlow()
        .onAppear { syncState() }
        .onChange(of: state.query) { _ in
            state.selectedIndex = 0
            syncState()
        }
        .onChange(of: state.expandedSections) { _ in
            syncState()
        }
        .onChange(of: state.focus) { focus in
            let shouldFocusSearch = focus == .search
            guard searchFieldFocused != shouldFocusSearch else { return }
            DispatchQueue.main.async {
                searchFieldFocused = shouldFocusSearch
            }
        }
        .onChange(of: searchFieldFocused) { isFocused in
            if isFocused {
                state.focus = .search
            } else if state.focus == .search {
                state.focus = .list
            }
        }
        .onReceive(scanner.objectWillChange) { _ in
            DispatchQueue.main.async { syncState() }
        }
        .onReceive(desktop.objectWillChange) { _ in
            DispatchQueue.main.async { syncState() }
        }
        .task {
            DispatchQueue.main.async {
                searchFieldFocused = state.focus == .search
            }
        }
    }

    // MARK: - Live tab deck

    /// The HUD sidebar is always present, even in freeform/no-chrome presets.
    /// Give live cross-app tabs a proper home here instead of relying on the
    /// compact top strip, which is intentionally hidden by some HUD experiences.
    private func liveTabDeck(_ group: LiveTabGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(HUDChrome.cyan.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(HUDChrome.cyan)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("LIVE TAB STACK")
                        .font(Typo.monoBold(8))
                        .tracking(1.1)
                        .foregroundStyle(HUDChrome.cyan.opacity(0.82))
                    Text(group.name)
                        .font(Typo.heading(12))
                        .foregroundStyle(Palette.text)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text("\(group.members.count) TABS")
                    .font(Typo.monoBold(8))
                    .foregroundStyle(Palette.textDim)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(HUDChrome.glassStrokeSoft, lineWidth: 0.5))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                        liveTabCard(member, index: index, group: group)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }

            HStack(spacing: 7) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(group.isExpanded ? Palette.detach : Palette.running)
                        .frame(width: 5, height: 5)
                        .shadow(color: (group.isExpanded ? Palette.detach : Palette.running).opacity(0.65), radius: 4)
                    Text(group.isExpanded ? "SPLIT VIEW" : "STACKED · TOP LEFT")
                        .font(Typo.monoBold(8))
                        .foregroundStyle(Palette.textDim)
                }

                Spacer()

                liveTabControl(
                    icon: group.isExpanded ? "rectangle.stack.fill" : "rectangle.split.2x1",
                    label: group.isExpanded ? "TABS" : "SPLIT",
                    active: group.isExpanded
                ) {
                    liveTabs.toggleLayout(id: group.id)
                }

                liveTabControl(icon: "xmark", label: "UNGROUP", destructive: true) {
                    liveTabs.delete(id: group.id)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [HUDChrome.cyan.opacity(0.10), Color.white.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [HUDChrome.cyan.opacity(0.46), HUDChrome.glassStrokeSoft],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                )
        )
        .shadow(color: HUDChrome.cyan.opacity(0.08), radius: 14, y: 4)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeOut(duration: 0.18), value: group.id)
    }

    private func liveTabCard(_ member: LiveTabMember, index: Int, group: LiveTabGroup) -> some View {
        let selected = group.selectedIndex == index
        return Button {
            liveTabs.select(groupID: group.id, index: index)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: liveTabIcon(for: member.app))
                        .font(.system(size: 11, weight: .semibold))
                    Text(member.app)
                        .font(Typo.monoBold(9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Circle()
                            .fill(HUDChrome.onSignal)
                            .frame(width: 5, height: 5)
                    }
                }

                Text(member.label)
                    .font(Typo.caption(9))
                    .lineLimit(1)
                    .foregroundStyle(selected ? HUDChrome.onSignal.opacity(0.70) : Palette.textMuted)
            }
            .foregroundStyle(selected ? HUDChrome.onSignal : Palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(width: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(HUDChrome.activeGradient) : AnyShapeStyle(Color.white.opacity(0.045)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.white.opacity(0.28) : HUDChrome.glassStrokeSoft, lineWidth: 0.6)
                    )
            )
            .shadow(color: selected ? HUDChrome.cyan.opacity(0.20) : .clear, radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("Show \(member.app): \(member.label)")
    }

    private func liveTabControl(
        icon: String,
        label: String,
        active: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                Text(label)
                    .font(Typo.monoBold(8))
            }
            .foregroundStyle(destructive ? Palette.kill.opacity(0.86) : (active ? HUDChrome.onSignal : Palette.textDim))
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? HUDChrome.cyan : Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(destructive ? Palette.kill.opacity(0.18) : HUDChrome.glassStrokeSoft, lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func liveTabIcon(for app: String) -> String {
        let value = app.lowercased()
        if value.contains("terminal") || value.contains("iterm") || value.contains("warp") {
            return "terminal.fill"
        }
        if value.contains("chrome") || value.contains("safari") || value.contains("firefox") || value.contains("arc") {
            return "globe"
        }
        if value.contains("xcode") || value.contains("code") || value.contains("cursor") || value.contains("zed") {
            return "chevron.left.forwardslash.chevron.right"
        }
        return "macwindow"
    }

    /// Push flat items + section offsets to state so HUDController's key handler can use them
    private func syncState() {
        state.syncAutoSectionDefaults(hasRunningProjects: scanner.projects.contains(where: \.isRunning))
        let secs = sections
        var flat = [HUDItem]()
        var offsets = [Int: Int]()
        for sec in secs {
            guard state.isSectionExpanded(sec.key) else { continue }
            if !sec.items.isEmpty {
                offsets[sec.key] = flat.count
            }
            flat.append(contentsOf: sec.items)
        }
        state.flatItems = flat
        state.sectionOffsets = offsets
        state.reconcileSelection(with: flat)

        // Assign ⌥+letter jump hints over the full filtered window list (independent
        // of section expansion) so the on-window badges work even when collapsed.
        let windowWids = filteredWindows.map(\.wid)
        let hints = HUDWindowHintAssigner.assign(orderedWids: windowWids)
        if state.windowHints != hints {
            state.windowHints = hints
        }
    }

    private var resizeHandle: some View {
        ZStack {
            Color.clear
            VStack(spacing: 4) {
                Capsule()
                    .fill(HUDChrome.cyan.opacity(0.55))
                    .frame(width: 2, height: 28)
                Capsule()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 2, height: 18)
            }
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if resizeStartWidth == nil {
                        resizeStartWidth = state.leftSidebarWidth
                    }
                    let base = resizeStartWidth ?? state.leftSidebarWidth
                    state.setLeftSidebarWidth(base + value.translation.width)
                }
                .onEnded { _ in
                    resizeStartWidth = nil
                }
        )
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(state.focus == .search ? HUDChrome.cyan : Palette.textMuted.opacity(0.85))

            ZStack(alignment: .leading) {
                if state.query.isEmpty {
                    Text(state.focus == .search ? "Type to search..." : "/ to search")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Palette.textMuted)
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.query)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Palette.text)
                    .textFieldStyle(.plain)
                    .focused($searchFieldFocused)
                    .onTapGesture {
                        state.focus = .search
                        searchFieldFocused = true
                    }
                    .onSubmit { activateSelected() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !state.query.isEmpty {
                Button {
                    state.query = ""
                    state.selectedIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
        .background(searchBarBackground)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            state.focus = .search
            searchFieldFocused = true
        }
        .onHover { isHovering in
            isSearchHovered = isHovering
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func sectionView(_ sec: SectionDef, proxy: ScrollViewProxy) -> some View {
        if !sec.items.isEmpty {
            let isExpanded = state.isSectionExpanded(sec.key)
            let isHovered = hoveredSectionKey == sec.key
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    state.toggleSection(sec.key)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Palette.textMuted)
                            .frame(width: 10, alignment: .center)

                        Image(systemName: sec.icon)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(isExpanded ? HUDChrome.cyan.opacity(0.9) : Palette.textMuted)
                        Text(sec.title)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isExpanded ? Palette.text.opacity(0.88) : Palette.textMuted.opacity(0.9))
                        Text("\(sec.items.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Palette.textDim)
                        Spacer()
                        shortcutBadge("\(sec.key)")
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isHovered ? Color.white.opacity(0.045) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { isHovering in
                    hoveredSectionKey = isHovering ? sec.key : (hoveredSectionKey == sec.key ? nil : hoveredSectionKey)
                }

                if isExpanded {
                    ForEach(sec.items) { item in
                        itemRow(item)
                            .id(item.id)
                    }
                }
            }
        }
    }

    // MARK: - Item row

    private func itemRow(_ item: HUDItem) -> some View {
        let isSelected = state.selectedItem == item && state.focus == .list
        let isMultiSelected = state.selectedItems.contains(item.id)
        let isTiled = state.tileMode && {
            if case .window(let w) = item { return state.tiledWindows.contains(w.wid) }
            return false
        }()
        let subtitleText = subtitle(for: item)
        let isHovered = hoveredItemID == item.id
        let rowFill: Color = {
            if isTiled { return Palette.running.opacity(0.14) }
            if isMultiSelected { return HUDChrome.cyan.opacity(0.13) }
            if isSelected { return Color.white.opacity(0.085) }
            if isHovered { return Color.white.opacity(0.055) }
            if state.selectedItem == item { return Color.white.opacity(0.045) }
            return Color.clear
        }()
        let rowStroke: Color = {
            if isTiled { return Palette.running.opacity(0.45) }
            if isMultiSelected { return HUDChrome.cyan.opacity(0.38) }
            if isSelected { return HUDChrome.cyan.opacity(0.42) }
            if isHovered { return Color.white.opacity(0.16) }
            return Color.clear
        }()

        return Button {
            state.focus = .list
            guard let idx = visibleItems.firstIndex(of: item) else { return }

            let modifiers = NSEvent.modifierFlags.intersection([.shift, .command])
            if modifiers.contains(.shift) {
                state.selectRange(to: item, index: idx, in: visibleItems)
            } else if modifiers.contains(.command) {
                state.toggleSelection(item, index: idx, in: visibleItems)
            } else {
                state.selectSingle(item, index: idx)
                state.pinInspector(item, source: "row")
            }
        } label: {
            HStack(spacing: 10) {
                statusDot(for: item)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)

                    if let subtitleText {
                        Text(subtitleText)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(Palette.textDim)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if case .window(let w) = item, let hint = state.windowHints[w.wid] {
                    windowHintBadge(hint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(rowFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(rowStroke, lineWidth: isSelected ? 0.8 : 0.5)
                    )
            )
            .overlay(alignment: .leading) {
                if isSelected || isMultiSelected || isTiled {
                    Capsule()
                        .fill(isTiled ? LinearGradient(colors: [Palette.running, Palette.running], startPoint: .top, endPoint: .bottom) : HUDChrome.activeGradient)
                        .frame(width: 3, height: 24)
                        .padding(.leading, 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            itemContextMenu(item)
        }
        .onHover { isHovering in
            hoveredItemID = isHovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
            if isHovering {
                previewClearWorkItem?.cancel()
                state.hoveredPreviewItem = item
                state.hoverPreviewAnchorScreenY = NSEvent.mouseLocation.y
                prefetchPreview(for: item)
            } else if state.hoveredPreviewItem == item {
                let hoveredItemID = item.id
                let clearWorkItem = DispatchWorkItem {
                    guard self.state.hoveredPreviewItem?.id == hoveredItemID,
                          !self.state.previewInteractionActive else { return }
                    self.state.hoveredPreviewItem = nil
                    self.state.hoverPreviewAnchorScreenY = nil
                }
                previewClearWorkItem = clearWorkItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: clearWorkItem)
            }
        }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: HUDItem) -> some View {
        let groupableWindows = selectedWindowsForTabGroup(including: item)
        let isInSelection = state.effectiveSelectionIDs.contains(item.id)

        if groupableWindows.count >= 2 {
            Button {
                createTabGroup(from: groupableWindows)
            } label: {
                Label("Create Tab Group from \(groupableWindows.count) Windows", systemImage: "rectangle.stack")
            }

            if liveTabs.activeGroup != nil {
                Button {
                    let count = liveTabs.add(windowIDs: groupableWindows.map(\.wid))
                    state.showFeedback("Added \(count) window\(count == 1 ? "" : "s") to \(liveTabs.activeGroup?.name ?? "tab group")", autoClearAfter: 1.6)
                } label: {
                    Label("Add Selection to Active Tab Group", systemImage: "plus.rectangle.on.rectangle")
                }
            }

            Divider()
        }

        Button {
            guard let index = visibleItems.firstIndex(of: item) else { return }
            state.toggleSelection(item, index: index, in: visibleItems)
        } label: {
            Label(isInSelection ? "Remove from Selection" : "Add to Selection",
                  systemImage: isInSelection ? "minus.circle" : "plus.circle")
        }

        if state.multiSelectionCount > 1 {
            Button(role: .destructive) {
                state.clearMultiSelection()
            } label: {
                Label("Clear Selection", systemImage: "xmark.circle")
            }
        }
    }

    private func selectedWindowsForTabGroup(including item: HUDItem) -> [WindowEntry] {
        var ids = state.effectiveSelectionIDs
        ids.insert(item.id)
        var seen = Set<UInt32>()
        return visibleItems.compactMap { candidate -> WindowEntry? in
            guard ids.contains(candidate.id) else { return nil }
            let window: WindowEntry?
            switch candidate {
            case .window(let entry):
                window = entry
            case .project(let project):
                window = project.isRunning ? desktop.windowForSession(project.sessionName) : nil
            }
            guard let window, seen.insert(window.wid).inserted else { return nil }
            return window
        }
    }

    private func createTabGroup(from windows: [WindowEntry]) {
        guard windows.count >= 2 else { return }
        let screen = windows.first.map { WindowTiler.screenForWindowFrame($0.frame) }
        liveTabs.captureCandidateSelection(windows.map(\.wid))
        guard let group = liveTabs.create(
            windowIDs: windows.map(\.wid),
            placement: .tile(.topLeft),
            screen: screen
        ) else {
            state.showFeedback("Couldn’t create tab group", autoClearAfter: 1.4)
            return
        }
        state.clearMultiSelection()
        state.showFeedback("Tab group created · \(group.name)", autoClearAfter: 1.8)
    }

    private func statusDot(for item: HUDItem) -> some View {
        ZStack {
            Circle()
                .fill(dotColor(for: item).opacity(0.18))
                .frame(width: 15, height: 15)
            Circle()
                .fill(dotColor(for: item))
                .frame(width: 6, height: 6)
        }
    }

    private func dotColor(for item: HUDItem) -> Color {
        switch item {
        case .project(let p): return p.isRunning ? Palette.running : Palette.textMuted.opacity(0.3)
        case .window:         return Palette.textDim
        }
    }

    private func subtitle(for item: HUDItem) -> String? {
        switch item {
        case .project(let p):
            return p.paneSummary.isEmpty ? nil : p.paneSummary
        case .window(let w):
            return w.app
        }
    }

    private func prefetchPreview(for item: HUDItem) {
        switch item {
        case .window(let window):
            WindowPreviewStore.shared.load(window: window)
        case .project(let project):
            guard project.isRunning,
                  let window = desktop.windowForSession(project.sessionName) else { return }
            WindowPreviewStore.shared.load(window: window)
        }
    }

    // MARK: - Layers section (at bottom)

    private func layersSection(_ layers: [Layer]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(HUDChrome.amber.opacity(0.9))
                Text("Layers")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Palette.text.opacity(0.86))
                Text("\(layers.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Palette.textDim)
                Spacer()
                shortcutBadge("[ ]")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)

            let windowCounts = workspace.layerWindowCounts()
            ForEach(Array(layers.enumerated()), id: \.element.id) { idx, layer in
                let isActive = idx == workspace.activeLayerSelection
                let count = windowCounts.indices.contains(idx) ? windowCounts[idx] : 0
                let isHovered = hoveredLayerID == layer.id

                Button {
                    workspace.focusLayer(index: idx)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(isActive ? HUDChrome.activeGradient : LinearGradient(colors: [Palette.textMuted.opacity(0.25), Palette.textMuted.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(layer.label)
                                .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isActive ? Palette.text : Palette.textMuted)
                                .lineLimit(1)

                            Text(LayerOverview.countNote(count))
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(Palette.textDim)
                        }

                        Spacer()

                        Text(LayerSlots.slot(forIndex: idx).map(String.init) ?? "·")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(isActive ? Palette.text : Palette.textDim)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isActive ? Palette.running.opacity(0.15) : Palette.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .strokeBorder(isActive ? Palette.running.opacity(0.3) : Palette.border, lineWidth: 0.5)
                                    )
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudGlass(cornerRadius: 9, active: isActive, hovered: isHovered)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onHover { isHovering in
                    hoveredLayerID = isHovering ? layer.id : (hoveredLayerID == layer.id ? nil : hoveredLayerID)
                }
            }
        }
    }

    // MARK: - Docked minimap

    private var minimapDocked: some View {
        let screen: NSScreen? = NSScreen.screens.first
        let mapWidth: CGFloat = 300 // full sidebar width minus padding
        let mapHeight: CGFloat = 140

        return VStack(alignment: .leading, spacing: 0) {
            minimapHeader

            if let screen {
                minimapCanvas(screen: screen, mapWidth: mapWidth, mapHeight: mapHeight)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        )
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    private var minimapHeader: some View {
        HStack(spacing: 0) {
            Image(systemName: "map")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Palette.textMuted)
            Text("Map")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Palette.textMuted.opacity(0.9))
                .padding(.leading, 4)

            Spacer()

            // Expand out to canvas
            Button {
                state.minimapMode = .expanded
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Palette.textMuted)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.surface)
                    )
            }
            .buttonStyle(.plain)
            .help("Expand map (M)")

            // Hide
            Button {
                state.minimapMode = .hidden
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Palette.textMuted)
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.surface)
                    )
            }
            .buttonStyle(.plain)
            .help("Hide map (M)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func minimapCanvas(screen: NSScreen, mapWidth: CGFloat, mapHeight: CGFloat) -> some View {
        let sw = screen.frame.width
        let sh = screen.frame.height
        let scale = min(mapWidth / sw, mapHeight / sh)
        let drawW = sw * scale
        let drawH = sh * scale
        let offsetX = (mapWidth - drawW) / 2
        let offsetY = (mapHeight - drawH) / 2
        let origin = screenCGOrigin(screen)
        let wins = windowsOnScreen(0)

        return ZStack(alignment: .topLeading) {
            // Screen background
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
                .frame(width: drawW, height: drawH)
                .offset(x: offsetX, y: offsetY)

            // Windows (back-to-front)
            ForEach(wins.reversed()) { win in
                minimapWindowCell(win: win, scale: scale, origin: origin, offsetX: offsetX, offsetY: offsetY)
            }
        }
        .frame(width: mapWidth, height: mapHeight)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func minimapWindowCell(
        win: WindowEntry,
        scale: CGFloat,
        origin: (x: CGFloat, y: CGFloat),
        offsetX: CGFloat,
        offsetY: CGFloat
    ) -> some View {
        let rx = (CGFloat(win.frame.x) - origin.x) * scale + offsetX
        let ry = (CGFloat(win.frame.y) - origin.y) * scale + offsetY
        let rw = CGFloat(win.frame.w) * scale
        let rh = CGFloat(win.frame.h) * scale
        let isSelected = state.selectedItem == .window(win)
        let appTint = appColor(win.app)
        let labelSize = max(6, min(9, rh * 0.35))

        return RoundedRectangle(cornerRadius: 1.5)
            .fill(appTint.opacity(isSelected ? 0.5 : 0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .strokeBorder(
                        isSelected ? Palette.running : appTint.opacity(0.35),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .overlay(
                Group {
                    if rw > 24 && rh > 14 {
                        Text(String(win.app.prefix(1)))
                            .font(.system(size: labelSize, weight: .semibold, design: .monospaced))
                            .foregroundColor(appTint.opacity(isSelected ? 1.0 : 0.5))
                    }
                }
            )
            .frame(width: max(rw, 3), height: max(rh, 2))
            .offset(x: rx, y: ry)
            .onTapGesture {
                state.focus = .list
                if let flatIdx = visibleItems.firstIndex(of: .window(win)) {
                    state.selectSingle(.window(win), index: flatIdx)
                    state.pinnedItem = .window(win)
                    state.hoveredPreviewItem = nil
                }
            }
    }

    // MARK: - Minimap helpers

    private func screenCGOrigin(_ screen: NSScreen) -> (x: CGFloat, y: CGFloat) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 900
        return (screen.frame.origin.x, primaryH - screen.frame.origin.y - screen.frame.height)
    }

    private func windowsOnScreen(_ screenIdx: Int) -> [WindowEntry] {
        let screens = NSScreen.screens
        guard screenIdx < screens.count else { return [] }
        let screen = screens[screenIdx]
        let origin = screenCGOrigin(screen)
        let sw = Double(screen.frame.width)
        let sh = Double(screen.frame.height)

        return desktop.allWindows().filter { win in
            let cx = win.frame.x + win.frame.w / 2
            let cy = win.frame.y + win.frame.h / 2
            return cx >= Double(origin.x) && cx < Double(origin.x) + sw &&
                   cy >= Double(origin.y) && cy < Double(origin.y) + sh &&
                   win.app != "Lattices"
        }
    }

    private func appColor(_ app: String) -> Color {
        if ["iTerm2", "Terminal", "WezTerm", "Alacritty", "kitty"].contains(app) {
            return Palette.running
        }
        if ["Google Chrome", "Safari", "Arc", "Firefox", "Brave Browser"].contains(app) {
            return Color.blue
        }
        if ["Xcode", "Visual Studio Code", "Cursor", "Zed"].contains(app) {
            return Color.purple
        }
        if app.localizedCaseInsensitiveContains("Claude") || app.localizedCaseInsensitiveContains("Codex") {
            return Color.orange
        }
        return Palette.textMuted
    }

    // MARK: - Footer

    private var footer: some View {
        let selectedIDs = state.effectiveSelectionIDs
        let selectionCount = state.multiSelectionCount
        let selectedProjects = visibleItems.compactMap { item -> Project? in
            guard selectedIDs.contains(item.id), case .project(let project) = item else { return nil }
            return project
        }
        let selectedWindows = visibleItems.compactMap { item -> WindowEntry? in
            guard selectedIDs.contains(item.id), case .window(let window) = item else { return nil }
            return window
        }

        return HStack(spacing: 10) {
            if selectionCount > 1 {
                Text("\(selectionCount) selected")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.86))
                if !selectedWindows.isEmpty || !selectedProjects.isEmpty {
                    keyBadge("T", label: "Tile")
                }
                if !selectedProjects.isEmpty {
                    keyBadge("D", label: "Detach")
                } else if selectedWindows.count > 1 {
                    keyBadge("D", label: "Distrib")
                }
            }
            footerNavigationHints(selectionActive: selectionCount > 1)

            // Experience badge (visible when no top bar)
            if !xp.showChrome && xp.presetIndex > 0 {
                Button {
                    let name = xp.cyclePreset()
                    state.showFeedback(name, autoClearAfter: 1.4)
                } label: {
                    HStack(spacing: 3) {
                        Text(xp.currentPreset.name)
                            .font(Typo.mono(8))
                            .foregroundColor(HUDChrome.cyan.opacity(0.65))
                        Image(systemName: "chevron.right.2")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundColor(HUDChrome.cyan.opacity(0.35))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(HUDChrome.cyan.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(HUDChrome.cyan.opacity(0.18), lineWidth: 0.5))
                    )
                }
                .buttonStyle(.plain)
                .help("Cycle experience (⌥X)")
            }

            Spacer()

            if state.minimapMode != .docked {
                Button {
                    state.minimapMode = .docked
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "map")
                            .font(.system(size: 8))
                        Text("M")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    }
                    .foregroundColor(state.minimapMode == .expanded ? Palette.running : Palette.textMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Palette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(state.minimapMode == .expanded ? Palette.running.opacity(0.3) : Palette.border, lineWidth: 0.5)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help("Dock map (M)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private func footerNavigationHints(selectionActive: Bool) -> some View {
        let minimapDockButtonVisible = state.minimapMode != .docked

        if selectionActive || minimapDockButtonVisible || state.leftSidebarWidth < 300 {
            footerHintRow(footerHints, labeled: false, spacing: 6)
        } else if state.leftSidebarWidth < 390 {
            VStack(alignment: .leading, spacing: 4) {
                footerHintRow(Array(footerHints.prefix(3)), labeled: true, spacing: 8)
                footerHintRow(Array(footerHints.suffix(3)), labeled: true, spacing: 8)
            }
        } else {
            footerHintRow(footerHints, labeled: true, spacing: 8)
        }
    }

    private func footerHintRow(_ hints: [FooterHint], labeled: Bool, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(hints) { hint in
                keyBadge(hint.key, label: labeled ? hint.label : nil)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func keyBadge(_ key: String, label: String? = nil) -> some View {
        HStack(spacing: label == nil ? 0 : 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(Palette.text)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.055))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Palette.textMuted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(label.map { "\($0) (\(key))" } ?? key)
    }

    /// ⌥-jump letter shown on the trailing edge of a window row, echoing the
    /// badge drawn over the window itself.
    private func windowHintBadge(_ letter: String) -> some View {
        Text(letter.uppercased())
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(HUDChrome.cyan)
            .frame(width: 19, height: 19)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(HUDChrome.cyan.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(HUDChrome.cyan.opacity(0.35), lineWidth: 0.5)
                    )
            )
    }

    private func shortcutBadge(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(Palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
    }

    private var searchBarBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                state.focus == .search
                    ? Color.white.opacity(0.075)
                    : (isSearchHovered ? Color.white.opacity(0.045) : Color.white.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        state.focus == .search
                            ? HUDChrome.cyan.opacity(0.40)
                            : (isSearchHovered ? Color.white.opacity(0.16) : Color.white.opacity(0.08)),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(state.focus == .search ? 0.22 : 0.10), radius: 10, y: 4)
    }

    // MARK: - Actions

    private func activateSelected() {
        guard let item = state.selectedItem else { return }
        activate(item)
    }

    private func activate(_ item: HUDItem) {
        switch item {
        case .project(let p):
            SessionManager.launch(project: p)
            HandsOffSession.shared.playCachedCue(p.isRunning ? "Focused." : "Done.")
        case .window(let w):
            _ = WindowTiler.focusWindow(wid: w.wid, pid: w.pid)
            HandsOffSession.shared.playCachedCue("Focused.")
        }
        onDismiss()
    }
}

// MARK: - Safe array subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
