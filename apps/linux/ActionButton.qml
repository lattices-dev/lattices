import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Button {
    id: button
    property bool accent: false
    property bool selected: false
    property bool quiet: false
    property string glyph: ""
    property string shortcut: ""
    readonly property bool marked: accent || selected
    implicitHeight: 26
    horizontalPadding: quiet ? 4 : 10
    font.family: Theme.font
    font.pixelSize: Theme.base
    opacity: enabled ? 1 : 0.4
    readonly property color ink: marked ? Theme.accent : hovered || visualFocus ? Theme.text : Theme.muted
    contentItem: RowLayout {
        spacing: 6
        Symbol { visible: button.glyph !== ""; name: button.glyph; tint: button.ink; Layout.preferredWidth: 12; Layout.preferredHeight: 12 }
        AppText { text: button.text; font: button.font; color: button.ink; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true }
        KeyCap { visible: button.shortcut !== ""; text: button.shortcut; ink: Theme.dim; line: Theme.border }
    }
    background: Rectangle {
        radius: 3
        color: button.quiet ? (button.hovered ? Theme.film : "transparent") : button.marked ? Theme.accentSoft : button.hovered ? Theme.hover : Theme.surface
        border.width: button.quiet && !button.visualFocus ? 0 : 1
        border.color: button.visualFocus ? Theme.accent : button.marked ? Theme.accentLine : button.hovered ? Theme.borderHot : Theme.borderLit
    }
}
