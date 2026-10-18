pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "DesktopViews.mjs" as Views

FocusScope {
    id: mission
    required property var controller
    property int spaceFilter: -1
    readonly property var inventory: Views.inventory(controller.state)
    readonly property var spaces: Views.spaceInventory(controller.state.displays, inventory)
    readonly property var windows: inventory.filter(w => (spaceFilter < 0 || (w.presence !== "parked" && (w.spaceIds || []).includes(spaceFilter))) && Views.inventoryMatches(w, controller.query))
    readonly property var selected: windows.find(w => w.wid === controller.selectedWid) || null
    readonly property bool ready: controller.online && !controller.busy
    readonly property bool canFocus: ready && selected !== null && selected.presence !== "parked" && controller.state.describe?.methods?.includes("windows.focus") === true
    focus: true
    function focusTable() { table.forceActiveFocus() }
    function focusSearch() { search.forceActiveFocus(); search.selectAll() }
    function showSelection() {
        const index = windows.findIndex(w => w.wid === controller.selectedWid)
        if (index >= 0) table.positionViewAtIndex(index, ListView.Contain)
    }
    function reconcile() { if (!selected) controller.selectedWid = windows[0]?.wid ?? -1; Qt.callLater(showSelection) }
    function focusTarget() { if (canFocus) controller.call("windows.focus", { wid: selected.wid }) }
    function inspectTarget() {
        if (!selected || selected.presence === "parked") return
        controller.inspectWindow(selected)
    }
    onWindowsChanged: if (visible && controller.page === "Mission") Qt.callLater(reconcile)
    onVisibleChanged: if (visible) Qt.callLater(() => { mission.reconcile(); mission.focusTable() })
    Component.onCompleted: if (visible && controller.page === "Mission") Qt.callLater(reconcile)
    Connections {
        target: mission.controller
        function onSelectedWidChanged() { if (mission.visible && mission.controller.page === "Mission") Qt.callLater(mission.showSelection) }
    }
    Keys.onPressed: event => {
        if (search.activeFocus || event.modifiers !== Qt.NoModifier) return
        const index = windows.findIndex(w => w.wid === controller.selectedWid)
        if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            const next = Math.max(0, Math.min(windows.length - 1, index + (event.key === Qt.Key_Down ? 1 : -1)))
            if (windows[next]) { controller.selectedWid = windows[next].wid; table.positionViewAtIndex(next, ListView.Contain) }
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { focusTarget(); event.accepted = true }
        else if (event.key === Qt.Key_Escape) { controller.query = ""; spaceFilter = -1; event.accepted = true }
    }
    readonly property bool narrow: width < 680
    readonly property bool wide: width > 900
    readonly property int parkedCount: inventory.filter(w => w.presence === "parked").length
    Rectangle { anchors.fill: parent; color: Theme.pageGround }
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: mission.narrow ? 52 : 78; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 0
            Repeater {
                model: [
                    { label: "WINDOWS", value: mission.inventory.length, note: "Across all spaces", caution: false },
                    { label: "SPACES", value: mission.spaces.length, note: mission.controller.state.displays.length + (mission.controller.state.displays.length === 1 ? " display" : " displays"), caution: false },
                    { label: "SESSIONS", value: mission.controller.state.sessions.length, note: "tmux running", caution: false },
                    { label: "PARKED", value: mission.parkedCount, note: "Put away by layers", caution: mission.parkedCount > 0 }
                ]
                Item {
                    id: metric
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true; Layout.fillHeight: true; Layout.preferredWidth: 100
                    Accessible.name: modelData.label + " " + modelData.value
                    Rectangle { visible: metric.index > 0; width: 1; height: parent.height - (mission.narrow ? 20 : 28); anchors.verticalCenter: parent.verticalCenter; color: Theme.border }
                    ColumnLayout {
                        anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: metric.index > 0 ? (mission.narrow ? 12 : 20) : 0; anchors.rightMargin: 8
                        spacing: mission.narrow ? 1 : 3
                        DeckLabel { text: metric.modelData.label; color: metric.modelData.caution ? Theme.caution : Theme.muted }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            AppText { id: numeral; text: metric.modelData.value; mono: true; font.pixelSize: mission.narrow ? 20 : 30; font.weight: Font.ExtraLight; color: metric.modelData.caution ? Theme.caution : metric.modelData.value === 0 ? Theme.dim : Theme.text }
                            AppText { visible: !mission.narrow; text: metric.modelData.note; font.pixelSize: Theme.small; color: Theme.muted; Layout.fillWidth: true; Layout.alignment: Qt.AlignBaseline; elide: Text.ElideRight }
                        }
                    }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        GridLayout {
            Layout.fillWidth: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; Layout.topMargin: 10; Layout.bottomMargin: 10
            columns: mission.wide ? 2 : 1; columnSpacing: 16; rowSpacing: 8
            RowLayout {
                Layout.fillWidth: true; Layout.preferredWidth: 420; spacing: 6
                InputField {
                    id: search; objectName: "missionSearch"
                    Layout.fillWidth: true; implicitHeight: 32; prompt: "/"; keycap: "Ctrl K"
                    placeholderText: mission.narrow ? "Filter by title, app, ID or layer" : "Filter by title, app, window ID or layer"
                    font.family: Theme.mono; font.pixelSize: Theme.base; text: mission.controller.query
                    Accessible.name: "Filter the window inventory"
                    onTextEdited: mission.controller.query = text
                    onAccepted: { mission.focusTable(); mission.focusTarget() }
                    Keys.onEscapePressed: { mission.controller.query = ""; mission.spaceFilter = -1; mission.focusTable() }
                }
                DeckButton { text: "Clear"; quiet: true; implicitHeight: 32; keycap: mission.narrow ? "" : "Esc"; enabled: mission.spaceFilter >= 0 || mission.controller.query !== ""; Accessible.name: "Clear filters"; onClicked: { mission.spaceFilter = -1; mission.controller.query = ""; mission.focusTable() } }
            }
            RowLayout {
                Layout.fillWidth: true; Layout.preferredWidth: 420; spacing: 6
                DeckButton { text: "All spaces"; implicitHeight: 32; selected: mission.spaceFilter < 0; Layout.minimumWidth: implicitWidth; onClicked: { mission.spaceFilter = -1; mission.focusTable() } }
                Flickable {
                    Layout.fillWidth: true; Layout.preferredHeight: 32; contentWidth: cards.width; contentHeight: height; clip: true
                    Row {
                        id: cards; spacing: 4
                        Repeater {
                            model: mission.spaces
                            SpaceCell {
                                required property var modelData
                                spaceId: modelData.id; count: modelData.visibleCount; current: modelData.isCurrent
                                suffix: mission.controller.state.displays.length > 1 ? " / " + modelData.displayId : ""
                                selected: mission.spaceFilter === modelData.id
                                onClicked: { mission.spaceFilter = modelData.id; mission.focusTable() }
                                ToolTip.visible: hovered; ToolTip.text: "Filter inventory to space " + modelData.id + " on " + modelData.displayId
                            }
                        }
                    }
                }
                DeckButton { objectName: "missionGoSpace"; visible: mission.spaceFilter > 0; text: "Go to space"; implicitHeight: 32; selected: true; Layout.minimumWidth: implicitWidth; enabled: mission.ready && mission.controller.state.describe?.methods?.includes("spaces.focus") === true; onClicked: mission.controller.call("spaces.focus", { workspace: mission.spaceFilter }) }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 16
            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: 30; Layout.leftMargin: 12; Layout.rightMargin: 12; spacing: 12
                    DeckLabel { text: "WINDOW"; Layout.preferredWidth: table.tabular ? 168 : -1 }
                    DeckLabel { visible: table.tabular; text: "TITLE"; color: Theme.dim }
                    Item { Layout.fillWidth: true }
                    DeckLabel { visible: table.width > 700; text: "LAYER"; color: Theme.dim; Layout.preferredWidth: 150 }
                    DeckLabel { text: "SPACE"; color: Theme.dim; Layout.preferredWidth: 64 }
                    DeckLabel { text: "ID"; color: Theme.dim; Layout.preferredWidth: table.width < 460 ? 72 : 88; horizontalAlignment: Text.AlignRight }
                    Item { visible: table.width > 460; implicitWidth: 70 }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.borderLit }
                ListView {
                    id: table; objectName: "missionTable"
                    readonly property bool tabular: width >= 620
                    Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumHeight: 70
                    clip: true; spacing: 0; model: mission.windows; keyNavigationEnabled: false
                    Accessible.name: "Window inventory"
                    ScrollBar.vertical: ScrollBar {}
                    delegate: Button {
                        id: row
                        required property var modelData
                        readonly property bool chosen: mission.controller.selectedWid === modelData.wid
                        readonly property bool parked: modelData.presence === "parked"
                        width: ListView.view.width; height: table.tabular ? 40 : 46; padding: 0
                        Accessible.name: mission.controller.appName(modelData.app) + ", " + modelData.title + ", " + modelData.presence
                        onClicked: { mission.controller.selectedWid = modelData.wid; mission.focusTable() }
                        background: Rectangle {
                            color: row.chosen ? Theme.accentSoft : row.hovered ? Theme.film : "transparent"
                            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                            // The wash and bar are the selection; the frame means the keyboard is in the table.
                            Rectangle { visible: row.chosen; anchors.fill: parent; color: "transparent"; border.color: table.activeFocus ? Theme.accent : Theme.accentLine }
                            Rectangle { visible: row.chosen; width: 2; height: parent.height; color: Theme.accent }
                        }
                        contentItem: RowLayout {
                            spacing: 12
                            AppText { visible: table.tabular; text: mission.controller.appName(row.modelData.app); font.pixelSize: Theme.lead; font.weight: Font.Medium; color: row.parked ? Theme.muted : Theme.text; Layout.leftMargin: 12; Layout.preferredWidth: 168; elide: Text.ElideRight }
                            AppText { visible: table.tabular; text: row.modelData.title; font.pixelSize: Theme.base; color: row.chosen ? Theme.body : Theme.muted; Layout.fillWidth: true; elide: Text.ElideMiddle }
                            ColumnLayout {
                                visible: !table.tabular
                                Layout.fillWidth: true; Layout.leftMargin: 12; spacing: 3
                                AppText { text: mission.controller.appName(row.modelData.app); font.pixelSize: Theme.lead; font.weight: Font.Medium; color: row.parked ? Theme.muted : Theme.text; Layout.fillWidth: true; elide: Text.ElideRight }
                                AppText { text: row.modelData.title; font.pixelSize: 11; color: Theme.muted; Layout.fillWidth: true; elide: Text.ElideMiddle }
                            }
                            AppText { visible: table.width > 700; text: row.modelData.layerNames.join(" · ") || "—"; mono: true; font.pixelSize: 11; color: row.modelData.layerNames.length ? Theme.body : Theme.dim; Layout.preferredWidth: 150; elide: Text.ElideRight }
                            Item {
                                Layout.preferredWidth: 64; implicitHeight: 17
                                Tag { visible: row.parked; text: "PARKED"; tone: Theme.caution }
                                AppText { visible: !row.parked; anchors.verticalCenter: parent.verticalCenter; text: row.modelData.spaceIds.map(id => String(id).padStart(2, "0")).join(", "); mono: true; font.pixelSize: Theme.base; color: Theme.body }
                            }
                            AppText { text: String(row.modelData.wid); mono: true; font.pixelSize: 11; color: Theme.muted; Layout.preferredWidth: table.width < 460 ? 72 : 88; horizontalAlignment: Text.AlignRight; elide: Text.ElideLeft; Layout.rightMargin: table.width > 460 ? 0 : 12 }
                            Item {
                                visible: table.width > 460
                                implicitWidth: 70; implicitHeight: 17; Layout.rightMargin: 12
                                Row {
                                    visible: row.modelData.isFocused === true
                                    anchors.verticalCenter: parent.verticalCenter; spacing: 6
                                    Rectangle { width: 5; height: 5; radius: 3; color: Theme.live; anchors.verticalCenter: parent.verticalCenter }
                                    AppText { text: "FOCUSED"; mono: true; font.pixelSize: Theme.caption; font.letterSpacing: 0.9; color: Theme.live }
                                }
                            }
                        }
                    }
                    ColumnLayout {
                        visible: mission.windows.length === 0
                        anchors.centerIn: parent; spacing: 6
                        AppText { text: "No windows match this filter"; color: Theme.text; font.pixelSize: 14; Layout.alignment: Qt.AlignHCenter }
                        AppText { text: "Press Esc to show every space."; color: Theme.muted; font.pixelSize: 12; Layout.alignment: Qt.AlignHCenter }
                    }
                }
                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.borderLit }
                RowLayout {
                    Layout.fillWidth: true; Layout.preferredHeight: 48; spacing: 8
                    DeckButton { text: "Focus"; keycap: "↵"; primary: true; implicitHeight: 32; enabled: mission.canFocus; Accessible.name: "Focus selected window"; onClicked: mission.focusTarget() }
                    DeckButton { text: "Flight Deck"; implicitHeight: 32; enabled: mission.selected !== null && mission.selected.presence !== "parked"; Accessible.name: "Show selected window in Flight Deck"; onClicked: mission.inspectTarget() }
                    Tag { visible: mission.selected?.presence === "parked"; text: "PARKED"; tone: Theme.caution; Layout.leftMargin: 6 }
                    AppText {
                        text: mission.selected?.presence === "parked" ? "Restore from its original space" : mission.selected ? "Window " + mission.selected.wid : "Select a window"
                        mono: true; font.pixelSize: Theme.small; color: mission.selected?.presence === "parked" ? Theme.caution : Theme.muted
                        Layout.fillWidth: true; Layout.leftMargin: mission.selected?.presence === "parked" ? 0 : 6; elide: Text.ElideRight
                    }
                    AppText { text: mission.windows.length + " of " + mission.inventory.length + " shown"; mono: true; font.pixelSize: 10; color: Theme.dim; Layout.rightMargin: 12 }
                }
            }
            Rectangle { visible: mission.wide; implicitWidth: 1; Layout.fillHeight: true; color: Theme.border }
            ScrollView {
                id: rail
                visible: mission.wide; Layout.preferredWidth: 270; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
                ColumnLayout {
                    width: rail.availableWidth; spacing: 8
                    SectionHeader {
                        title: "LAYERS"; Layout.fillWidth: true; Layout.preferredHeight: 30
                        DeckButton { text: "Manage"; quiet: true; implicitHeight: 24; Accessible.name: "Manage layers"; onClicked: mission.controller.page = "Layers" }
                    }
                    Repeater {
                        model: mission.controller.state.layers || []
                        DeckButton {
                            required property var modelData
                            Layout.fillWidth: true; text: modelData.label; align: Text.AlignLeft
                            hollowDot: true; dot: modelData.active ? Theme.live : "transparent"; note: modelData.active ? "ACTIVE" : ""; noteInk: Theme.live
                            enabled: mission.ready && !mission.controller.state.layersError && mission.controller.state.describe?.methods?.includes("layers.activate") === true
                            Accessible.name: modelData.label + (modelData.active ? ", active layer" : ", layer")
                            onClicked: mission.controller.call("layers.activate", { layer: modelData.id, mode: "tile" })
                            ToolTip.visible: hovered; ToolTip.text: "Activate on the current desktop"
                        }
                    }
                    AppText { visible: !(mission.controller.state.layers || []).length; text: "No saved layers"; color: Theme.muted; font.pixelSize: 12 }
                    DeckButton { visible: mission.parkedCount > 0; text: "Show all · current spaces"; dot: Theme.caution; align: Text.AlignLeft; enabled: mission.ready; Layout.fillWidth: true; onClicked: mission.controller.call("layers.reveal") }
                    SectionHeader { title: "TMUX SESSIONS"; detail: String(mission.controller.state.sessions.length); Layout.fillWidth: true; Layout.topMargin: 12 }
                    Repeater {
                        model: mission.controller.state.sessions
                        ColumnLayout {
                            id: session
                            required property var modelData
                            Layout.fillWidth: true; spacing: 3
                            AppText { text: session.modelData.name; mono: true; font.pixelSize: Theme.base; color: Theme.text; Layout.fillWidth: true; elide: Text.ElideRight }
                            AppText { text: session.modelData.path || ""; mono: true; font.pixelSize: 10; color: Theme.muted; Layout.fillWidth: true; elide: Text.ElideMiddle }
                            AppText { text: session.modelData.windowCount + " windows · " + (session.modelData.panes || []).length + " panes"; mono: true; font.pixelSize: 10; color: Theme.dim }
                        }
                    }
                    AppText { visible: !mission.controller.state.sessions.length; text: "No tmux sessions running"; color: Theme.muted; font.pixelSize: 12 }
                    DeckButton { text: "New session"; align: Text.AlignLeft; enabled: mission.ready; Layout.fillWidth: true; onClicked: mission.controller.newSession() }
                    SectionHeader { title: "RECENT APP ACTIONS"; Layout.fillWidth: true; Layout.topMargin: 12 }
                    Repeater {
                        model: (mission.controller.activity || []).slice(0, 5)
                        RowLayout {
                            id: action
                            required property var modelData
                            readonly property bool preview: String(modelData.label).startsWith("Preview")
                            Layout.fillWidth: true; spacing: 8
                            AppText { text: action.modelData.time; mono: true; font.pixelSize: 10; color: Theme.dim; Layout.alignment: Qt.AlignTop; Layout.topMargin: 1 }
                            ColumnLayout {
                                Layout.fillWidth: true; spacing: 2
                                AppText { text: action.modelData.label; font.pixelSize: Theme.base; color: action.modelData.error ? Theme.red : action.preview ? Theme.caution : Theme.body; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                AppText { visible: action.modelData.detail !== ""; text: action.modelData.detail; font.pixelSize: 11; color: Theme.muted; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            }
                        }
                    }
                    AppText { visible: !(mission.controller.activity || []).length; text: "No app actions yet"; color: Theme.muted; font.pixelSize: 12 }
                    SectionHeader { title: "HOST HEALTH"; Layout.fillWidth: true; Layout.topMargin: 12 }
                    Repeater {
                        model: [{ label: "Window inventory", key: "windows.read" }, { label: "Window placement", key: "windows.place" }, { label: "Spaces", key: "spaces.read" }, { label: "tmux", key: "sessions.tmux" }]
                        RowLayout {
                            id: check
                            required property var modelData
                            readonly property var health: mission.controller.state.describe?.capabilityHealth?.[modelData.key]
                            Layout.fillWidth: true; spacing: 8
                            // Solid: ready. Caution ring: unavailable. Dim ring: not reported.
                            Rectangle { implicitWidth: 6; implicitHeight: 6; radius: 3; color: check.health?.available === true ? Theme.live : "transparent"; border.width: check.health?.available === true ? 0 : 1; border.color: check.health?.available === false ? Theme.caution : Theme.dim }
                            AppText { text: check.modelData.label; font.pixelSize: 12; color: Theme.body; Layout.fillWidth: true }
                            AppText { text: check.health?.available === true ? "READY" : check.health?.available === false ? "UNAVAILABLE" : "UNKNOWN"; mono: true; font.pixelSize: 10; font.letterSpacing: 0.8; color: check.health?.available === true ? Theme.muted : check.health?.available === false ? Theme.caution : Theme.dim }
                        }
                    }
                    DeckButton { text: "Open Operator Console"; quiet: true; align: Text.AlignLeft; keycap: "Ctrl 7"; Layout.fillWidth: true; Layout.topMargin: 4; onClicked: mission.controller.page = "Console" }
                    Item { implicitHeight: 4 }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 36; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 8
            KeyBar {
                Layout.fillWidth: true
                keys: [{ cap: "↑ ↓", label: "Select" }, { cap: "↵", label: "Focus" }, { cap: "Ctrl K", label: "Filter" }, { cap: "Esc", label: "All spaces" }]
            }
            DeckButton { visible: !mission.wide; text: "Layers"; quiet: true; implicitHeight: 24; onClicked: mission.controller.page = "Layers" }
            DeckButton {
                visible: !mission.wide && mission.parkedCount > 0; text: "Restore here"; quiet: true; dot: Theme.caution; implicitHeight: 24; enabled: mission.ready; onClicked: mission.controller.call("layers.reveal")
                ToolTip.visible: hovered; ToolTip.text: "Restore parked windows whose original spaces are currently active"
            }
        }
    }
}
