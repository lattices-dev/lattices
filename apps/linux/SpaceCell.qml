import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One desktop space. A solid dot and rule mark the space on screen; the
// frame marks the operator's choice, in the caution tone while it is only
// being inspected.
Button {
    id: cell
    property int spaceId: 0
    property int count: 0
    property string suffix: ""
    property bool current: false
    property bool selected: false
    property bool caution: false
    readonly property color accent: caution ? Theme.caution : Theme.accent
    padding: 0
    implicitHeight: 32
    Accessible.name: "Space " + spaceId + ", " + count + (count === 1 ? " window" : " windows") + (current ? ", current" : "")
    contentItem: Item {
        implicitWidth: readings.implicitWidth + 22
        implicitHeight: 32
        RowLayout {
            id: readings
            anchors.centerIn: parent
            spacing: 7
            Rectangle { visible: cell.current; implicitWidth: 5; implicitHeight: 5; radius: 3; color: Theme.live }
            AppText { text: String(cell.spaceId).padStart(2, "0"); mono: true; font.pixelSize: Theme.base; font.weight: Font.Medium; color: cell.selected ? cell.accent : cell.hovered || cell.current ? Theme.text : Theme.body }
            AppText { text: cell.count + cell.suffix; mono: true; font.pixelSize: Theme.caption; color: cell.count > 0 ? Theme.muted : Theme.dim }
        }
        Rectangle { visible: cell.current; x: 1; width: parent.width - 2; height: 2; anchors.bottom: parent.bottom; anchors.bottomMargin: 1; color: Theme.live }
    }
    background: Rectangle {
        radius: 3
        color: cell.selected ? (cell.caution ? Theme.cautionSoft : Theme.accentSoft) : cell.hovered ? Theme.hover : Theme.surface
        border.color: cell.activeFocus ? Theme.accent : cell.selected ? (cell.caution ? Theme.cautionLine : Theme.accentLine) : Theme.borderLit
    }
}
