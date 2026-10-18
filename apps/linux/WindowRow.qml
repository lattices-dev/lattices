import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

Button {
    id: row
    required property var entry
    property string appName: entry.app
    property bool selected: false
    readonly property var desktopEntry: DesktopEntries.heuristicLookup(entry.app)
    readonly property string imagePath: desktopEntry ? Quickshell.iconPath(desktopEntry.icon, true) : ""
    implicitHeight: 34
    padding: 0
    Accessible.name: appName + ", " + entry.title
    background: Rectangle { radius: 3; color: row.selected ? Theme.accentSoft : row.hovered ? Theme.hover : Theme.surface; border.color: row.visualFocus ? Theme.accent : row.selected ? Theme.accentLine : "transparent" }
    contentItem: RowLayout {
        spacing: 10
        Item {
            Layout.leftMargin: 10; Layout.preferredWidth: 18; Layout.preferredHeight: 18
            Image { visible: row.imagePath !== ""; anchors.fill: parent; source: row.imagePath; sourceSize: Qt.size(36, 36) }
            Symbol { visible: row.imagePath === ""; anchors.fill: parent; name: "window"; tint: Theme.dim }
        }
        AppText { text: row.appName; font.weight: Font.Medium; Layout.preferredWidth: row.width < 400 ? 80 : row.width < 580 ? 112 : 150; elide: Text.ElideRight }
        AppText { text: row.entry.title; font.pixelSize: 11; color: Theme.muted; elide: Text.ElideMiddle; Layout.fillWidth: true }
        AppText { visible: row.width >= 400; text: "WS " + row.entry.spaceIds.join(", "); mono: true; font.pixelSize: 10; color: Theme.dim; Layout.preferredWidth: 55 }
        AppText { visible: row.width >= 650; text: row.entry.frame.w + "×" + row.entry.frame.h; mono: true; font.pixelSize: 10; color: Theme.dim; horizontalAlignment: Text.AlignRight; Layout.preferredWidth: 84 }
        Rectangle { Layout.rightMargin: 10; implicitWidth: 5; implicitHeight: 5; radius: 3; color: row.entry.isFocused ? Theme.live : "transparent" }
    }
}
