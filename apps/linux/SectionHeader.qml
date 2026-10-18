import QtQuick
import QtQuick.Layouts

// Caption, optional count, then a rule to the edge. Children trail the rule.
RowLayout {
    id: head
    property string title: ""
    property string detail: ""
    spacing: 8
    DeckLabel { text: head.title }
    AppText { visible: head.detail !== ""; text: head.detail; mono: true; font.pixelSize: Theme.caption; color: Theme.dim }
    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Theme.border }
}
