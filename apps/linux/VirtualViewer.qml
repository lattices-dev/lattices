pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

Rectangle {
    id: viewer
    required property var session
    signal hideRequested()
    signal controlsRequested()
    signal moveRequested(real dx, real dy)
    signal resizeRequested(real dx, real dy)
    readonly property string status: !session.online ? "HOST OFFLINE" : !session.running ? "STOPPED" : session.error ? "INTERRUPTED" : session.fresh ? "LIVE" : session.frame ? "WAITING" : "CONNECTING"
    color: Theme.bg
    radius: 8
    border.color: Theme.accentLine
    border.width: 1
    clip: true

    ColumnLayout {
        anchors.fill: parent; anchors.margins: 1; spacing: 0
        Item {
            Layout.fillWidth: true; Layout.preferredHeight: 38
            MouseArea {
                objectName: "viewerDrag"
                anchors.fill: parent
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                property point previous: Qt.point(0, 0)
                onPressed: mouse => previous = mapToGlobal(mouse.x, mouse.y)
                onPositionChanged: mouse => {
                    if (!pressed) return
                    const point = mapToGlobal(mouse.x, mouse.y)
                    viewer.moveRequested(point.x - previous.x, point.y - previous.y)
                    previous = point
                }
            }
            RowLayout {
                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 8
                Rectangle { implicitWidth: 5; implicitHeight: 5; radius: 3; color: viewer.session.fresh && viewer.session.watching ? Theme.accent : Theme.dim }
                AppText { text: "Agent space"; font.pixelSize: 12; font.weight: Font.Medium; Layout.fillWidth: true }
                AppText { objectName: "viewerStatus"; text: viewer.status; mono: true; font.pixelSize: 9; color: viewer.session.fresh ? Theme.accent : Theme.muted }
                ActionButton { objectName: "viewerHide"; text: "Hide"; quiet: true; onClicked: viewer.hideRequested(); Accessible.name: "Hide agent viewer; keep the session running" }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        Item {
            Layout.fillWidth: true; Layout.fillHeight: true
            Image {
                objectName: "viewerImage"
                anchors.fill: parent
                source: viewer.session.frame
                fillMode: Image.PreserveAspectFit
                cache: false
                asynchronous: false
                opacity: viewer.session.fresh ? 1 : 0.3
            }
            ColumnLayout {
                visible: !viewer.session.fresh
                anchors.centerIn: parent; width: parent.width - 40; spacing: 8
                AppText { text: !viewer.session.online ? "Reconnect to the local host" : !viewer.session.running ? "No background desktop running" : viewer.session.error ? "Preview interrupted" : "Connecting to the desktop…"; font.pixelSize: 13; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
                AppText { visible: viewer.session.error !== ""; text: viewer.session.error; color: Theme.muted; font.pixelSize: 11; wrapMode: Text.WordWrap; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
            }
        }
        Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
        RowLayout {
            Layout.fillWidth: true; Layout.preferredHeight: 34; Layout.leftMargin: 12; Layout.rightMargin: 22; spacing: 8
            AppText { text: "WATCHING ONLY"; mono: true; font.pixelSize: 9; color: Theme.dim; Layout.fillWidth: true }
            ActionButton { objectName: "viewerControls"; text: "Open controls"; quiet: true; onClicked: viewer.controlsRequested() }
        }
    }
    MouseArea {
        objectName: "viewerResize"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: 20; height: 20
        cursorShape: Qt.SizeFDiagCursor
        property point previous: Qt.point(0, 0)
        onPressed: mouse => previous = mapToGlobal(mouse.x, mouse.y)
        onPositionChanged: mouse => {
            if (!pressed) return
            const point = mapToGlobal(mouse.x, mouse.y)
            viewer.resizeRequested(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        AppText { anchors.centerIn: parent; text: "◢"; font.pixelSize: 10; color: Theme.dim }
    }
}
