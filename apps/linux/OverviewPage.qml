pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "FlightDeckModel.mjs" as Deck

FocusScope {
    id: overview
    required property var controller
    property bool virtualView: false
    property int displayIndex: -1
    property int inspectedSpace: -1
    property bool previewPlacement: false
    property var placementPlan: null
    property string commandError: ""
    property string statusNote: ""
    property var targetAction: null
    readonly property var displays: controller.state.displays
    readonly property var display: displays.find(d => d.displayIndex === displayIndex) || displays.find(d => d.displayIndex === controller.state.frontWindow?.displayIndex) || displays[0] || null
    readonly property var spaces: Deck.spacesFor(display)
    readonly property int spaceId: inspectedSpace > 0 && spaces.some(s => s.id === inspectedSpace) ? inspectedSpace : display?.currentSpaceId || -1
    readonly property bool inspecting: display !== null && spaceId !== display.currentSpaceId
    readonly property bool commandMode: Deck.entryMode(controller.query) === "command"
    readonly property var windows: Deck.mapWindows(controller.state.windows, display, spaceId, commandMode ? "" : controller.query)
    readonly property var selected: windows.find(w => w.wid === controller.selectedWid) || null
    readonly property var layers: controller.state.layers || []
    readonly property var searchResults: commandMode || !controller.query.trim() ? [] : controller.state.windows.filter(w => Deck.matches(w, controller.query))
    readonly property int parkedCount: (controller.state.stage?.parked || []).length
    readonly property bool canFocus: controller.online && !controller.busy && controller.state.describe?.methods?.includes("windows.focus") === true
    readonly property bool canPlace: canFocus && controller.state.describe?.methods?.includes("windows.place") && controller.state.describe?.capabilityHealth?.["windows.place"]?.available !== false
    readonly property bool canSwitch: controller.online && !controller.busy && controller.state.describe?.methods?.includes("spaces.focus") === true
    readonly property var workspaceCanvas: map
    readonly property string selectedCommand: selected ? targetAction?.wid === selected.wid ? "lats window place " + selected.wid + " " + targetAction.placement + (targetAction.dryRun ? " --dry-run" : "") : "lats window focus " + selected.wid : spaceId > 0 ? "lats space " + spaceId : ""
    focus: true

    function focusMap() { map.forceActiveFocus() }
    function focusSearch() { virtualView = false; filter.forceActiveFocus(); filter.selectAll() }
    function reconcileSelection() {
        if (!selected) controller.selectedWid = (windows.find(w => w.isFocused) || windows[0])?.wid ?? -1
        if (placementPlan && placementPlan.target?.wid !== controller.selectedWid) placementPlan = null
    }
    function selectWindow(entry) {
        displayIndex = entry.displayIndex
        inspectedSpace = entry.spaceIds.find(id => id > 0) || -1
        controller.query = ""
        controller.selectedWid = entry.wid
        commandError = ""
        statusNote = ""
        targetAction = null
        overview.focusMap()
        Qt.callLater(() => map.fitSpace(overview.spaceId))
    }
    function inspectSpace(id) {
        inspectedSpace = id === display?.currentSpaceId ? -1 : id
        controller.query = ""
        placementPlan = null
        commandError = ""
        statusNote = ""
        overview.focusMap()
        Qt.callLater(() => map.fitSpace(id))
    }
    function selectCanvasWindow(id, wid) {
        inspectedSpace = id === display?.currentSpaceId ? -1 : id
        controller.selectedWid = wid
        commandError = ""; statusNote = ""; placementPlan = null
        overview.focusMap()
    }
    function selectCanvasSpace(id) {
        inspectedSpace = id === display?.currentSpaceId ? -1 : id
        controller.selectedWid = -1
        commandError = ""; statusNote = ""; placementPlan = null
        Qt.callLater(reconcileSelection)
        overview.focusMap()
    }
    function selectDirection(direction) {
        const next = Deck.nearbyWindow(windows, controller.selectedWid, direction)
        if (next !== null) controller.selectedWid = next
    }
    function focusTarget() {
        if (selected && canFocus) controller.call("windows.focus", { wid: selected.wid })
    }
    function placeTarget(position) {
        if (!selected || !canPlace) return
        placementPlan = null
        targetAction = { wid: selected.wid, placement: position, dryRun: previewPlacement }
        statusNote = ""
        controller.call("windows.place", { wid: selected.wid, placement: position, dryRun: previewPlacement })
    }
    function runEntry() {
        const action = Deck.parseEntry(controller.query, controller.state.windows, layers)
        commandError = ""
        statusNote = ""
        if (action.kind === "error") { commandError = action.message; return }
        if (action.kind === "page") { controller.query = ""; controller.page = action.page; return }
        if (action.kind === "search") {
            if (searchResults.length !== 1) { commandError = searchResults.length ? "Choose a result, then press Enter to focus it." : "No matching window."; return }
            const entry = searchResults[0]
            selectWindow(entry)
            if (canFocus) controller.call("windows.focus", { wid: entry.wid })
            return
        }
        if (!controller.online || controller.busy) return
        if (!controller.state.describe.methods.includes(action.method)) { commandError = "This host does not support that action yet."; return }
        if (action.params.wid) {
            const target = controller.state.windows.find(w => w.wid === action.params.wid)
            if (target) selectWindow(target)
            if (action.method === "windows.place") targetAction = { wid: action.params.wid, placement: action.params.placement, dryRun: action.params.dryRun }
        }
        controller.call(action.method, action.params)
        controller.query = ""
        overview.focusMap()
    }
    function handleResult(method, result) {
        if (method === "windows.place") {
            placementPlan = result?.status === "planned" && result.target?.wid === selected?.wid ? result : null
            if (result?.status === "planned") statusNote = "Placement preview only · no window moved."
        }
        if (method === "windows.resolve") statusNote = "Window " + (result?.window?.wid || "") + " resolved · no focus changed."
        if (method === "spaces.focus") {
            if (result?.status === "planned") statusNote = "Planned space switch: " + result.target + " · no space changed."
            else { displayIndex = Number.isInteger(result?.displayIndex) ? result.displayIndex : -1; inspectedSpace = -1 }
        }
    }
    onWindowsChanged: if (visible && controller.page === "Overview") Qt.callLater(reconcileSelection)
    onSelectedChanged: {
        if (placementPlan && placementPlan.target?.wid !== selected?.wid) placementPlan = null
        if (targetAction && targetAction.wid !== selected?.wid) targetAction = null
    }
    onSpaceIdChanged: placementPlan = null
    onDisplayChanged: placementPlan = null
    onVisibleChanged: if (visible) Qt.callLater(() => { overview.reconcileSelection(); overview.focusMap() })
    Component.onCompleted: if (visible && controller.page === "Overview") Qt.callLater(reconcileSelection)
    Connections {
        target: overview.controller
        function onActionFinished(method, result) { overview.handleResult(method, result) }
    }
    Keys.onPressed: event => {
        if (virtualView || filter.activeFocus || commandCopy.activeFocus) return
        if (event.key === Qt.Key_Plus && event.modifiers === Qt.ShiftModifier) { map.zoomBy(1.25); event.accepted = true; return }
        if (event.modifiers !== Qt.NoModifier) return
        const directions = { [Qt.Key_Left]: "left", [Qt.Key_Right]: "right", [Qt.Key_Up]: "up", [Qt.Key_Down]: "down" }
        if (directions[event.key]) { selectDirection(directions[event.key]); event.accepted = true }
        else if (event.key === Qt.Key_BracketLeft || event.key === Qt.Key_BracketRight) {
            const next = Deck.nextSpace(spaces, spaceId, event.key === Qt.Key_BracketLeft ? -1 : 1)
            if (next !== null) inspectSpace(next)
            event.accepted = true
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { focusTarget(); event.accepted = true }
        else if (event.key === Qt.Key_Escape) { controller.query = ""; commandError = ""; inspectedSpace = -1; placementPlan = null; map.fitSpace(display?.currentSpaceId); event.accepted = true }
        else if (event.key === Qt.Key_Space) { map.panHeld = true; event.accepted = true }
        else if (event.key === Qt.Key_0) { map.fitAll(); event.accepted = true }
        else if (event.key === Qt.Key_1) { map.fitSpace(spaceId); event.accepted = true }
        else if (event.key === Qt.Key_Minus) { map.zoomBy(0.8); event.accepted = true }
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) { map.zoomBy(1.25); event.accepted = true }
        else if (event.key === Qt.Key_Question) { controller.page = "Hints"; event.accepted = true }
    }
    Keys.onReleased: event => { if (event.key === Qt.Key_Space) { map.panHeld = false; event.accepted = true } }

    Rectangle { anchors.fill: parent; color: Theme.pageGround }
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 50; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 10
            InputField {
                id: filter; objectName: "deckSearch"
                visible: !overview.virtualView
                Layout.fillWidth: true; implicitHeight: 32; font.family: Theme.mono; font.pixelSize: 12
                prompt: overview.commandMode ? ">" : "/"; keycap: "Ctrl K"
                placeholderText: overview.width < 620 ? "Find a window · > space next" : "Find a window, or type > space next · > focus kitty · > hints"
                text: overview.controller.query
                Accessible.name: "Find a window or run a command"
                onTextEdited: { overview.controller.query = text; overview.commandError = "" }
                onAccepted: overview.runEntry()
                Keys.onEscapePressed: { overview.controller.query = ""; overview.commandError = ""; overview.focusMap() }
            }
            DeckLabel { visible: overview.virtualView; text: "VIRTUAL SPACE"; color: Theme.text }
            AppText { visible: overview.virtualView; text: "A separate headless desktop"; font.pixelSize: 11; color: Theme.muted; Layout.fillWidth: true; elide: Text.ElideRight }
            Row {
                spacing: -1
                DeckButton { text: "Desktop"; selected: !overview.virtualView; z: selected ? 1 : 0; onClicked: { overview.virtualView = false; overview.focusMap() } }
                DeckButton { text: "Virtual space"; selected: overview.virtualView; z: selected ? 1 : 0; onClicked: overview.virtualView = true }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        VirtualSpaceView { visible: overview.virtualView; controller: overview.controller; Layout.fillWidth: true; Layout.fillHeight: true }
        ColumnLayout {
            visible: !overview.virtualView
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
            RowLayout {
                visible: overview.commandError !== ""
                Layout.fillWidth: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; Layout.topMargin: 8; Layout.bottomMargin: 8; spacing: 8
                Tag { text: "NOT RUN"; tone: Theme.amber; Layout.alignment: Qt.AlignTop }
                AppText { text: overview.commandError; color: Theme.amber; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            }
            RowLayout {
                visible: overview.commandError === "" && (overview.statusNote !== "" || overview.commandMode)
                Layout.fillWidth: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; Layout.topMargin: 8; Layout.bottomMargin: 8; spacing: 8
                Tag { visible: overview.statusNote !== ""; text: "PREVIEW"; tone: Theme.amber; Layout.alignment: Qt.AlignTop }
                AppText {
                    text: overview.statusNote || "Enter runs a command. Relative space commands use the focused display."
                    color: overview.statusNote !== "" ? Theme.amber : Theme.muted; font.pixelSize: 12
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
            }
            ListView {
                visible: overview.searchResults.length > 0
                Layout.fillWidth: true; Layout.preferredHeight: Math.min(132, overview.searchResults.length * 36); Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; Layout.topMargin: 8; Layout.bottomMargin: 8
                clip: true; spacing: 2; model: overview.searchResults
                delegate: Button {
                    id: hit
                    required property var modelData
                    readonly property bool chosen: overview.controller.selectedWid === modelData.wid
                    width: ListView.view.width; height: 34; padding: 0
                    Accessible.name: overview.controller.appName(modelData.app) + ", " + modelData.title + ", space " + modelData.spaceIds.join(", ")
                    onClicked: overview.selectWindow(modelData)
                    background: Rectangle {
                        radius: 3; color: hit.chosen ? Theme.cyanSoft : hit.hovered ? Theme.hover : Theme.surface
                        border.color: hit.activeFocus ? Theme.cyan : hit.chosen ? Theme.cyanLine : Theme.border
                    }
                    contentItem: RowLayout {
                        spacing: 10
                        AppText { text: overview.controller.appName(hit.modelData.app); font.weight: Font.Medium; color: hit.chosen ? Theme.cyan : Theme.text; Layout.leftMargin: 10; Layout.preferredWidth: hit.width < 460 ? 84 : 132; elide: Text.ElideRight }
                        AppText { text: hit.modelData.title; color: Theme.body; Layout.fillWidth: true; elide: Text.ElideMiddle }
                        AppText { text: "SPACE " + hit.modelData.spaceIds.join(","); mono: true; font.pixelSize: 10; color: Theme.muted }
                        AppText { visible: hit.width >= 460; text: "ID " + hit.modelData.wid; mono: true; font.pixelSize: 10; color: Theme.dim; Layout.rightMargin: 10 }
                        Item { visible: hit.width < 460; implicitWidth: 1 }
                    }
                }
            }
            Rectangle { visible: overview.commandError !== "" || overview.statusNote !== "" || overview.commandMode || overview.searchResults.length > 0; Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
            RowLayout {
                Layout.fillWidth: true; Layout.preferredHeight: 48; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 6
                DeckButton {
                    text: "["; implicitWidth: 24; implicitHeight: 32; horizontalPadding: 0; enabled: overview.spaces.length > 1
                    Accessible.name: "Inspect previous space"
                    onClicked: overview.inspectSpace(Deck.nextSpace(overview.spaces, overview.spaceId, -1))
                    ToolTip.visible: hovered; ToolTip.text: "Inspect previous space"
                }
                Flickable {
                    Layout.preferredWidth: horizon.width; Layout.minimumWidth: 56; Layout.preferredHeight: 32
                    contentWidth: horizon.width; contentHeight: height; clip: true
                    Row {
                        id: horizon; spacing: 4
                        Repeater {
                            model: overview.spaces
                            SpaceCell {
                                required property var modelData
                                spaceId: modelData.id; count: modelData.windowCount
                                current: modelData.id === overview.display?.currentSpaceId
                                selected: overview.spaceId === modelData.id; caution: selected && !current
                                onClicked: overview.inspectSpace(modelData.id)
                                ToolTip.visible: hovered; ToolTip.text: "Inspect space " + modelData.id + " · " + modelData.windowCount + " windows" + (current ? " · current" : "")
                            }
                        }
                    }
                }
                DeckButton {
                    text: "]"; implicitWidth: 24; implicitHeight: 32; horizontalPadding: 0; enabled: overview.spaces.length > 1
                    Accessible.name: "Inspect next space"
                    onClicked: overview.inspectSpace(Deck.nextSpace(overview.spaces, overview.spaceId, 1))
                    ToolTip.visible: hovered; ToolTip.text: "Inspect next space"
                }
                AppText {
                    visible: overview.width >= 620
                    text: "SPACE " + (overview.spaceId > 0 ? String(overview.spaceId).padStart(2, "0") : "—")
                    mono: true; font.pixelSize: 13; font.weight: Font.DemiBold; font.letterSpacing: 1; color: Theme.text
                    Layout.leftMargin: 10; Layout.minimumWidth: implicitWidth
                }
                Tag {
                    text: overview.inspecting ? "INSPECTING" : "CURRENT"; tone: overview.inspecting ? Theme.amber : Theme.green; dot: !overview.inspecting
                    Layout.leftMargin: overview.width >= 620 ? 2 : 6; Layout.minimumWidth: implicitWidth
                }
                AppText {
                    visible: overview.inspecting && overview.width >= 900
                    text: "The desktop stays on space " + String(overview.display?.currentSpaceId || 0).padStart(2, "0")
                    font.pixelSize: 11; color: Theme.muted; Layout.leftMargin: 4
                }
                Item { Layout.fillWidth: true }
                DeckButton {
                    visible: overview.displays.length > 1; text: overview.display?.displayId || "Display"; quiet: true
                    Accessible.name: "Choose display, " + text
                    onClicked: displayMenu.open()
                    Menu {
                        id: displayMenu
                        Repeater {
                            model: overview.displays
                            MenuItem {
                                required property var modelData
                                text: modelData.displayId
                                onTriggered: { overview.displayIndex = modelData.displayIndex; overview.inspectedSpace = -1; overview.focusMap() }
                            }
                        }
                    }
                }
                DeckButton { visible: overview.inspecting; text: "Go to space"; selected: true; enabled: overview.canSwitch; Layout.minimumWidth: implicitWidth; onClicked: overview.controller.call("spaces.focus", { workspace: overview.spaceId }) }
                DeckButton { visible: overview.inspecting; text: overview.width < 620 ? "Back" : "Back to current"; quiet: true; keycap: overview.width < 620 ? "" : "Esc"; Layout.minimumWidth: implicitWidth; Accessible.name: "Back to current space"; onClicked: overview.inspectSpace(overview.display.currentSpaceId) }
            }
            RowLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 16
                ColumnLayout {
                    Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
                    RowLayout {
                        Layout.fillWidth: true; Layout.preferredHeight: 30; spacing: 8
                        DeckLabel { visible: overview.layers.length > 0; text: "LAYER" }
                        Flickable {
                            Layout.fillWidth: true; Layout.preferredHeight: 24; contentWidth: layerChoices.width; contentHeight: height; clip: true
                            Row {
                                id: layerChoices; spacing: 4
                                Repeater {
                                    model: overview.layers
                                    DeckButton {
                                        required property var modelData
                                        readonly property bool raised: modelData.active && !overview.inspecting
                                        text: modelData.label; implicitHeight: 24; hollowDot: true; dot: raised ? Theme.green : "transparent"
                                        enabled: !overview.inspecting && !overview.controller.busy && !overview.controller.state.layersError
                                        Accessible.name: modelData.label + (raised ? ", active layer" : ", layer")
                                        onClicked: overview.controller.call("layers.activate", { layer: modelData.id, mode: "tile" })
                                        ToolTip.visible: hovered; ToolTip.text: overview.inspecting ? "Go to this space before switching layers" : "Raise and arrange this layer on the current space"
                                    }
                                }
                                DeckButton {
                                    visible: overview.layers.length > 0 || overview.parkedCount > 0
                                    text: "Show all"; implicitHeight: 24; quiet: true
                                    enabled: !overview.inspecting && !overview.controller.busy && overview.parkedCount > 0
                                    onClicked: overview.controller.call("layers.reveal")
                                    ToolTip.visible: hovered; ToolTip.text: "Restore parked windows whose original spaces are currently active"
                                }
                            }
                        }
                        AppText { visible: overview.parkedCount > 0; text: overview.parkedCount + " PARKED"; mono: true; font.pixelSize: 10; font.letterSpacing: 0.8; color: Theme.amber }
                        AppText { visible: overview.width >= 680 || overview.parkedCount === 0; text: overview.windows.length + (overview.windows.length === 1 ? " WINDOW" : " WINDOWS"); mono: true; font.pixelSize: 10; font.letterSpacing: 0.8; color: Theme.muted }
                        AppText { visible: overview.width > 690; text: (overview.display?.displayId || "Display") + " · " + (overview.display?.frame.w || 0) + " × " + (overview.display?.frame.h || 0); mono: true; font.pixelSize: 10; color: Theme.dim }
                    }
                    WorkspaceCanvas {
                        id: map; objectName: "deckMap"
                        Layout.fillWidth: true; Layout.fillHeight: true; Layout.minimumWidth: 190; Layout.minimumHeight: 120
                        controller: overview.controller; display: overview.display; windows: overview.controller.state.windows
                        spaceId: overview.spaceId; query: overview.commandMode ? "" : overview.controller.query; placementPlan: overview.placementPlan
                        onSpaceSelected: id => overview.selectCanvasSpace(id)
                        onWindowSelected: (id, wid) => overview.selectCanvasWindow(id, wid)
                        onWindowActivated: (id, wid) => { overview.selectCanvasWindow(id, wid); overview.focusTarget() }
                    }
                }
                ScrollView {
                    id: target
                    Layout.preferredWidth: overview.width < 680 ? 174 : 248; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
                    ColumnLayout {
                        width: target.availableWidth; spacing: 10
                        SectionHeader { title: "TARGET"; Layout.fillWidth: true; Layout.preferredHeight: 30 }
                        AppText { text: overview.selected ? overview.controller.appName(overview.selected.app) : "No window selected"; font.pixelSize: 19; font.weight: Font.Medium; color: Theme.text; Layout.fillWidth: true; elide: Text.ElideRight; Layout.topMargin: -2 }
                        AppText { visible: overview.selected !== null; text: overview.selected?.title || ""; color: Theme.body; font.pixelSize: 12; wrapMode: Text.WordWrap; maximumLineCount: 4; elide: Text.ElideRight; lineHeight: 1.2; Layout.fillWidth: true }
                        AppText { visible: overview.selected === null; text: "Choose a window on the map to see its controls."; color: Theme.muted; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                        Flow {
                            visible: overview.selected !== null
                            Layout.fillWidth: true; spacing: 6
                            Tag { visible: overview.selected?.isFocused === true; text: "FOCUSED"; tone: Theme.green; dot: true }
                            Tag { text: overview.selected?.isFullscreen ? "FULLSCREEN" : overview.selected?.isFloating ? "FLOATING" : "TILED" }
                            Tag { visible: overview.inspecting; text: "NOT ON SCREEN"; tone: Theme.amber }
                        }
                        ColumnLayout {
                            visible: overview.selected !== null
                            Layout.fillWidth: true; Layout.topMargin: 2; spacing: 0
                            Repeater {
                                model: overview.selected ? [
                                    { label: "WINDOW", value: String(overview.selected.wid) },
                                    { label: "SPACE", value: overview.selected.spaceIds.join(", ") },
                                    { label: "SIZE", value: overview.selected.frame.w + " × " + overview.selected.frame.h },
                                    { label: "ORIGIN", value: overview.selected.frame.x + ", " + overview.selected.frame.y },
                                    { label: "TMUX", value: overview.selected.latticesSession || "—" }
                                ] : []
                                ColumnLayout {
                                    id: reading
                                    required property var modelData
                                    Layout.fillWidth: true; spacing: 0
                                    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                                    RowLayout {
                                        Layout.fillWidth: true; Layout.preferredHeight: 25; spacing: 8
                                        DeckLabel { text: reading.modelData.label; color: Theme.dim }
                                        AppText { text: reading.modelData.value; mono: true; font.pixelSize: 11; color: Theme.text; Layout.fillWidth: true; horizontalAlignment: Text.AlignRight; elide: Text.ElideMiddle }
                                    }
                                }
                            }
                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
                        }
                        DeckButton { text: "Focus window"; keycap: "↵"; primary: true; align: Text.AlignLeft; implicitHeight: 32; Layout.fillWidth: true; Layout.topMargin: 2; enabled: overview.selected !== null && overview.canFocus; onClicked: overview.focusTarget() }
                        RowLayout {
                            visible: overview.selected !== null
                            Layout.fillWidth: true; Layout.topMargin: 6; spacing: 8
                            DeckLabel { text: "PLACE WINDOW"; Layout.fillWidth: true }
                            Tag { visible: overview.previewPlacement; text: "PREVIEW"; tone: Theme.amber }
                        }
                        GridLayout {
                            visible: overview.selected !== null; columns: 2; columnSpacing: 6; rowSpacing: 6; Layout.fillWidth: true
                            Repeater {
                                model: ["left", "right", "center", "maximize"]
                                DeckButton {
                                    required property string modelData
                                    text: modelData === "maximize" ? "Fill" : modelData.charAt(0).toUpperCase() + modelData.slice(1)
                                    placement: modelData; align: Text.AlignLeft; caution: overview.previewPlacement
                                    Layout.fillWidth: true; Layout.preferredWidth: 80; enabled: overview.canPlace
                                    Accessible.name: (overview.previewPlacement ? "Preview " : "Place ") + modelData
                                    onClicked: overview.placeTarget(modelData)
                                    ToolTip.visible: hovered; ToolTip.text: (overview.previewPlacement ? "Preview " : "Place ") + modelData
                                }
                            }
                        }
                        DeckButton {
                            visible: overview.selected !== null
                            text: overview.previewPlacement ? "Preview on · no move" : "Preview placement"
                            selected: overview.previewPlacement; caution: overview.previewPlacement
                            hollowDot: true; dot: overview.previewPlacement ? Theme.amber : "transparent"; align: Text.AlignLeft
                            Layout.fillWidth: true
                            onClicked: { overview.previewPlacement = !overview.previewPlacement; overview.placementPlan = null; overview.focusMap() }
                        }
                        AppText { visible: overview.placementPlan !== null; text: "Preview only. Turn preview off and choose a placement to move this window."; color: Theme.amber; font.pixelSize: 11; wrapMode: Text.WordWrap; lineHeight: 1.2; Layout.fillWidth: true }
                        SectionHeader { title: "SAME MOVE FROM A SHELL"; Layout.fillWidth: true; Layout.topMargin: 8 }
                        TextArea {
                            id: commandCopy; objectName: "deckCommand"
                            text: overview.selectedCommand; readOnly: true; selectByMouse: true; wrapMode: TextEdit.Wrap; textFormat: TextEdit.PlainText
                            font.family: Theme.mono; font.pixelSize: 12; color: Theme.text; selectionColor: Theme.cyanSoft; selectedTextColor: Theme.text
                            padding: 9; implicitHeight: Math.max(32, contentHeight + 18); Layout.fillWidth: true
                            Accessible.name: "CLI command for selected target"
                            background: Rectangle { radius: 3; color: Theme.ink; border.color: commandCopy.activeFocus ? Theme.cyan : Theme.borderLit }
                            onActiveFocusChanged: if (activeFocus) selectAll()
                        }
                        AppText { text: "Select text to copy."; color: Theme.dim; font.pixelSize: 11 }
                        Item { implicitHeight: 4 }
                    }
                }
            }
            KeyBar {
                Layout.fillWidth: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; Layout.topMargin: 10; Layout.bottomMargin: 10
                keys: [{ cap: "Scroll", label: "Zoom" }, { cap: "Drag", label: "Pan" }, { cap: "0 / 1", label: "All / space" }, { cap: "[ ]", label: "Inspect" }, { cap: "↵", label: "Focus" }, { cap: "Esc", label: "Current" }]
            }
        }
    }
}
