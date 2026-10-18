pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: layers
    required property var controller
    property string selectedId: ""
    readonly property var configured: controller.state.layers || []
    readonly property var selected: configured.find(l => l.id === selectedId) || configured[0] || null
    readonly property var members: selected ? selected.entries.reduce((all, e) => all.concat(e.windows), []) : []
    readonly property var availableWindows: configured.reduce((all, l) => all.concat(l.entries.reduce((held, e) => held.concat(e.windows), [])), controller.state.windows).filter((w, i, all) => all.findIndex(other => other.wid === w.wid) === i)
    property var picked: []
    spacing: 0
    function create() { layerName.text = ""; includeVisible.checked = true; createDialog.open() }
    function layoutTitle(kind) { return ({ auto: "Auto", columns: "Columns", "master-stack": "Master stack" })[kind] || "In place" }
    function toggle(id, checked) { picked = checked ? picked.concat([id]) : picked.filter(wid => wid !== id) }

    RowLayout {
        Layout.fillWidth: true; Layout.preferredHeight: 44; Layout.leftMargin: 16; Layout.rightMargin: 16; spacing: 8
        AppText { text: layers.configured.length + (layers.configured.length === 1 ? " layer" : " layers"); color: Theme.muted; Layout.fillWidth: true }
        ActionButton { text: "Show all"; enabled: !layers.controller.busy && (layers.controller.state.stage?.parked || []).length > 0; onClicked: layers.controller.call("layers.reveal") }
        ActionButton { text: "New layer"; glyph: "plus"; accent: true; enabled: !layers.controller.busy && layers.controller.state.layersSupported; onClicked: layers.create() }
    }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
    AppText { visible: !layers.controller.state.layersSupported; text: "Update the local host to use layers."; color: Theme.muted; Layout.margins: 16 }
    AppText { visible: !!layers.controller.state.layersError; text: layers.controller.state.layersError || ""; color: Theme.red; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.margins: 16 }
    RowLayout {
        visible: layers.controller.state.layersSupported
        Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0
        ScrollView {
            id: index
            Layout.preferredWidth: layers.width < 700 ? 160 : 200; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ColumnLayout {
                width: index.availableWidth; spacing: 4
                Repeater {
                    model: layers.configured
                    Button {
                        id: layerRow
                        required property var modelData
                        Layout.fillWidth: true; Layout.margins: 8; Layout.topMargin: 4; Layout.bottomMargin: 0
                        implicitHeight: 62; padding: 10
                        onClicked: layers.selectedId = modelData.id
                        background: Rectangle { radius: 6; color: layers.selected?.id === layerRow.modelData.id ? Theme.greenSoft : layerRow.hovered ? Theme.hover : "transparent" }
                        contentItem: ColumnLayout {
                            spacing: 5
                            RowLayout {
                                AppText { text: layerRow.modelData.label; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                                Rectangle { visible: layerRow.modelData.active; implicitWidth: 5; implicitHeight: 5; radius: 3; color: Theme.green }
                            }
                            AppText { text: layerRow.modelData.entries.reduce((n, e) => n + e.windows.length, 0) + " windows · " + layers.layoutTitle(layerRow.modelData.layout); font.pixelSize: 10; color: Theme.muted; Layout.fillWidth: true; elide: Text.ElideRight }
                        }
                    }
                }
                AppText { visible: !layers.configured.length; text: "Your layers appear here"; color: Theme.dim; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.margins: 16 }
            }
        }
        Rectangle { Layout.fillHeight: true; implicitWidth: 1; color: Theme.border }
        ScrollView {
            id: detail
            Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
            ColumnLayout {
                width: detail.availableWidth; spacing: 16
                ColumnLayout {
                    visible: layers.selected !== null
                    Layout.fillWidth: true; Layout.margins: 16; spacing: 14
                    RowLayout {
                        AppText { text: layers.selected?.label || ""; font.pixelSize: 18; font.weight: Font.DemiBold; Layout.fillWidth: true; elide: Text.ElideRight }
                        ActionButton { text: layers.selected?.active ? "Gather" : "Switch"; accent: true; enabled: !layers.controller.busy && layers.members.length > 0; onClicked: layers.controller.call("layers.activate", { layer: layers.selected.id, mode: "tile" }) }
                    }
                    AppText { text: "Switch on this display and desktop. Other windows are put away until you switch layers or show all."; color: Theme.muted; wrapMode: Text.WordWrap; Layout.fillWidth: true; font.pixelSize: 11 }
                    AppText { text: "Layout"; font.weight: Font.DemiBold; Layout.topMargin: 4 }
                    GridLayout {
                        columns: 2; uniformCellWidths: true; columnSpacing: 8; rowSpacing: 8; Layout.fillWidth: true
                        Repeater {
                            model: ["none", "auto", "columns", "master-stack"]
                            Button {
                                id: choice
                                required property string modelData
                                readonly property bool chosen: (layers.selected?.layout || "none") === modelData
                                Layout.fillWidth: true; implicitHeight: 76; padding: 10
                                enabled: !layers.controller.busy
                                onClicked: layers.controller.call("layers.layout", { layer: layers.selected.id, layout: modelData })
                                background: Rectangle { color: choice.chosen ? Theme.greenSoft : choice.hovered ? Theme.hover : Theme.surface; radius: 7; border.color: choice.chosen ? Theme.green : Theme.border }
                                contentItem: ColumnLayout {
                                    spacing: 8
                                    Item {
                                        Layout.fillWidth: true; Layout.preferredHeight: 22
                                        readonly property var boxes: choice.modelData === "none" ? [[.08,.05,.5,.75],[.45,.3,.5,.7]] : choice.modelData === "columns" ? [[0,0,.3,1],[.35,0,.3,1],[.7,0,.3,1]] : choice.modelData === "master-stack" ? [[0,0,.6,1],[.65,0,.35,.45],[.65,.55,.35,.45]] : [[0,0,.28,1],[.33,0,.34,1],[.72,0,.28,.45],[.72,.55,.28,.45]]
                                        Repeater {
                                            model: parent.boxes
                                            Rectangle { required property var modelData; x: modelData[0] * parent.width; y: modelData[1] * parent.height; width: modelData[2] * parent.width; height: modelData[3] * parent.height; radius: 2; color: choice.chosen ? Theme.liveLine : Theme.hover; border.color: choice.chosen ? Theme.live : Theme.borderHot }
                                        }
                                    }
                                    AppText { text: layers.layoutTitle(choice.modelData); color: choice.chosen ? Theme.green : Theme.text; font.pixelSize: 11 }
                                }
                            }
                        }
                    }
                    AppText { text: "Applies when you switch or gather this layer."; color: Theme.dim; font.pixelSize: 10 }
                    RowLayout {
                        AppText { text: "Windows"; font.weight: Font.DemiBold; Layout.fillWidth: true }
                        ActionButton { text: "Add windows"; glyph: "plus"; enabled: !layers.controller.busy; onClicked: { layers.picked = []; addDialog.open() } }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true; spacing: 4
                        Repeater {
                            model: layers.selected?.entries || []
                            ColumnLayout {
                                id: entry
                                required property var modelData
                                Layout.fillWidth: true; spacing: 4
                                AppText { visible: entry.modelData.windows.length === 0; text: entry.modelData.name + " · " + entry.modelData.missing; color: Theme.dim; Layout.fillWidth: true; elide: Text.ElideRight }
                                Repeater {
                                    model: entry.modelData.windows
                                    ColumnLayout {
                                        id: held
                                        required property var modelData
                                        Layout.fillWidth: true; spacing: 2
                                        RowLayout {
                                            Layout.fillWidth: true
                                            AppText { text: layers.controller.appName(held.modelData.app); font.weight: Font.Medium; Layout.fillWidth: true; elide: Text.ElideRight }
                                            AppText { text: held.modelData.presence === "showing" ? "On screen" : held.modelData.presence === "parked" ? "Put away" : "Elsewhere"; color: Theme.dim; font.pixelSize: 10 }
                                            ActionButton { text: "Remove"; quiet: true; enabled: !layers.controller.busy; onClicked: layers.controller.call("layers.unassign", { layer: layers.selected.id, wid: held.modelData.wid }) }
                                        }
                                        AppText { text: held.modelData.title; font.pixelSize: 11; color: Theme.muted; Layout.fillWidth: true; elide: Text.ElideMiddle }
                                        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border; Layout.topMargin: 6; Layout.bottomMargin: 6 }
                                    }
                                }
                            }
                        }
                    }
                    AppText { visible: layers.members.length === 0; text: "Add windows to build this layer."; color: Theme.dim }
                    RowLayout {
                        Layout.fillWidth: true; spacing: 8
                        InputField { id: rename; text: layers.selected?.label || ""; Layout.fillWidth: true; onAccepted: if (text.trim()) layers.controller.call("layers.rename", { layer: layers.selected.id, name: text.trim() }) }
                        ActionButton { text: "Rename"; enabled: !layers.controller.busy && rename.text.trim() !== "" && rename.text !== layers.selected?.label; onClicked: layers.controller.call("layers.rename", { layer: layers.selected.id, name: rename.text.trim() }) }
                    }
                    ActionButton { text: "Delete layer"; quiet: true; enabled: !layers.controller.busy; onClicked: deleteDialog.open() }
                }
                ColumnLayout {
                    visible: layers.selected === null; Layout.fillWidth: true; Layout.margins: 24; spacing: 12
                    Symbol { name: "layers"; tint: Theme.dim; Layout.preferredWidth: 30; Layout.preferredHeight: 30 }
                    AppText { text: "Make room for each kind of work"; font.pixelSize: 16; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    AppText { text: "Save windows as a layer, choose their layout, and switch back whenever you need them."; color: Theme.muted; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                    ActionButton { text: "Create a layer"; glyph: "plus"; accent: true; enabled: !layers.controller.busy; onClicked: layers.create() }
                }
                Item { implicitHeight: 12 }
            }
        }
    }
    Item {
    Dialog {
        id: createDialog; parent: layers.controller.dialogParent; anchors.centerIn: parent; width: 410; modal: true; padding: 20
        onOpened: layerName.forceActiveFocus()
        background: Rectangle { color: Theme.surface; radius: 10; border.color: Theme.borderLit }
        contentItem: ColumnLayout {
            spacing: 14
            AppText { text: "New layer"; font.pixelSize: 15; font.weight: Font.DemiBold }
            InputField { id: layerName; placeholderText: "Name this layer"; Layout.fillWidth: true; onAccepted: if (text.trim()) { createDialog.close(); layers.controller.call("layers.create", { name: text.trim(), visible: includeVisible.checked }) } }
            CheckBox { id: includeVisible; text: "Include visible windows"; checked: true; palette.windowText: Theme.text; palette.highlight: Theme.green }
            RowLayout {
                Item { Layout.fillWidth: true }
                ActionButton { text: "Cancel"; onClicked: createDialog.close() }
                ActionButton { text: "Create"; accent: true; enabled: !layers.controller.busy && layerName.text.trim() !== ""; onClicked: { createDialog.close(); layers.controller.call("layers.create", { name: layerName.text.trim(), visible: includeVisible.checked }) } }
            }
        }
    }
    Dialog {
        id: addDialog; parent: layers.controller.dialogParent; anchors.centerIn: parent; width: 470; height: Math.min(520, parent.height - 48); modal: true; padding: 20
        background: Rectangle { color: Theme.surface; radius: 10; border.color: Theme.borderLit }
        contentItem: ColumnLayout {
            spacing: 12
            AppText { text: "Add windows"; font.pixelSize: 15; font.weight: Font.DemiBold }
            AppText { text: "Saved windows move from their previous layer."; color: Theme.muted; font.pixelSize: 11 }
            ScrollView {
                id: picker; Layout.fillWidth: true; Layout.fillHeight: true; contentWidth: availableWidth; clip: true
                ColumnLayout {
                    width: picker.availableWidth; spacing: 3
                    Repeater {
                        model: layers.availableWindows.filter(w => !layers.members.some(m => m.wid === w.wid) && w.title && w.frame.w >= 120 && w.frame.h >= 120)
                        CheckBox {
                            id: pickWindow
                            required property var modelData
                            Layout.fillWidth: true; checked: layers.picked.includes(modelData.wid); palette.windowText: Theme.text; palette.highlight: Theme.green
                            text: layers.controller.appName(modelData.app) + " · " + modelData.title
                            contentItem: AppText { text: pickWindow.text; leftPadding: 30; elide: Text.ElideRight; verticalAlignment: Text.AlignVCenter }
                            onToggled: layers.toggle(modelData.wid, checked)
                        }
                    }
                }
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                ActionButton { text: "Cancel"; onClicked: addDialog.close() }
                ActionButton { text: "Add " + layers.picked.length; accent: true; enabled: layers.selected !== null && layers.picked.length > 0 && !layers.controller.busy; onClicked: { addDialog.close(); layers.controller.call("layers.assign", { layer: layers.selected.id, windowIds: layers.picked }) } }
            }
        }
    }
    Dialog {
        id: deleteDialog; parent: layers.controller.dialogParent; anchors.centerIn: parent; width: 380; modal: true; padding: 20
        background: Rectangle { color: Theme.surface; radius: 10; border.color: Theme.borderLit }
        contentItem: ColumnLayout {
            spacing: 14
            AppText { text: "Delete “" + (layers.selected?.label || "") + "”?"; font.pixelSize: 15; font.weight: Font.DemiBold; Layout.fillWidth: true; wrapMode: Text.WordWrap }
            AppText { text: "The windows stay open."; color: Theme.muted }
            RowLayout { Item { Layout.fillWidth: true } ActionButton { text: "Cancel"; onClicked: deleteDialog.close() } ActionButton { text: "Delete"; onClicked: { deleteDialog.close(); layers.controller.call("layers.delete", { layer: layers.selected.id }) } } }
        }
    }
    }
}
