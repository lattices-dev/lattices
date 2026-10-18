import QtQuick

// A key the operator can press right now.
Rectangle {
    id: cap
    property string text: ""
    property color ink: Theme.muted
    property color line: Theme.borderLit
    implicitWidth: Math.max(18, label.implicitWidth + 10)
    implicitHeight: 17
    radius: 3
    color: "transparent"
    border.color: line
    AppText { id: label; anchors.centerIn: parent; text: cap.text; mono: true; font.pixelSize: Theme.caption; color: cap.ink }
}
