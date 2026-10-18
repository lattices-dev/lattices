pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: virtualView
    required property var controller
    readonly property var space: controller.state.virtual || ({ available: false, running: false, windows: [] })
    spacing: 12
    RowLayout {
        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.topMargin: 12; spacing: 8
        Rectangle { implicitWidth: 6; implicitHeight: 6; radius: 3; color: virtualView.space.running ? Theme.green : Theme.dim }
        AppText { text: virtualView.space.running ? "Virtual space running" : "Virtual space"; font.weight: Font.DemiBold; Layout.fillWidth: true }
        AppText { visible: virtualView.space.running; text: virtualView.space.width + " × " + virtualView.space.height; mono: true; font.pixelSize: 10; color: Theme.dim }
        ActionButton { objectName: "virtualViewerToggle"; text: virtualView.controller.virtualViewerVisible ? "Hide PiP" : "Show PiP"; enabled: virtualView.controller.online; onClicked: virtualView.controller.showVirtualViewer("toggle") }
        ActionButton { visible: virtualView.space.running; text: "Browser"; enabled: !virtualView.controller.busy; onClicked: virtualView.controller.call("computer.virtual.launch", { app: "browser" }) }
        ActionButton { visible: virtualView.space.running; text: "Terminal"; enabled: !virtualView.controller.busy; onClicked: virtualView.controller.call("computer.virtual.launch", { app: "terminal" }) }
        ActionButton { visible: virtualView.space.running; text: "Stop"; enabled: !virtualView.controller.busy; onClicked: stopDialog.open() }
    }
    AppText { visible: virtualView.space.running; text: "Computer use stays here. Your desktop keeps its own keyboard and pointer."; color: Theme.muted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16 }
    Rectangle {
        id: monitor
        Layout.fillWidth: true; Layout.fillHeight: true; Layout.leftMargin: 16; Layout.rightMargin: 16
        radius: 8; color: Theme.ink; border.color: Theme.borderLit; clip: true
        Image {
            id: screen
            anchors.fill: parent; anchors.margins: 1
            source: virtualView.controller.virtualFrame
            fillMode: Image.PreserveAspectFit; cache: false; asynchronous: false
            visible: virtualView.space.running && virtualView.controller.virtualFrame !== ""
        }
        ColumnLayout {
            visible: !virtualView.space.running || virtualView.controller.virtualFrame === ""
            anchors.centerIn: parent; width: Math.max(100, Math.min(350, parent.width - 48)); spacing: 14
            Symbol { name: "virtual"; tint: Theme.dim; Layout.preferredWidth: 32; Layout.preferredHeight: 32; Layout.alignment: Qt.AlignHCenter }
            AppText { text: virtualView.space.running ? "Waiting for the preview" : "A separate space for computer use"; font.pixelSize: 16; font.weight: Font.DemiBold; wrapMode: Text.WordWrap; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
            AppText { text: virtualView.space.running ? "The desktop will appear here." : "Open apps in an offscreen desktop and watch them here while you keep working."; color: Theme.muted; wrapMode: Text.WordWrap; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
            AppText { visible: !virtualView.space.available; text: virtualView.space.reason || "Update the local host to use virtual space."; color: Theme.dim; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter }
            ActionButton { visible: !virtualView.space.running; text: "Start virtual space"; accent: true; enabled: virtualView.space.available && !virtualView.controller.busy; Layout.alignment: Qt.AlignHCenter; onClicked: { virtualView.controller.virtualFrame = ""; virtualView.controller.call("computer.virtual.start") } }
        }
        MouseArea {
            anchors.fill: screen
            enabled: virtualView.space.running && virtualView.controller.virtualControl && !virtualView.controller.busy && virtualView.controller.virtualFrame !== ""
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            function point(x, y) {
                const left = (width - screen.paintedWidth) / 2, top = (height - screen.paintedHeight) / 2
                if (x < left || y < top || x >= left + screen.paintedWidth || y >= top + screen.paintedHeight) return null
                return { space: "virtual", xRatio: (x - left) / screen.paintedWidth, yRatio: (y - top) / screen.paintedHeight, treatment: "execute" }
            }
            onClicked: mouse => {
                const p = point(mouse.x, mouse.y)
                if (!p) return
                p.button = mouse.button === Qt.RightButton ? "right" : mouse.button === Qt.MiddleButton ? "middle" : "left"
                virtualView.controller.call("computer.click", p)
            }
            onWheel: wheel => {
                const p = point(wheel.x, wheel.y)
                if (!p) return
                p.dx = -wheel.angleDelta.x / 120; p.dy = -wheel.angleDelta.y / 120
                virtualView.controller.call("computer.scroll", p)
                wheel.accepted = true
            }
        }
    }
    ColumnLayout {
        visible: virtualView.space.running
        Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 16; spacing: 8
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            ActionButton { text: "Control preview"; selected: virtualView.controller.virtualControl; enabled: !virtualView.controller.busy; onClicked: virtualView.controller.virtualControl = !virtualView.controller.virtualControl }
            AppText { text: virtualView.controller.virtualControl ? "Click and scroll in the preview" : "Preview only"; color: Theme.dim; font.pixelSize: 10; Layout.fillWidth: true }
            Repeater {
                model: ["Tab", "Enter", "Esc"]
                ActionButton { required property string modelData; text: modelData; enabled: virtualView.controller.virtualControl && !virtualView.controller.busy; onClicked: virtualView.controller.call("computer.pressKey", { space: "virtual", key: modelData, treatment: "execute" }) }
            }
        }
        RowLayout {
            Layout.fillWidth: true; spacing: 8
            InputField { id: text; placeholderText: "Text for the focused virtual window"; Layout.fillWidth: true; enabled: virtualView.controller.virtualControl && !virtualView.controller.busy; onAccepted: if (send.enabled) send.clicked() }
            ActionButton { id: send; text: "Send text"; enabled: virtualView.controller.virtualControl && !virtualView.controller.busy && text.text !== ""; onClicked: { virtualView.controller.call("computer.typeText", { space: "virtual", text: text.text, treatment: "execute" }); text.clear() } }
        }
    }
    AppText { visible: virtualView.controller.virtualError !== "" || !!virtualView.space.error; text: virtualView.controller.virtualError || virtualView.space.error || ""; color: Theme.red; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.leftMargin: 16; Layout.rightMargin: 16; Layout.bottomMargin: 12 }
    Item {
        Dialog {
            id: stopDialog; parent: virtualView.controller.dialogParent; anchors.centerIn: parent; width: 390; modal: true; padding: 20
            background: Rectangle { color: Theme.surface; radius: 10; border.color: Theme.borderLit }
            contentItem: ColumnLayout {
                spacing: 14
                AppText { text: "Stop virtual space?"; font.pixelSize: 15; font.weight: Font.DemiBold }
                AppText { text: "Apps in the virtual space will close."; color: Theme.muted }
                RowLayout {
                    Item { Layout.fillWidth: true }
                    ActionButton { text: "Cancel"; onClicked: stopDialog.close() }
                    ActionButton { text: "Stop"; onClicked: { stopDialog.close(); virtualView.controller.virtualControl = false; virtualView.controller.call("computer.virtual.stop") } }
                }
            }
        }
    }
}
