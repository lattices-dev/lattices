import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Button {
    id: row
    required property string glyph
    property bool selected: false
    property bool compact: false
    property string shortcut: ""
    readonly property bool lit: selected || hovered || activeFocus
    implicitHeight: 30
    padding: 0
    Accessible.name: text
    ToolTip.visible: hovered && (compact || shortcut !== "")
    ToolTip.delay: compact ? 0 : 700
    ToolTip.text: text + (shortcut !== "" ? "  ·  " + shortcut : "")
    contentItem: RowLayout {
        spacing: 0
        Item {
            Layout.preferredWidth: Theme.rail
            Layout.fillHeight: true
            Symbol { anchors.centerIn: parent; name: row.glyph; tint: row.selected ? Theme.accent : row.lit ? Theme.text : Theme.muted }
        }
        AppText {
            visible: !row.compact
            Layout.fillWidth: true
            text: row.text
            font.pixelSize: Theme.lead
            font.weight: row.selected ? Font.Medium : Font.Normal
            color: row.lit ? Theme.text : Theme.body
        }
    }
    background: Item {
        Rectangle {
            anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6; anchors.topMargin: 1; anchors.bottomMargin: 1
            visible: row.selected || row.hovered || row.visualFocus
            radius: 3
            color: row.selected ? Theme.filmLit : row.hovered ? Theme.film : "transparent"
            border.width: row.visualFocus ? 1 : 0
            border.color: Theme.accent
        }
        // The page on screen: one accent rule on the window edge.
        Rectangle { visible: row.selected; y: 7; width: 2; height: parent.height - 14; color: Theme.accent }
    }
}
