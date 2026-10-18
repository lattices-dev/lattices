import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The instrument control. One per view is `primary`, filled with the accent.
// `selected` is the operator's choice, `caution` previews without acting, and
// a `dot` reports desktop state.
Button {
    id: button
    property bool selected: false
    property bool quiet: false
    property bool primary: false
    property bool caution: false
    property color dot: "transparent"
    property bool hollowDot: false
    property string keycap: ""
    property string note: ""
    property color noteInk: Theme.muted
    property string placement: ""
    property int align: Text.AlignHCenter
    readonly property bool lit: hovered || activeFocus
    readonly property color accent: caution ? Theme.caution : Theme.accent
    readonly property bool filled: primary && enabled
    readonly property color ink: filled ? Theme.accentInk : selected || caution ? accent : lit ? Theme.text : Theme.body
    implicitHeight: 28
    horizontalPadding: 10
    opacity: enabled ? 1 : 0.38
    Accessible.name: text
    contentItem: RowLayout {
        spacing: 7
        Rectangle {
            visible: button.hollowDot || button.dot.a > 0
            implicitWidth: 6; implicitHeight: 6; radius: 3
            color: button.dot; border.width: button.dot.a > 0 ? 0 : 1; border.color: Theme.dim
        }
        PlacementGlyph { visible: button.placement !== ""; placement: button.placement; ink: button.ink }
        AppText {
            text: button.text; mono: true; font.pixelSize: Theme.small; font.weight: button.filled ? Font.DemiBold : Font.Normal
            color: button.ink
            horizontalAlignment: button.align; verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight; Layout.fillWidth: true
        }
        AppText { visible: button.note !== ""; text: button.note; mono: true; font.pixelSize: Theme.caption; font.letterSpacing: 0.8; color: button.noteInk }
        KeyCap { visible: button.keycap !== ""; text: button.keycap; ink: button.filled ? Theme.accentInk : Theme.muted; line: button.filled ? Qt.rgba(Theme.accentInk.r, Theme.accentInk.g, Theme.accentInk.b, 0.45) : Theme.borderLit }
    }
    background: Rectangle {
        radius: 3
        color: button.filled ? (button.hovered ? Theme.accentHover : Theme.accent)
            : button.selected ? (button.caution ? Theme.cautionSoft : Theme.accentSoft)
            : button.hovered ? Theme.hover : button.quiet ? "transparent" : Theme.surface
        border.width: button.quiet && !button.activeFocus && !button.selected ? 0 : 1
        border.color: button.activeFocus ? (button.filled ? Theme.text : Theme.accent)
            : button.selected || button.caution ? (button.caution ? Theme.cautionLine : Theme.accentLine)
            : button.filled ? Theme.accent : button.hovered ? Theme.borderHot : Theme.borderLit
        // Keyboard focus ring, outside the control so it reads on any fill.
        Rectangle { visible: button.visualFocus; anchors.fill: parent; anchors.margins: -3; radius: 5; color: "transparent"; border.color: Theme.accent }
    }
}
