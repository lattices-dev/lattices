import QtQuick
import QtQuick.Controls

TextField {
    id: field
    // Leading mode glyph and a trailing shortcut hint, both optional.
    property string prompt: ""
    property string keycap: ""
    color: Theme.text
    placeholderTextColor: Theme.dim
    selectionColor: Theme.selection
    selectedTextColor: Theme.text
    font.family: Theme.font
    font.pixelSize: Theme.base
    implicitHeight: 28
    leftPadding: prompt !== "" ? 28 : 9
    rightPadding: cap.visible ? cap.width + 14 : 9
    background: Rectangle { radius: 3; color: Theme.ink; border.color: field.activeFocus ? Theme.accent : field.hovered ? Theme.borderHot : Theme.borderLit }
    AppText { visible: field.prompt !== ""; x: 11; anchors.verticalCenter: parent.verticalCenter; text: field.prompt; mono: true; font.pixelSize: Theme.lead; font.weight: Font.Medium; color: field.activeFocus ? Theme.accent : Theme.muted }
    KeyCap { id: cap; visible: field.keycap !== "" && !field.activeFocus && field.text === ""; anchors.right: parent.right; anchors.rightMargin: 7; anchors.verticalCenter: parent.verticalCenter; text: field.keycap }
}
