pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "DesktopViews.mjs" as Views

FocusScope {
    id: operator
    required property var controller
    property var entries: []
    property var history: []
    property int serial: 0
    property int historyIndex: -1
    property string draft: ""
    property string completionPrefix: ""
    property string lastCompletion: ""
    property int completionIndex: 0
    readonly property var activeLayer: (controller.state.layers || []).find(layer => layer.active)
    focus: true
    function focusInput() { input.forceActiveFocus() }
    function prepare(command) { input.text = command; input.cursorPosition = command.length; historyIndex = -1; lastCompletion = ""; focusInput() }
    function append(command, output, status, id, json) {
        entries = entries.concat([{ id: id || "", command, output, status, json: !!json, time: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) }]).slice(-100)
        Qt.callLater(() => transcript.positionViewAtEnd())
    }
    function clearTranscript() { entries = entries.filter(entry => entry.status === "running"); focusInput() }
    function historyStep(delta) {
        if (!history.length) return
        if (historyIndex < 0) { draft = input.text; historyIndex = history.length }
        historyIndex = Math.max(0, Math.min(history.length, historyIndex + delta))
        input.text = historyIndex === history.length ? draft : history[historyIndex]
        input.cursorPosition = input.text.length
        lastCompletion = ""
    }
    function completeInput() {
        if (input.text !== lastCompletion) { completionPrefix = input.text; completionIndex = 0 }
        else completionIndex++
        const choices = Views.completions(completionPrefix, controller.state.windows, controller.state.layers || [])
        if (!choices.length) return
        lastCompletion = choices[completionIndex % choices.length]
        input.text = lastCompletion
        input.select(completionPrefix.length, lastCompletion.length)
    }
    function complete(id, method, result, failed, message) {
        const index = entries.findIndex(entry => entry.id === id && entry.status === "running")
        if (index < 0) return
        let output
        try { output = failed ? message : Views.formatResult(method, result, entries[index].json) }
        catch (error) { output = JSON.stringify(result ?? null, null, 2); if (!output) output = error.message }
        const next = entries.slice()
        next[index] = Object.assign({}, next[index], { output, status: failed || (method === "app.doctor" && result?.report?.ok === false) ? "error" : result?.status === "planned" || method === "windows.resolve" ? "preview" : "ok" })
        entries = next
        Qt.callLater(() => transcript.positionViewAtEnd())
    }
    function submit() {
        const command = input.text.trim()
        if (!command || controller.busy) return
        if (history[history.length - 1] !== command) history = history.concat([command]).slice(-50)
        historyIndex = -1; lastCompletion = ""; input.text = ""
        const action = Views.consoleCommand(command, controller.state.windows, controller.state.layers || [])
        if (action.kind === "error") { append(command, action.message, "error"); return }
        if (action.kind === "page") { append(command, "Opened " + ({ Mission: "Mission Control", Overview: "Flight Deck", Console: "Operator Console", Hints: "Hints" })[action.page] + ".", "ok"); controller.page = action.page; return }
        if (action.kind === "local") {
            if (action.action === "clear") { clearTranscript(); return }
            if (action.action === "help") append(command, Views.consoleHelp, "ok")
            else if (action.action === "status") append(command, action.json ? JSON.stringify({ running: true, page: controller.page, online: controller.online }, null, 2) : "Lattices running · " + controller.page + "\nHost " + (controller.online ? "connected" : "offline"), "ok")
            else append(command, action.json ? JSON.stringify(controller.hints, null, 2) : controller.hints.groups.map(group => group.title + "\n" + group.hints.map(hint => "  " + (hint.shortcut || hint.command) + "\n    " + hint.title + " · " + hint.detail).join("\n")).join("\n\n"), "ok")
            return
        }
        if (action.kind !== "rpc") { append(command, "Use a supported Lattices command. Type help for the list.", "error"); return }
        if (action.method !== "app.doctor" && !controller.online) { append(command, "The local host is offline. Run lats doctor to inspect the connection.", "error"); return }
        if (action.method !== "app.doctor" && !controller.state.describe?.methods?.includes(action.method)) { append(command, "This host does not support " + action.method + ".", "error"); return }
        const id = "console-" + Date.now() + "-" + (++serial)
        append(command, "Waiting for the local host…", "running", id, action.json)
        if (controller.call(action.method, action.params, id) === false) complete(id, action.method, null, true, "The app could not submit this request. Try again after reconnecting.")
    }
    onVisibleChanged: if (visible) Qt.callLater(focusInput)
    Connections {
        target: operator.controller
        function onCommandFinished(id, method, result, failed, message) { operator.complete(id, method, result, failed, message) }
    }
    Shortcut { sequence: "Ctrl+L"; enabled: operator.visible; onActivated: operator.clearTranscript() }
    readonly property bool wide: width > 850
    Rectangle { anchors.fill: parent; color: Theme.pageGround }
    ColumnLayout {
        anchors.fill: parent; spacing: 0
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 40; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 14
            DeckLabel { visible: operator.width >= 620; text: "ACTS ON" }
            AppText { text: operator.controller.state.windows.length + (operator.controller.state.windows.length === 1 ? " window" : " windows"); mono: true; font.pixelSize: 11; color: Theme.body }
            AppText { text: operator.controller.state.sessions.length + (operator.controller.state.sessions.length === 1 ? " session" : " sessions"); mono: true; font.pixelSize: 11; color: Theme.body }
            AppText { text: "Layer " + (operator.activeLayer?.label || "all windows"); mono: true; font.pixelSize: 11; color: Theme.body; Layout.fillWidth: true; elide: Text.ElideRight }
            DeckButton { text: "Clear"; quiet: true; implicitHeight: 24; keycap: "Ctrl L"; enabled: operator.entries.some(entry => entry.status !== "running"); Accessible.name: "Clear completed entries"; onClicked: operator.clearTranscript() }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 16
            ListView {
                id: transcript; objectName: "consoleTranscript"
                Layout.fillWidth: true; Layout.fillHeight: true; clip: true; spacing: 0
                topMargin: 6; bottomMargin: 6
                model: operator.entries
                Accessible.name: "Command transcript"
                ScrollBar.vertical: ScrollBar {}
                delegate: Item {
                    id: entry
                    required property var modelData
                    readonly property string status: modelData.status
                    readonly property color tone: status === "error" ? Theme.red : status === "preview" ? Theme.caution : status === "running" ? Theme.accent : Theme.live
                    width: ListView.view.width; implicitHeight: block.implicitHeight + 25
                    // The gutter rule carries the outcome down the whole result:
                    // quiet when it ran, red when it failed, accent while it runs,
                    // and broken for a preview, which changed nothing.
                    Rectangle { visible: entry.status !== "preview"; x: 0; y: 12; width: 2; height: block.height; color: entry.status === "ok" ? Theme.liveLine : entry.tone }
                    Column {
                        visible: entry.status === "preview"
                        x: 0; y: 12; width: 2; height: block.height; spacing: 3; clip: true
                        Repeater { model: entry.status === "preview" ? Math.ceil(block.height / 7) : 0; Rectangle { width: 2; height: 4; color: entry.tone } }
                    }
                    ColumnLayout {
                        id: block
                        x: 14; y: 12; width: parent.width - 28; spacing: 7
                        RowLayout {
                            Layout.fillWidth: true; spacing: 8
                            AppText { text: ">"; mono: true; font.pixelSize: Theme.base; color: Theme.dim; Layout.alignment: Qt.AlignTop }
                            AppText { text: entry.modelData.command; mono: true; font.pixelSize: Theme.base; font.weight: Font.Medium; color: Theme.text; Layout.fillWidth: true; wrapMode: Text.WrapAnywhere }
                            AppText { text: entry.modelData.time; mono: true; font.pixelSize: 10; color: Theme.dim; Layout.alignment: Qt.AlignTop; Layout.topMargin: 2 }
                            Tag { text: entry.status === "running" ? "RUNNING" : entry.status === "error" ? "ERROR" : entry.status === "preview" ? "PREVIEW" : "OK"; tone: entry.tone; dot: entry.status === "ok"; Layout.alignment: Qt.AlignTop }
                        }
                        TextEdit {
                            Layout.fillWidth: true; Layout.leftMargin: 16
                            text: entry.modelData.output; readOnly: true; selectByMouse: true; textFormat: TextEdit.PlainText; wrapMode: TextEdit.WrapAnywhere
                            font.family: Theme.mono; font.pixelSize: Theme.base; color: entry.status === "error" ? Theme.redText : entry.status === "running" ? Theme.muted : Theme.body
                            selectionColor: Theme.selection; selectedTextColor: Theme.text
                            Accessible.name: "Command output"
                        }
                    }
                    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.border }
                }
                ColumnLayout {
                    visible: !operator.entries.length
                    width: Math.min(parent.width, 620); y: 22; spacing: 12
                    AppText { text: "Lattices commands, on your desktop."; font.pixelSize: 21; font.weight: Font.Normal; font.letterSpacing: -0.2; color: Theme.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    AppText { text: "Inspect the host, find windows, preview a move, or switch a layer. Each command keeps its result here for this app session."; font.pixelSize: Theme.lead; color: Theme.muted; lineHeight: 1.35; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    Flow {
                        Layout.fillWidth: true; Layout.topMargin: 6; spacing: 6
                        Repeater {
                            model: ["lats doctor", "lats windows", "lats spaces", "help"]
                            DeckButton { required property string modelData; text: modelData; Accessible.name: "Insert " + modelData; onClicked: operator.prepare(modelData) }
                        }
                    }
                    AppText { text: "A suggestion fills the command line; Enter runs it. Add --dry-run to preview focus, placement or space changes."; font.pixelSize: 12; color: Theme.dim; lineHeight: 1.3; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                }
            }
            Rectangle { visible: operator.wide; implicitWidth: 1; Layout.fillHeight: true; color: Theme.border }
            ScrollView {
                id: rail
                visible: operator.wide; Layout.preferredWidth: 240; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
                ColumnLayout {
                    width: rail.availableWidth; spacing: 4
                    SectionHeader { title: "QUICK COMMANDS"; Layout.fillWidth: true; Layout.preferredHeight: 34 }
                    Rectangle {
                        Layout.fillWidth: true; implicitHeight: quick.implicitHeight + 2; radius: 3; color: Theme.surface; border.color: Theme.border
                        ColumnLayout {
                            id: quick
                            x: 1; y: 1; width: parent.width - 2; spacing: 0
                            Repeater {
                                model: ["lats doctor", "lats windows", "lats spaces", "lats sessions", "lats layer", "lats hints"]
                                DeckButton { required property string modelData; text: modelData; align: Text.AlignLeft; quiet: true; note: hovered || activeFocus ? "INSERT" : ""; Layout.fillWidth: true; Accessible.name: "Insert " + modelData; onClicked: operator.prepare(modelData) }
                            }
                        }
                    }
                    DeckButton { text: "New session"; align: Text.AlignLeft; enabled: operator.controller.online && !operator.controller.busy; Layout.fillWidth: true; Layout.topMargin: 6; onClicked: operator.controller.newSession() }
                    SectionHeader { title: "KEYBOARD HINTS"; Layout.fillWidth: true; Layout.topMargin: 16; Layout.bottomMargin: 4 }
                    Repeater {
                        model: operator.controller.hints.groups.find(group => group.id === "operator-console")?.hints || []
                        ColumnLayout {
                            id: hint
                            required property var modelData
                            readonly property bool key: !!modelData.shortcut && modelData.shortcut.length <= 12
                            Layout.fillWidth: true; Layout.bottomMargin: 6; spacing: 4
                            RowLayout {
                                Layout.fillWidth: true; spacing: 8
                                KeyCap { visible: hint.key; text: hint.modelData.shortcut || "" }
                                AppText { visible: !hint.key; text: hint.modelData.shortcut || hint.modelData.command || ""; mono: true; font.pixelSize: Theme.small; color: Theme.text; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                                AppText { visible: hint.key; text: hint.modelData.title; font.pixelSize: 12; color: Theme.body; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            }
                            AppText { visible: !hint.key; text: hint.modelData.title; font.pixelSize: Theme.base; color: Theme.muted; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                    }
                    DeckButton { text: "All hints"; keycap: "F1"; quiet: true; align: Text.AlignLeft; Layout.fillWidth: true; onClicked: operator.controller.page = "Hints" }
                    Item { implicitHeight: 4 }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.borderLit }
        Rectangle {
            Layout.fillWidth: true; implicitHeight: 60; color: Theme.film
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: Theme.gutter; anchors.rightMargin: Theme.gutter; spacing: 8
                InputField {
                    id: input; objectName: "consoleInput"
                    Layout.fillWidth: true; implicitHeight: 36; font.family: Theme.mono; font.pixelSize: Theme.lead; prompt: ">"
                    placeholderText: operator.controller.online ? "lats doctor · type help for commands" : "Host offline · lats doctor still runs"
                    Accessible.name: "Lattices command"
                    onAccepted: operator.submit()
                    onTextEdited: { operator.historyIndex = -1; operator.lastCompletion = "" }
                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Up) { operator.historyStep(-1); event.accepted = true }
                        else if (event.key === Qt.Key_Down) { operator.historyStep(1); event.accepted = true }
                        else if (event.key === Qt.Key_Tab) { operator.completeInput(); event.accepted = true }
                        else if (event.key === Qt.Key_Escape) { text = ""; operator.historyIndex = -1; event.accepted = true }
                    }
                }
                DeckButton { text: operator.controller.busy ? "Working…" : "Run"; keycap: operator.controller.busy ? "" : "↵"; primary: true; implicitHeight: 36; enabled: !operator.controller.busy && input.text.trim() !== ""; Accessible.name: "Run command"; onClicked: { operator.submit(); operator.focusInput() } }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 36; Layout.leftMargin: Theme.gutter; Layout.rightMargin: Theme.gutter; spacing: 12
            KeyBar {
                Layout.fillWidth: true
                keys: [{ cap: "Tab", label: "Complete" }, { cap: "↑ ↓", label: "History" }, { cap: "Ctrl L", label: "Clear" }, { cap: "Esc", label: "Empty the line" }]
            }
            AppText { visible: operator.wide; text: "Typed Lattices actions only · no shell"; mono: true; font.pixelSize: 10; color: Theme.dim }
        }
    }
}
